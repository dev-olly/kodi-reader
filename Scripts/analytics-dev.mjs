import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

if (typeof Request === 'undefined' || typeof Response === 'undefined') {
  throw new Error('Analytics preview requires a modern Node.js runtime. Use Node.js 24, as configured in website/package.json.');
}

// Local preview runs the real API handlers. Configure server-only environment
// variables before starting to connect a separate development Supabase project.
// An explicit aggregate snapshot can also be viewed locally without loading any
// database credentials. The file is never copied into the public build.
const website = fileURLToPath(new URL('../website/', import.meta.url));
const publicRoot = path.join(website, 'dist');
const port = Number(process.env.PORT || 4173);
const snapshotFile = process.env.ANALYTICS_LOCAL_SNAPSHOT;
const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
const allowedOrigins = new Set([...allowedHosts].map(host => `http://${host}`));
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };

createServer(async (incoming, outgoing) => {
  try {
    const url = new URL(incoming.url, `http://127.0.0.1:${port}`);
    if (url.pathname === '/api/analytics/local-snapshot') {
      const headers = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Vary': 'Origin, Sec-Fetch-Site' };
      const finish = (code, body) => { outgoing.writeHead(code, headers); outgoing.end(JSON.stringify(body)); };
      // Prevent another origin from reading private aggregates through localhost
      // or DNS rebinding. This endpoint exists only in this loopback dev server.
      if (!allowedHosts.has(incoming.headers.host) || (incoming.headers.origin && !allowedOrigins.has(incoming.headers.origin)) || incoming.headers['sec-fetch-site'] === 'cross-site') {
        finish(403, { error: { code: 'local_origin_required' } }); return;
      }
      if (incoming.method !== 'GET') { finish(405, { error: { code: 'method_not_allowed' } }); return; }
      if (!snapshotFile) { finish(404, { error: { code: 'no_local_snapshot' } }); return; }
      const days = url.searchParams.get('days') || '30';
      if (!['7', '30', '90'].includes(days)) { finish(400, { error: { code: 'invalid_period' } }); return; }
      const snapshot = JSON.parse(await readFile(snapshotFile, 'utf8'));
      const data = snapshot.periods?.[days];
      if (snapshot.version !== 1 || data?.days !== Number(days) || !data.server_metrics || !Number.isFinite(Date.parse(snapshot.captured_at))) {
        finish(503, { error: { code: 'invalid_local_snapshot' } }); return;
      }
      finish(200, { ...data, data_source: { kind: 'local_snapshot', captured_at: snapshot.captured_at, project: 'Kodi Reader' } });
      return;
    }
    if (/^\/api\/analytics\/(?:(?:events|dashboard)|auth\/(?:login|callback|session|logout))$/.test(url.pathname)) {
      const route = url.pathname.slice('/api/analytics/'.length);
      const module = await import(new URL(`../website/api/analytics/${route}.js`, import.meta.url));
      const handler = module[incoming.method];
      if (!handler) { outgoing.writeHead(405); outgoing.end(); return; }
      const chunks = [];
      let size = 0;
      for await (const chunk of incoming) {
        size += chunk.length;
        if (size > 128 * 1024) { outgoing.writeHead(413); outgoing.end(); return; }
        chunks.push(chunk);
      }
      const request = new Request(url, { method: incoming.method, headers: incoming.headers,
        ...(!['GET', 'HEAD'].includes(incoming.method) ? { body: Buffer.concat(chunks) } : {}) });
      const response = await handler(request);
      const headers = Object.fromEntries(response.headers);
      const cookies = response.headers.getSetCookie();
      if (cookies.length) headers['set-cookie'] = cookies;
      outgoing.writeHead(response.status, headers);
      outgoing.end(Buffer.from(await response.arrayBuffer()));
      return;
    }
    if (!['GET', 'HEAD'].includes(incoming.method)) { outgoing.writeHead(405); outgoing.end(); return; }
    let filename = path.resolve(publicRoot, `.${decodeURIComponent(url.pathname)}`);
    if (filename !== publicRoot && !filename.startsWith(publicRoot + path.sep)) { outgoing.writeHead(403); outgoing.end(); return; }
    if (filename === publicRoot) filename = path.join(publicRoot, 'index.html');
    else if (!path.extname(filename)) filename += '.html';
    if (!(await stat(filename)).isFile()) { outgoing.writeHead(404); outgoing.end(); return; }
    outgoing.writeHead(200, { 'Content-Type': types[path.extname(filename)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    outgoing.end(incoming.method === 'HEAD' ? undefined : await readFile(filename));
  } catch (error) {
    if (error.code !== 'ENOENT') console.error('Analytics preview error:', error.message);
    outgoing.writeHead(error.code === 'ENOENT' ? 404 : 500, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    outgoing.end(JSON.stringify({ error: 'local_preview_unavailable' }));
  }
}).listen(port, '127.0.0.1', () => console.log(`Kodi analytics preview: http://127.0.0.1:${port}/analytics`));
