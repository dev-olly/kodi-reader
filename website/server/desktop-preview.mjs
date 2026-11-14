import { createHash } from 'node:crypto';

export const DESKTOP_PREVIEW_TAG = 'desktop-v0.1.0-preview.1';
const RELEASE_API = `https://api.github.com/repos/dev-olly/kodi-reader/releases/tags/${DESKTOP_PREVIEW_TAG}`;
const ASSET_BASE = `https://github.com/dev-olly/kodi-reader/releases/download/${DESKTOP_PREVIEW_TAG}/`;
const SOURCE_COMMIT = '64410e7c5357ca18c9f0120abe8d37b9bd9de1db';
const MANIFEST = { name: 'release-manifest.json', bytes: 2124, sha256: 'a68053034a066bbb3ee1d1896c6e1834af18803e2674d51b392235b8f0d53efc' };
const TARGETS = [
  {
    target: 'x86_64-pc-windows-msvc', nativeSmokeEvidence: false,
    packages: [{ name: 'KodiReader-Preview-0.1.0-windows-x64-setup.exe', format: 'exe' }],
    support: { name: 'KodiReader-Preview-0.1.0-windows-x64-codec-source-and-notices.zip', bytes: 13719999 },
  },
  {
    target: 'x86_64-unknown-linux-gnu', nativeSmokeEvidence: true,
    packages: [
      { name: 'KodiReader-Preview-0.1.0-linux-x86_64.AppImage', format: 'AppImage' },
      { name: 'KodiReader-Preview-0.1.0-linux-amd64.deb', format: 'deb' },
      { name: 'KodiReader-Preview-0.1.0-linux-x86_64.rpm', format: 'rpm' },
    ],
    support: { name: 'KodiReader-Preview-0.1.0-linux-x86_64-codec-source-and-notices.zip', bytes: 13996620 },
  },
];
const KNOWN_ASSETS = new Set([MANIFEST.name, 'SHA256SUMS', 'KodiReader.dmg', ...TARGETS.flatMap(target => [...target.packages.map(item => item.name), target.support.name])]);
const MAX_RELEASE_BYTES = 256 * 1024;
const MAX_CHECKSUM_BYTES = 16 * 1024;
const MAX_ASSET_BYTES = 1024 * 1024 * 1024;
const SHA256 = /^[a-f0-9]{64}$/;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const validSize = size => Number.isSafeInteger(size) && size > 0 && size <= MAX_ASSET_BYTES;

async function boundedBytes(response, limit) {
  const declared = response.headers.get('content-length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > limit)) {
    void response.body?.cancel().catch(() => {});
    throw new Error('Response is too large');
  }
  const reader = response.body?.getReader();
  if (!reader) throw new Error('Response body is missing');
  const chunks = []; let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array) || (total += value.byteLength) > limit) {
        void reader.cancel().catch(() => {});
        throw new Error('Response is too large');
      }
      chunks.push(value);
    }
    return Buffer.concat(chunks, total);
  } finally { reader.releaseLock(); }
}

function assetIndex(release) {
  if (!Array.isArray(release.assets) || release.assets.length > KNOWN_ASSETS.size) throw new Error('Invalid release assets');
  const assets = new Map();
  for (const asset of release.assets) {
    if (!asset || !KNOWN_ASSETS.has(asset.name) || assets.has(asset.name) || asset.state !== 'uploaded' ||
        asset.browser_download_url !== ASSET_BASE + encodeURIComponent(asset.name) || !validSize(asset.size) ||
        typeof asset.digest !== 'string' || !/^sha256:[a-f0-9]{64}$/.test(asset.digest)) throw new Error('Invalid release asset');
    assets.set(asset.name, asset);
  }
  return assets;
}

function requireAsset(assets, name, bytes, sha256) {
  const asset = assets.get(name);
  if (!asset || !validSize(bytes) || !SHA256.test(sha256) || asset.size !== bytes || asset.digest !== `sha256:${sha256}`) throw new Error('Release asset does not match its manifest');
  return asset;
}

