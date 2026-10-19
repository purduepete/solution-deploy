import importlib.util
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import socket
from datetime import datetime
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "sqlite_snapshot", Path(__file__).parents[1] / "scripts" / "sqlite_snapshot.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SnapshotTests(unittest.TestCase):
    """All writes are confined to a fresh TemporaryDirectory, with synthetic rows."""

    def snapshot(self, source, root):
        fence_path = root / "fence.json"
        fence_path.write_text(json.dumps({
            "operationId": "test123", "sourcePath": str(source.resolve()),
            "writersStopped": True, "restartPathsDisabled": True,
            "host": socket.gethostname(), "verifiedLocal": datetime.now().astimezone().isoformat(),
        }), encoding="utf-8")
        return MODULE.snapshot(source, root / "export.db", fence_path, "test123", root,
                               hashlib.sha256(fence_path.read_bytes()).hexdigest())

    def create_closed_source(self, root, mode):
        source = root / "source.db"
        with closing(sqlite3.connect(source)) as writer:
            self.assertEqual(writer.execute(f"PRAGMA journal_mode={mode}").fetchone()[0], mode.lower())
            writer.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)")
            writer.execute("PRAGMA user_version=7")
            writer.execute("INSERT INTO sample(value) VALUES ('synthetic')")
            writer.commit()
        return source

    def test_closed_wal_and_delete_sources_are_self_contained(self):
        for mode in ("WAL", "DELETE"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
                root = Path(directory)
                source = self.create_closed_source(root, mode)
                before = MODULE.source_hashes(source)
                result = self.snapshot(source, root)
                self.assertEqual(result["sourceUriMode"], "mode=ro&immutable=1")
                self.assertEqual(result["sourceSidecarsBefore"],
                                 {"-wal": False, "-shm": False, "-journal": False})
                self.assertEqual(result["integrity"], "ok")
                self.assertEqual(result["userVersion"], 7)
                self.assertEqual(before, MODULE.source_hashes(source))
                for path in (source, root / "export.db"):
                    for suffix in ("-wal", "-shm", "-journal"):
                        self.assertFalse(Path(str(path) + suffix).exists())
                self.assertEqual(list(root.glob("*.partial*")), [])
                with closing(sqlite3.connect((root / "export.db").as_uri() + "?mode=ro&immutable=1", uri=True)) as reader:
                    self.assertEqual(reader.execute("SELECT id, value FROM sample").fetchall(), [(1, "synthetic")])

    def test_rollback_journal_blocks_open_and_export(self):
        with tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
            root = Path(directory)
            source = self.create_closed_source(root, "DELETE")
            journal = Path(str(source) + "-journal")
            journal.write_bytes(b"synthetic journal requiring recovery review")
            before = MODULE.source_hashes(source)
            with patch.object(MODULE.sqlite3, "connect") as connect:
                with self.assertRaisesRegex(ValueError, "rollback journal"):
                    self.snapshot(source, root)
                connect.assert_not_called()
            self.assertEqual(before, MODULE.source_hashes(source))
            self.assertFalse((root / "export.db").exists())

    def test_new_source_sidecar_blocks_publication(self):
        for suffix in ("-wal", "-shm", "-journal"):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
                root = Path(directory)
                source = self.create_closed_source(root, "WAL")
                original_hashes = MODULE.source_hashes
                calls = 0

                def hashes_with_new_sidecar(path):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        Path(str(source) + suffix).write_bytes(b"")
                    return original_hashes(path)

                with patch.object(MODULE, "source_hashes", side_effect=hashes_with_new_sidecar):
                    with self.assertRaisesRegex(ValueError, "changed during"):
                        self.snapshot(source, root)
                self.assertFalse((root / "export.db").exists())

    def test_target_sidecars_block_publication(self):
        for suffix in ("-wal", "-shm", "-journal"):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
                root = Path(directory)
                source = self.create_closed_source(root, "DELETE")
                original_connect = sqlite3.connect
                temporary = root / "export.db.test123.partial"

                class TargetWithSidecar(sqlite3.Connection):
                    def close(self):
                        super().close()
                        Path(str(temporary) + suffix).write_bytes(b"synthetic sidecar")

                def connect_with_sidecar(path, *args, **kwargs):
                    if path == temporary:
                        kwargs["factory"] = TargetWithSidecar
                    return original_connect(path, *args, **kwargs)

                with patch.object(MODULE.sqlite3, "connect", side_effect=connect_with_sidecar):
                    with self.assertRaisesRegex(ValueError, "not self-contained"):
                        self.snapshot(source, root)
                self.assertFalse((root / "export.db").exists())

    def test_wal_snapshot_has_committed_rows_and_original_schema(self):
        with tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
            root = Path(directory)
            source = root / "source.db"
            fence_path = root / "fence.json"
            output = root / "export.db"
            writer = sqlite3.connect(source)
            try:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.execute("PRAGMA wal_autocheckpoint=0")
                writer.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)")
                writer.execute("PRAGMA user_version=7")
                writer.execute("INSERT INTO sample(value) VALUES ('synthetic')")
                writer.commit()
                fence_path.write_text(json.dumps({
                    "operationId": "test123", "sourcePath": str(source.resolve()),
                    "writersStopped": True, "restartPathsDisabled": True,
                    "host": socket.gethostname(), "verifiedLocal": datetime.now().astimezone().isoformat(),
                }), encoding="utf-8")
                digest = hashlib.sha256(fence_path.read_bytes()).hexdigest()
                before = MODULE.source_hashes(source)
                self.assertIsNotNone(before[1])
                result = MODULE.snapshot(source, output, fence_path, "test123", root, digest)
                self.assertEqual(result["sourceUriMode"], "mode=ro")
                self.assertTrue(result["sourceSidecarsBefore"]["-wal"])
                self.assertEqual(before, MODULE.source_hashes(source))
                self.assertEqual(result["integrity"], "ok")
                self.assertEqual(result["userVersion"], 7)
                self.assertEqual(len(result["sha256"]), 64)
                with closing(sqlite3.connect(output.as_uri() + "?mode=ro&immutable=1", uri=True)) as target:
                    self.assertEqual(target.execute("SELECT value FROM sample").fetchall(), [("synthetic",)])
                self.assertEqual(writer.execute("SELECT count(*) FROM sample").fetchone()[0], 1)
                with self.assertRaises(ValueError):
                    MODULE.snapshot(source, output, fence_path, "test123", root, digest)
            finally:
                writer.close()

    def test_missing_fence_never_creates_an_export(self):
        with tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
            root = Path(directory)
            source = root / "source.db"
            with closing(sqlite3.connect(source)):
                pass
            fence_path = root / "fence.json"
            fence_path.write_text(json.dumps({"operationId": "wrong", "verifiedLocal": datetime.now().astimezone().isoformat()}), encoding="utf-8")
            output = root / "export.db"
            with self.assertRaises(ValueError):
                MODULE.snapshot(source, output, fence_path, "test123", root,
                                hashlib.sha256(fence_path.read_bytes()).hexdigest())
            self.assertFalse(output.exists())

    def test_rejects_destination_outside_protected_root(self):
        with tempfile.TemporaryDirectory(prefix="solutiondeploy-sqlite-") as directory:
            root = Path(directory)
            protected = root / "protected"
            protected.mkdir()
            source = root / "source.db"
            with closing(sqlite3.connect(source)):
                pass
            fence_path = root / "fence.json"
            fence_path.write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                MODULE.snapshot(source, root / "outside.db", fence_path, "test123", protected,
                                hashlib.sha256(fence_path.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
