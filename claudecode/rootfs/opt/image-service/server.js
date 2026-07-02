#!/usr/bin/env node
/**
 * Claude Terminal Plus - image upload wrapper for ttyd
 *
 * Dependency-free (node core only). Sits on the HA ingress port and:
 *  - serves index.html (header bar + iframe around the terminal)
 *  - accepts image uploads (raw body POST /upload) into /data/images
 *  - proxies /terminal/* (HTTP + WebSocket) to the upstream ttyd on 7681
 *
 * Browser clipboards cannot deliver binary images into a web terminal, so the
 * page intercepts paste/drag-drop, uploads the image here, and hands the user
 * a file path Claude Code can read.
 */

'use strict';

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.IMAGE_SERVICE_PORT || '7682', 10);
const TTYD_HOST = '127.0.0.1';
const TTYD_PORT = parseInt(process.env.TTYD_PORT || '7681', 10);
const UPLOAD_DIR = process.env.UPLOAD_DIR || '/data/images';
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // 10MB

const MIME_EXT = {
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/svg+xml': '.svg',
};

const INDEX_HTML = fs.readFileSync(path.join(__dirname, 'index.html'));

fs.mkdirSync(UPLOAD_DIR, { recursive: true });

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function handleUpload(req, res) {
  const mime = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  const ext = MIME_EXT[mime];
  if (!ext) {
    sendJson(res, 415, { error: `Unsupported image type: ${mime || '(none)'}` });
    req.resume();
    return;
  }

  const declared = parseInt(req.headers['content-length'] || '0', 10);
  if (declared > MAX_UPLOAD_BYTES) {
    sendJson(res, 413, { error: 'Image exceeds 10MB limit' });
    req.resume();
    return;
  }

  const chunks = [];
  let size = 0;
  let aborted = false;

  req.on('data', (chunk) => {
    if (aborted) return;
    size += chunk.length;
    if (size > MAX_UPLOAD_BYTES) {
      aborted = true;
      sendJson(res, 413, { error: 'Image exceeds 10MB limit' });
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on('end', () => {
    if (aborted) return;
    if (size === 0) {
      sendJson(res, 400, { error: 'Empty upload' });
      return;
    }
    const filename = `pasted-${Date.now()}${ext}`;
    const filePath = path.join(UPLOAD_DIR, filename);
    fs.writeFile(filePath, Buffer.concat(chunks), { mode: 0o644 }, (err) => {
      if (err) {
        console.error(`[image-service] write failed: ${err.message}`);
        sendJson(res, 500, { error: 'Failed to save image' });
        return;
      }
      console.log(`[image-service] uploaded ${filePath} (${(size / 1024).toFixed(1)} KB)`);
      sendJson(res, 200, { success: true, path: filePath, filename, size });
    });
  });

  req.on('error', () => { aborted = true; });
}

/** Strip the /terminal prefix so ttyd sees its native paths. */
function ttydPath(url) {
  const stripped = url.replace(/^\/terminal/, '');
  return stripped === '' ? '/' : stripped;
}

function proxyHttp(req, res) {
  const upstream = http.request(
    {
      host: TTYD_HOST,
      port: TTYD_PORT,
      method: req.method,
      path: ttydPath(req.url),
      headers: { ...req.headers, host: `${TTYD_HOST}:${TTYD_PORT}` },
    },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.headers);
      upRes.pipe(res);
    }
  );
  upstream.on('error', (err) => {
    console.error(`[image-service] ttyd proxy error: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
    }
    res.end('Terminal backend unavailable');
  });
  req.pipe(upstream);
}

const server = http.createServer((req, res) => {
  const pathname = req.url.split('?')[0];

  if (pathname === '/terminal' || pathname.startsWith('/terminal/')) {
    proxyHttp(req, res);
    return;
  }
  if (req.method === 'POST' && pathname === '/upload') {
    handleUpload(req, res);
    return;
  }
  if (req.method === 'GET' && pathname === '/health') {
    sendJson(res, 200, { status: 'ok', uploadDir: UPLOAD_DIR });
    return;
  }
  if (pathname === '/favicon.ico') {
    res.writeHead(204);
    res.end();
    return;
  }
  if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': INDEX_HTML.length,
      'Cache-Control': 'no-store',
    });
    res.end(INDEX_HTML);
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found');
});

// WebSocket proxy: replay the upgrade handshake to ttyd and pipe both ways.
server.on('upgrade', (req, socket, head) => {
  const pathname = req.url.split('?')[0];
  if (!(pathname === '/terminal' || pathname.startsWith('/terminal/'))) {
    socket.destroy();
    return;
  }

  const upstream = net.connect(TTYD_PORT, TTYD_HOST, () => {
    let handshake = `${req.method} ${ttydPath(req.url)} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      const value = name.toLowerCase() === 'host'
        ? `${TTYD_HOST}:${TTYD_PORT}`
        : req.rawHeaders[i + 1];
      handshake += `${name}: ${value}\r\n`;
    }
    handshake += '\r\n';
    upstream.write(handshake);
    if (head && head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });

  const teardown = () => {
    upstream.destroy();
    socket.destroy();
  };
  upstream.on('error', teardown);
  socket.on('error', teardown);
  upstream.on('close', () => socket.destroy());
  socket.on('close', () => upstream.destroy());
});

server.listen(PORT, () => {
  console.log(`[image-service] listening on :${PORT}, proxying terminal to ${TTYD_HOST}:${TTYD_PORT}, uploads in ${UPLOAD_DIR}`);
});
