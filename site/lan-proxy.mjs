import http from 'node:http';
import { isIPv4 } from 'node:net';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const lanAddress = '192.168.2.14';
const privateHost = 'jimbrownhome1.tail8ad282.ts.net';
const hopHeaders = new Set([
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'proxy-connection',
]);
export const productionConfig = Object.freeze({
    bindAddress: lanAddress,
    lanAddress,
    allowLoopback: false,
    listeners: Object.freeze(
        [
            [80, 18798, 8798],
            [8787, 8787, 8787],
            [8788, 8788, 8788],
            [8790, 8790, 8790],
            [8791, 8791, 8791],
            [8792, 8792, 8792],
            [8793, 18793, 8793],
            [8794, 18794, 8794],
            [8795, 18795, 8795],
            [8796, 18796, 8796],
            [8797, 18797, 8797],
            [8798, 18798, 8798],
            [8801, 8801, 8801],
            [8802, 8802, 8802],
        ].map(([port, upstreamPort, privatePort]) => Object.freeze({ port, upstreamPort, privatePort }))
    ),
});

function filteredHeaders(headers) {
    const connection = new Set(
        (headers.connection || '')
            .toLowerCase()
            .split(',')
            .map((value) => value.trim())
    );
    return Object.fromEntries(
        Object.entries(headers).filter(([name]) => !hopHeaders.has(name) && !connection.has(name))
    );
}

function upstreamHeaders(req, trustedOrigin, upstreamPort, upgrade) {
    const headers = filteredHeaders(req.headers);
    for (const name of Object.keys(headers)) {
        if (
            /^(?:forwarded$|x-forwarded-|x-real-ip$|true-client-ip$|cf-|cloudflare-|cdn-loop$|x-original-|x-rewrite-|x-ms-client-principal)/i.test(
                name
            )
        ) {
            delete headers[name];
        }
    }
    delete headers.expect;
    headers.host = `127.0.0.1:${upstreamPort}`;
    headers.origin = trustedOrigin;
    if (upgrade) {
        headers.connection = 'Upgrade';
        headers.upgrade = 'websocket';
    }
    return headers;
}

function lanCookie(cookie, trustedOrigin) {
    const parts = cookie.split(';');
    const name = parts[0].trim().split('=')[0];
    if (name.startsWith('__Host-') || name.startsWith('__Secure-')) {
        throw new Error(`Cookie ${name} requires HTTPS and cannot be used on the HTTP LAN proxy`);
    }
    const trustedHost = new URL(trustedOrigin).hostname;
    const kept = [parts[0]];
    for (const part of parts.slice(1)) {
        const [attribute, ...value] = part.trim().split('=');
        if (attribute.toLowerCase() === 'secure') continue;
        if (attribute.toLowerCase() === 'samesite' && value.join('=').toLowerCase() === 'none') {
            throw new Error(`Cookie ${name} uses SameSite=None, which requires HTTPS`);
        }
        if (attribute.toLowerCase() === 'partitioned') {
            throw new Error(`Cookie ${name} uses Partitioned, which requires HTTPS`);
        }
        if (attribute.toLowerCase() === 'domain') {
            if (value.join('=').toLowerCase().replace(/^\./, '') !== trustedHost) {
                throw new Error(`Cookie ${name} has an unsupported Domain`);
            }
            continue;
        }
        kept.push(part);
    }
    return kept.join(';');
}

function lanCsp(policy, directoryOrigin) {
    // Node coalesces repeated CSP headers with commas. Each policy remains independent.
    return policy
        .split(',')
        .map((singlePolicy) =>
            singlePolicy
                .split(';')
                .map((part) => part.trim())
                .filter(Boolean)
                .flatMap((part) => {
                    const [directive, ...values] = part.split(/\s+/);
                    if (directive.toLowerCase() === 'upgrade-insecure-requests') return [];
                    if (directive.toLowerCase() !== 'frame-ancestors') return [part];
                    const ancestors = values.filter((value) => value !== "'none'");
                    if (!ancestors.includes(directoryOrigin)) ancestors.push(directoryOrigin);
                    return [`${directive} ${ancestors.join(' ')}`];
                })
                .join('; ')
        )
        .join(', ');
}