function validateManifest(value, assets) {
  if (!value || value.version !== '0.1.0' || value.channel !== 'preview' || value.sourceCommit !== SOURCE_COMMIT ||
      value.signed !== false || value.manualAcceptance !== false || value.updaterEnabled !== false ||
      value.workflowRunURL !== 'https://github.com/dev-olly/kodi-reader/actions/runs/43413721202' ||
      !Array.isArray(value.platforms) || value.platforms.length !== TARGETS.length) throw new Error('Invalid preview manifest');
  const targets = new Set();
  for (const platform of value.platforms) {
    const expected = TARGETS.find(target => target.target === platform?.target);
    if (!expected || targets.has(platform.target) || platform.nativeSmokeEvidence !== expected.nativeSmokeEvidence ||
        !Array.isArray(platform.packages) || platform.packages.length !== expected.packages.length) throw new Error('Invalid preview platform');
    targets.add(platform.target);
    const packages = new Set();
    for (const item of platform.packages) {
      const spec = expected.packages.find(spec => spec.name === item?.name);
      if (!spec || packages.has(item.name) || item.format !== spec.format) throw new Error('Invalid preview package');
      packages.add(item.name); requireAsset(assets, item.name, item.bytes, item.sha256);
    }
    if (platform.support?.name !== expected.support.name) throw new Error('Invalid support archive');
    requireAsset(assets, platform.support.name, expected.support.bytes, platform.support.sha256);
  }
}

function allowedRedirect(value, original) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.port) return false;
  if (url.hostname === 'github.com') return url.href === original;
  return ['release-assets.githubusercontent.com', 'objects.githubusercontent.com'].includes(url.hostname) && url.pathname.startsWith('/github-production-release-asset');
}

async function downloadAsset(fetchImpl, asset, limit) {
  if (asset.size > limit) throw new Error('Asset is too large');
  let url = asset.browser_download_url;
  const signal = AbortSignal.timeout(10000);
  for (let redirects = 0; redirects <= 3; redirects++) {
    const response = await fetchImpl(url, { headers: { Accept: 'application/octet-stream' }, redirect: 'manual', signal });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      if (!location) throw new Error('Missing asset redirect');
      const next = new URL(location, url).href;
      if (!allowedRedirect(next, asset.browser_download_url)) throw new Error('Invalid asset redirect');
      void response.body?.cancel().catch(() => {});
      url = next; continue;
    }
    if (response.status !== 200) throw new Error('Asset is unavailable');
    const bytes = await boundedBytes(response, limit);
    if (bytes.length !== asset.size || `sha256:${hash(bytes)}` !== asset.digest) throw new Error('Asset integrity check failed');
    return bytes;
  }
  throw new Error('Too many asset redirects');
}

function validateChecksums(bytes, assets) {
  const entries = new Map();
  for (const line of new TextDecoder('utf-8', { fatal: true }).decode(bytes).trim().split(/\r?\n/)) {
    const match = /^([a-f0-9]{64})  ([A-Za-z0-9_.-]+)$/.exec(line);
    if (!match || entries.has(match[2]) || match[2] === 'SHA256SUMS' || !assets.has(match[2]) || assets.get(match[2]).digest !== `sha256:${match[1]}`) throw new Error('Invalid checksums');
    entries.set(match[2], match[1]);
  }
  // The compatibility Mac DMG is allowed but never becomes a desktop target.
  for (const name of assets.keys()) if (name !== 'SHA256SUMS' && !entries.has(name)) throw new Error('Missing checksum');
}

/** A pinned, explicitly unsigned preview. This is separate from Tauri updates. */
export function createDesktopPreviewHandler({ fetchImpl = fetch } = {}) {
  return async function GET() {
    const headers = { 'Cache-Control': 'public, max-age=60, s-maxage=300', 'X-Content-Type-Options': 'nosniff' };
    try {
      const response = await fetchImpl(RELEASE_API, { headers: { Accept: 'application/vnd.github+json' }, redirect: 'error', signal: AbortSignal.timeout(10000) });
      if (response.status === 404) return new Response(null, { status: 204, headers });
      if (response.status !== 200) throw new Error('Release metadata unavailable');
      const release = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await boundedBytes(response, MAX_RELEASE_BYTES)));
      if (!release || release.tag_name !== DESKTOP_PREVIEW_TAG || release.draft !== false || release.prerelease !== true ||
          typeof release.published_at !== 'string' || !Number.isFinite(Date.parse(release.published_at))) return new Response(null, { status: 204, headers });
      const assets = assetIndex(release);
      const manifestAsset = requireAsset(assets, MANIFEST.name, MANIFEST.bytes, MANIFEST.sha256);
      const checksumsAsset = assets.get('SHA256SUMS');
      if (!checksumsAsset) throw new Error('Missing checksums');
      const [manifestBytes, checksumsBytes] = await Promise.all([
        downloadAsset(fetchImpl, manifestAsset, MANIFEST.bytes), downloadAsset(fetchImpl, checksumsAsset, MAX_CHECKSUM_BYTES),
      ]);
      const manifest = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(manifestBytes));
      validateManifest(manifest, assets); validateChecksums(checksumsBytes, assets);
      return Response.json(manifest, { headers });
    } catch {
      return Response.json({ error: 'Desktop preview downloads are temporarily unavailable.' }, { status: 503, headers: { ...headers, 'Cache-Control': 'no-store' } });
    }
  };
}
