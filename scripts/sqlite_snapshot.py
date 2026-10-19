"""Consistent SQLite export. Run only after the independently reviewed writer fence."""

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import socket
import sqlite3
import stat
import sys
from datetime import datetime, timezone


def reject_reparse_path(path: Path) -> None:
    path = path.absolute()
    for candidate in (path, *path.parents):
        if not candidate.exists():
            continue
        metadata = candidate.lstat()
        if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, "st_file_attributes", 0) & 0x400:
            raise ValueError("Snapshot paths cannot contain symbolic links or reparse points.")


def source_hashes(source: Path) -> tuple:
    hashes = []
    for path in (source, source.with_name(source.name + "-wal"),
                 source.with_name(source.name + "-journal")):
        reject_reparse_path(path)
        if path.exists():
            with path.open("rb") as stream:
                hashes.append(hashlib.file_digest(stream, "sha256").hexdigest())
        else:
            hashes.append(None)
    return tuple(hashes)


def snapshot(source: Path, destination: Path, fence_path: Path, operation: str,
             root: Path, fence_sha256: str) -> dict:
    # Export-FrozenState is the approved caller. A fence file alone is not authorization.
    for path in (source, destination, root, fence_path):
        reject_reparse_path(path)
    with fence_path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != fence_sha256:
            raise ValueError("Writer fence changed after caller validation.")
    source = source.resolve(strict=True)
    root = root.resolve(strict=True)
    destination = destination.resolve()
    if not destination.is_relative_to(root) or destination == root:
        raise ValueError("Snapshot destination escapes its protected export root.")
    fence = json.loads(fence_path.read_text(encoding="utf-8-sig"))
    if not isinstance(fence.get("verifiedLocal"), str):
        raise ValueError("Writer fence has no timestamp.")
    verified = datetime.fromisoformat(fence["verifiedLocal"])
    if verified.tzinfo is None:
        raise ValueError("Writer fence timestamp must include its local offset.")
    age_seconds = (datetime.now(timezone.utc) - verified).total_seconds()
    if (
        fence.get("operationId") != operation
        or fence.get("sourcePath") != str(source)
        or fence.get("host", "").casefold() != socket.gethostname().casefold()
        or not 0 <= age_seconds <= 300
        or fence.get("writersStopped") is not True
        or fence.get("restartPathsDisabled") is not True
    ):
        raise ValueError("Writer fence does not match this export.")
    if not source.is_file() or destination.exists():
        raise ValueError("Source must be a regular file and destination must be new.")
    if not destination.parent.is_dir():
        raise ValueError("Snapshot destination parent must already exist.")
    if source == destination.resolve():
        raise ValueError("Snapshot destination must differ from source.")
    temporary = destination.with_name(destination.name + f".{operation}.partial")
    if temporary.exists():
        raise ValueError("An interrupted export exists. Review it before retrying.")
    for suffix in ("-wal", "-shm", "-journal"):
        if temporary.with_name(temporary.name + suffix).exists():
            raise ValueError("Interrupted snapshot sidecars exist. Review them before retrying.")
    before = source_hashes(source)
    sidecars = {}
    for suffix in ("-wal", "-shm", "-journal"):
        path = source.with_name(source.name + suffix)
        reject_reparse_path(path)
        sidecars[suffix] = path.exists()
    if before[2] is not None or sidecars["-journal"]:
        raise ValueError("Source rollback journal requires separate recovery review.")
    # A fenced, sidecar-free source is self-contained. Immutable reads avoid
    # SQLite creating empty WAL/SHM files when opening a closed WAL-mode database.
    uri_mode = "mode=ro" if any(sidecars.values()) else "mode=ro&immutable=1"
    schema_hash = None
    with closing(sqlite3.connect(source.as_uri() + "?" + uri_mode, uri=True, timeout=5)) as origin:
        origin.execute("PRAGMA query_only=ON")
        source_version = origin.execute("PRAGMA user_version").fetchone()[0]
        schema = origin.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_schema "
            "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
        ).fetchall()
        schema_hash = hashlib.sha256(
            json.dumps(schema, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        with closing(sqlite3.connect(temporary, timeout=5)) as target:
            origin.backup(target, pages=256, sleep=0.05)
            integrity = target.execute("PRAGMA integrity_check").fetchall()
            if integrity != [("ok",)]:
                raise ValueError("SQLite snapshot failed integrity validation.")
            if target.execute("PRAGMA user_version").fetchone()[0] != source_version:
                raise ValueError("SQLite user_version changed during export.")
            if target.execute(
                "SELECT type, name, tbl_name, sql FROM sqlite_schema "
                "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
            ).fetchall() != schema:
                raise ValueError("SQLite schema changed during export.")
    for suffix in ("-wal", "-shm", "-journal"):
        if temporary.with_name(temporary.name + suffix).exists():
            raise ValueError("Snapshot is not self-contained; temporary sidecars remain.")
    with temporary.open("r+b") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
        os.fsync(stream.fileno())
    if before != source_hashes(source):
        raise ValueError("Source database, WAL or rollback journal changed during the fenced snapshot.")
    if source.with_name(source.name + "-shm").exists() != sidecars["-shm"]:
        raise ValueError("Source shared-memory sidecar presence changed during the fenced snapshot.")
    # Never replace an existing export, including one created concurrently.
    os.link(temporary, destination)
    temporary.unlink()
    return {
        "operationId": operation,
        "sha256": digest,
        "bytes": destination.stat().st_size,
        "userVersion": source_version,
        "schemaSHA256": schema_hash,
        "integrity": "ok",
        "sourceUriMode": uri_mode,
        "sourceSidecarsBefore": sidecars,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--fence", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--fence-sha256", required=True)
    parser.add_argument("--operation", required=True)
    args = parser.parse_args()
    if not args.operation.isalnum() or len(args.operation) > 80:
        parser.error("Operation must be an alphanumeric identifier of at most 80 characters.")
    try:
        result = snapshot(args.source, args.destination, args.fence, args.operation,
                          args.root, args.fence_sha256)
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Snapshot failed: {type(error).__name__}. Export is not approved for use.", file=sys.stderr)
        raise SystemExit(1) from error
    print(json.dumps(result))


if __name__ == "__main__":
    main()