function responseHeaders(headers, trustedOrigin, incomingOrigin, directoryOrigin, upgrade = false) {
    const result = filteredHeaders(headers);
    if (result.location) {
        const location = result.location;
        if (/^(?:https?:)?\/\//i.test(location)) {
            const target = new URL(location, trustedOrigin);
            if (target.origin === trustedOrigin)
                result.location = `${incomingOrigin}${target.pathname}${target.search}${target.hash}`;
        }
    }
    if (result['set-cookie'])
        result['set-cookie'] = result['set-cookie'].map((cookie) => lanCookie(cookie, trustedOrigin));
    for (const name of ['content-security-policy', 'content-security-policy-report-only']) {
        if (result[name]) {
            result[name] = Array.isArray(result[name])
                ? result[name].map((value) => lanCsp(value, directoryOrigin))
                : lanCsp(result[name], directoryOrigin);
        }
    }
    if (upgrade) {
        result.connection = 'Upgrade';
        result.upgrade = 'websocket';
    }
    return result;
}

function rawHeaderCount(req, name) {
    let count = 0;
    for (let index = 0; index < req.rawHeaders.length; index += 2) {
        if (req.rawHeaders[index].toLowerCase() === name) count++;
    }
    return count;
}

export function permittedSource(address, allowLoopback = false) {
    if (!isIPv4(address)) return false;
    return address.startsWith('192.168.2.') || (allowLoopback && address.startsWith('127.'));
}

export function createLanProxy(config = productionConfig, logger = console) {
    const { bindAddress, lanAddress: address, allowLoopback = false, listeners } = config;
    if (
        !isIPv4(bindAddress) ||
        !isIPv4(address) ||
        bindAddress !== address ||
        (bindAddress !== lanAddress && !(allowLoopback && bindAddress.startsWith('127.')))
    ) {
        throw new Error(
            'Bind address must be explicitly 192.168.2.14, or an explicitly permitted loopback test address'
        );
    }
    if (!Array.isArray(listeners) || !listeners.length) throw new Error('At least one listener is required');
    for (const item of listeners) {
        if (
            ![item.port, item.upstreamPort, item.privatePort].every(Number.isInteger) ||
            item.port < 0 ||
            item.port > 65535 ||
            item.upstreamPort < 1 ||
            item.upstreamPort > 65535 ||
            item.privatePort < 1 ||
            item.privatePort > 65535 ||
            (item.port === 0 && !allowLoopback)
        ) {
            throw new Error('Invalid listener ports');
        }
    }
    const sockets = new Set();
    let starting = false;
    let started = false;
    let closing;
    const servers = [];
    const close = () => {
        closing ??= Promise.all(
            servers.map(
                (server) =>
                    new Promise((done, reject) => {
                        if (!server.listening) return done();
                        server.close((error) => (error ? reject(error) : done()));
                    })
            )
        ).then(() => undefined);
        for (const socket of sockets) socket.destroy();
        return closing;
    };

    for (const item of listeners) {
        const trustedOrigin = `https://${privateHost}:${item.privatePort}`;
        const server = http.createServer();
        servers.push(server);
        server.on('connection', (socket) => {
            sockets.add(socket);
            socket.once('close', () => sockets.delete(socket));
        });
        const reject = (req, res, status, message) => {
            logger.error(`LAN proxy ${status}: ${message}; source=${req.socket.remoteAddress}`);
            if (res instanceof http.ServerResponse) {
                res.writeHead(status, { 'Content-Type': 'text/plain', Connection: 'close' }).end(message);
            } else {
                res.end(
                    `HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: ${Buffer.byteLength(message)}\r\n\r\n${message}`
                );
            }
        };
        const handle = (req, res, head) => {
            const upgrade = head !== undefined;
            const port = server.address().port;
            const authority = `${address}${port === 80 ? '' : `:${port}`}`;
            const incomingOrigin = `http://${authority}`;
            if (!permittedSource(req.socket.remoteAddress, allowLoopback))
                return reject(req, res, 403, 'Source IPv4 address is not allowed');
            if (
                rawHeaderCount(req, 'host') !== 1 ||
                ![authority, ...(port === 80 ? [`${address}:80`] : [])].includes(req.headers.host)
            ) {
                return reject(req, res, 403, 'Host is not this LAN listener');
            }
            const origin = req.headers.origin;
            const allowedOrigins = [incomingOrigin, ...(port === 80 ? [`http://${address}:80`] : [])];
            if (rawHeaderCount(req, 'origin') > 1 || (origin !== undefined && !allowedOrigins.includes(origin))) {
                return reject(req, res, 403, 'Origin is not this LAN listener');
            }
            if (
                (req.headers['sec-fetch-site'] || '')
                    .toLowerCase()
                    .split(',')
                    .some((value) => value.trim() === 'cross-site')
            ) {
                return reject(req, res, 403, 'Cross-site requests are not allowed');
            }
            if (!req.url.startsWith('/') || req.url.startsWith('//'))
                return reject(req, res, 400, 'Only origin-form request paths are allowed');
            if (upgrade && req.headers.upgrade?.toLowerCase() !== 'websocket')
                return reject(req, res, 400, 'Only WebSocket upgrades are supported');
            if (item.privatePort === 8794 && req.method === 'HEAD') {
                if (!upgrade) res.setHeader('Allow', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
                return reject(req, res, 405, 'Work Log does not support HEAD');
            }
            if (item.privatePort === 8794 && req.url === '/' && !upgrade && req.method === 'GET') {
                res.writeHead(302, { Location: '/app', 'Content-Length': 0 }).end();
                return;
            }
            if (req.headers.expect && !upgrade) res.writeContinue();
            const upstream = http.request({
                hostname: '127.0.0.1',
                port: item.upstreamPort,
                method: req.method,
                path: req.url,
                headers: upstreamHeaders(req, trustedOrigin, item.upstreamPort, upgrade),
                agent: false,
            });
            let responseStarted = false;
            const failure = (error) => {
                logger.error(`LAN proxy upstream error on ${port}: ${error.message}`);
                if (res.destroyed || res.writableEnded) return;
                if (responseStarted || (!upgrade && res.headersSent)) res.destroy(error);
                else reject(req, res, 502, 'LAN upstream unavailable or incompatible; inspect proxy logs');
            };
            upstream.on('socket', (socket) => {
                sockets.add(socket);
                socket.once('close', () => sockets.delete(socket));
            });
            upstream.on('error', failure);
            req.on('aborted', () => upstream.destroy());
            req.on('error', (error) => {
                logger.error(`LAN request stream error on ${port}: ${error.message}`);
                upstream.destroy();
            });
            res.on('close', () => upstream.destroy());
            res.on('error', (error) => {
                logger.error(`LAN client error on ${port}: ${error.message}`);
                upstream.destroy();
            });
            upstream.on('response', (response) => {
                let headers;
                try {
                    headers = responseHeaders(
                        response.headers,
                        trustedOrigin,
                        incomingOrigin,
                        `http://${address}:8790`
                    );
                } catch (error) {
                    failure(error);
                    response.destroy();
                    return;
                }
                response.on('error', failure);
                response.on('aborted', () => failure(new Error('Upstream response ended before completion')));
                responseStarted = true;
                if (upgrade) {
                    // A refused handshake still needs a complete HTTP response.
                    res.write(
                        `HTTP/1.1 ${response.statusCode} ${http.STATUS_CODES[response.statusCode] || 'Response'}\r\n`
                    );
                    for (const [name, value] of Object.entries(headers)) {
                        for (const entry of Array.isArray(value) ? value : [value]) res.write(`${name}: ${entry}\r\n`);
                    }
                    res.write('Connection: close\r\n\r\n');
                    response.pipe(res);
                } else {
                    res.writeHead(response.statusCode, headers);
                    response.pipe(res);
                }
            });
            upstream.on('upgrade', (response, socket, upstreamHead) => {
                if (!upgrade || response.headers.upgrade?.toLowerCase() !== 'websocket') {
                    socket.destroy();
                    failure(new Error('Unexpected upstream upgrade'));
                    return;
                }
                let headers;
                try {
                    headers = responseHeaders(
                        response.headers,
                        trustedOrigin,
                        incomingOrigin,
                        `http://${address}:8790`,
                        true
                    );
                } catch (error) {
                    socket.destroy();
                    failure(error);
                    return;
                }
                socket.on('error', (error) => {
                    logger.error(`LAN WebSocket upstream error on ${port}: ${error.message}`);
                    res.destroy();
                });
                res.once('close', () => socket.destroy());
                socket.once('close', () => res.destroy());
                responseStarted = true;
                res.write('HTTP/1.1 101 Switching Protocols\r\n');
                for (const [name, value] of Object.entries(headers)) {
                    for (const entry of Array.isArray(value) ? value : [value]) res.write(`${name}: ${entry}\r\n`);
                }
                res.write('\r\n');
                if (upstreamHead.length) res.write(upstreamHead);
                if (head.length) socket.write(head);
                socket.pipe(res).pipe(socket);
            });
            if (upgrade) upstream.end();
            else req.pipe(upstream);
        };
        server.on('request', (req, res) => handle(req, res));
        server.on('checkContinue', (req, res) => handle(req, res));
        server.on('upgrade', (req, socket, head) => handle(req, socket, head));
        server.on('connect', (req, socket) => reject(req, socket, 405, 'CONNECT is not supported'));
        server.on('clientError', (error, socket) => {
            logger.error(`LAN HTTP parser error: ${error.message}`);
            if (socket.writable)
                socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
        });
        server.on('error', (error) => {
            logger.error(`LAN listener ${address}:${item.port} failed: ${error.message}`);
            if (!starting) {
                process.exitCode = 1;
                void close().catch((closeError) => logger.error(`LAN shutdown failed: ${closeError.message}`));
            }
        });
        // Uploads and SSE may run indefinitely; backpressure is handled by pipe().
        server.requestTimeout = 0;
        server.timeout = 0;
    }
    return {
        servers,
        close,
        async start() {
            if (started || starting || closing) throw new Error('Proxy can only be started once');
            starting = true;
            try {
                for (let index = 0; index < servers.length; index++) {
                    const server = servers[index];
                    await new Promise((done, reject) => {
                        const failed = (error) => {
                            server.off('listening', ready);
                            reject(error);
                        };
                        const ready = () => {
                            server.off('error', failed);
                            done();
                        };
                        server.once('error', failed);
                        server.once('listening', ready);
                        server.listen(listeners[index].port, bindAddress);
                    });
                    logger.log(
                        `LAN proxy http://${address}:${server.address().port} -> http://127.0.0.1:${listeners[index].upstreamPort}`
                    );
                }
                started = true;
            } catch (error) {
                await close();
                throw error;
            } finally {
                starting = false;
            }
            return servers.map((server) => server.address());
        },
    };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const proxy = createLanProxy();
    for (const signal of ['SIGINT', 'SIGTERM'])
        process.once(signal, () => {
            void proxy.close().catch((error) => {
                console.error('LAN shutdown failed:', error);
                process.exitCode = 1;
            });
        });
    proxy.start().catch((error) => {
        console.error('LAN proxy startup failed; all listeners closed:', error);
        process.exitCode = 1;
    });
}
