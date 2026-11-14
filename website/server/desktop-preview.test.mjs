import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createDesktopPreviewHandler, DESKTOP_PREVIEW_TAG } from './desktop-preview.mjs';
const originalManifest = {
  "version": "0.1.0",
  "channel": "preview",
  "sourceCommit": "64410e7c5357ca18c9f0120abe8d37b9bd9de1db",
  "workflowRunURL": "https://github.com/dev-olly/kodi-reader/actions/runs/43413721202",
  "signed": false,
  "manualAcceptance": false,
  "updaterEnabled": false,
  "platforms": [
    {
      "target": "x86_64-pc-windows-msvc",
      "packages": [
        {
          "name": "KodiReader-Preview-0.1.0-windows-x64-setup.exe",
          "originalName": "Kodi Reader Preview_0.1.0_x64-setup.exe",
          "format": "exe",
          "bytes": 30381366,
          "sha256": "51f7c45aa12c10aa3e4440133a7b60770c5597f110f6ff667c97c077d2d24731"
        }
      ],
      "support": {
        "name": "KodiReader-Preview-0.1.0-windows-x64-codec-source-and-notices.zip",
        "sha256": "d24aa95f6b51a5b6095e6710232490ece0171263e0d43ca9a382bc2c8e9bbeb2"
      },
      "nativeSmokeEvidence": false
    },
    {
      "target": "x86_64-unknown-linux-gnu",
      "packages": [
        {
          "name": "KodiReader-Preview-0.1.0-linux-x86_64.AppImage",
          "originalName": "Kodi Reader Preview_0.1.0_amd64.AppImage",
          "format": "AppImage",
          "bytes": 119060984,
          "sha256": "0e125b5fd76e73c31d8d6837fb44aa8109b1a5027479e402a4febd5868a34103"
        },
        {
          "name": "KodiReader-Preview-0.1.0-linux-amd64.deb",
          "originalName": "Kodi Reader Preview_0.1.0_amd64.deb",
          "format": "deb",
          "bytes": 43261464,
          "sha256": "911b79a5b2e05b5f7dd929255ff439cd03748eac21cd6d90442b8fe2d7209dfc"
        },
        {
          "name": "KodiReader-Preview-0.1.0-linux-x86_64.rpm",
          "originalName": "Kodi Reader Preview-0.1.0-1.x86_64.rpm",
          "format": "rpm",
          "bytes": 43312821,
          "sha256": "de38fde9dd487213b8020511bca71a4eb81957509e062f7e6694016e03d21d66"
        }
      ],
      "support": {
        "name": "KodiReader-Preview-0.1.0-linux-x86_64-codec-source-and-notices.zip",
        "sha256": "df3011ccfd98c1afd1432e7328c778271bf36da0f5ad4997a26d949613542381"
      },
      "nativeSmokeEvidence": true
    }
  ]
};

const source = `https://github.com/dev-olly/kodi-reader/releases/download/${DESKTOP_PREVIEW_TAG}/`;
const api = `https://api.github.com/repos/dev-olly/kodi-reader/releases/tags/${DESKTOP_PREVIEW_TAG}`;
const hash = value => createHash('sha256').update(value).digest('hex');
function fixture({ mac = false } = {}) {
  const manifest = structuredClone(originalManifest);
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  assert.equal(hash(manifestBytes), 'a68053034a066bbb3ee1d1896c6e1834af18803e2674d51b392235b8f0d53efc');
  const asset = (name, size, digest) => ({ name, size, digest: `sha256:${digest}`, state: 'uploaded', browser_download_url: source + name });
  const assets = manifest.platforms.flatMap(platform => [
    ...platform.packages.map(item => asset(item.name, item.bytes, item.sha256)),
    asset(platform.support.name, platform.target.includes('windows') ? 13719999 : 13996620, platform.support.sha256),
  ]);
  assets.push(asset('release-manifest.json', manifestBytes.length, hash(manifestBytes)));
  if (mac) assets.push(asset('KodiReader.dmg', 21937395, '9'.repeat(64)));
  const release = { tag_name: DESKTOP_PREVIEW_TAG, draft: false, prerelease: true, published_at: '2026-11-14T12:00:00Z', assets };
  const files = new Map([['release-manifest.json', manifestBytes]]);
  const updateChecksums = text => {
    const bytes = Buffer.from(text ?? `${assets.filter(item => item.name !== 'SHA256SUMS').map(item => `${item.digest.slice(7)}  ${item.name}`).join('\n')}\n`);
    files.set('SHA256SUMS', bytes);
    const previous = assets.findIndex(item => item.name === 'SHA256SUMS');
    if (previous !== -1) assets.splice(previous, 1);
    assets.push(asset('SHA256SUMS', bytes.length, hash(bytes)));
  };
  updateChecksums();
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    if (url === api) return Response.json(release);
    const name = url.startsWith(source) ? url.slice(source.length) : null;
    if (!files.has(name)) throw new Error('Unexpected fetch target');
    return new Response(files.get(name));
  };
  return { manifest, release, assets, files, calls, updateChecksums, fetchImpl };
}
const invoke = value => createDesktopPreviewHandler({ fetchImpl: value.fetchImpl })();

test('only the published pinned prerelease returns the original unsigned manual-preview manifest', async () => {
  for (const mac of [false, true]) {
    const f = fixture({ mac }); const response = await invoke(f);
    assert.equal(response.status, 200); assert.deepEqual(await response.json(), originalManifest);
    assert.equal(f.calls.length, 3); assert.equal(f.calls[0].url, api);
    assert.ok(f.calls.every(call => call.options.signal instanceof AbortSignal));
    assert.equal(f.calls.some(call => /latest\.json|releases\/latest/.test(call.url)), false);
  }
});

test('missing, draft, stable and other release tags never expose preview links', async () => {
  assert.equal((await createDesktopPreviewHandler({ fetchImpl: async () => new Response(null, { status: 404 }) })()).status, 204);
  for (const change of [{ draft: true }, { prerelease: false }, { tag_name: 'v0.4.12' }, { tag_name: 'desktop-v0.1.0' }, { tag_name: 'desktop-v0.1.0-preview.2' }, { published_at: null }]) {
    const f = fixture(); Object.assign(f.release, change);
    assert.equal((await invoke(f)).status, 204); assert.equal(f.calls.length, 1);
  }
});

test('API errors and invalid JSON are unavailable without caching provider diagnostics', async () => {
  for (const fetchImpl of [async () => new Response('provider details', { status: 429 }), async () => new Response('not json'), async () => { throw new Error('private diagnostics'); }]) {
    const response = await createDesktopPreviewHandler({ fetchImpl })();
    assert.equal(response.status, 503); assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), { error: 'Desktop preview downloads are temporarily unavailable.' });
  }
});

test('manifest byte tampering or replacement fails even if replacement metadata has a matching digest', async () => {
  for (const updateDigest of [false, true]) {
    const f = fixture(); const changed = Buffer.from(f.files.get('release-manifest.json').toString().replace('"signed": false', '"signed": true '));
    f.files.set('release-manifest.json', changed);
    if (updateDigest) { const asset = f.assets.find(item => item.name === 'release-manifest.json'); asset.size = changed.length; asset.digest = `sha256:${hash(changed)}`; f.updateChecksums(); }
    assert.equal((await invoke(f)).status, 503);
  }
});

test('all installer and support names, API sizes and sha256 digests must match the pinned manifest', async () => {
  for (const mutate of [
    f => { f.assets[0].digest = `sha256:${'0'.repeat(64)}`; },
    f => { f.assets[0].size++; },
    f => { f.assets.find(item => item.name.endsWith('.zip')).digest = `sha256:${'0'.repeat(64)}`; },
    f => { f.assets.find(item => item.name.endsWith('.zip')).size++; },
    f => { f.assets[0].digest = 'sha512:unsupported'; },
    f => { f.assets[0].state = 'new'; },
    f => { f.assets.splice(0, 1); },
    f => { f.assets.push({ ...f.assets[0] }); },
    f => { f.assets.splice(f.assets.findIndex(item => item.name === 'SHA256SUMS'), 1); },
  ]) {
    const f = fixture(); mutate(f); assert.equal((await invoke(f)).status, 503);
  }
});

test('unsafe hosts, paths, credentials, query strings and a different tag cannot become asset sources', async () => {
  for (const url of [
    'https://evil.example/release-manifest.json',
    source.replace(DESKTOP_PREVIEW_TAG, 'desktop-v0.1.0') + 'release-manifest.json',
    source.replace('/dev-olly/', '/other-owner/') + 'release-manifest.json',
    source.replace('github.com/', 'github.com.evil.example/') + 'release-manifest.json',
    source.replace('https://', 'https://user:pass@') + 'release-manifest.json',
    source + 'release-manifest.json?redirect=elsewhere', source + '../release-manifest.json',
  ]) {
    const f = fixture(); f.assets.find(item => item.name === 'release-manifest.json').browser_download_url = url;
    assert.equal((await invoke(f)).status, 503); assert.equal(f.calls.length, 1);
  }
});

test('checksum files are verified against API digests and cannot omit, duplicate or traverse files', async () => {
  for (const change of [
    text => text.replace(/^./, '0'),
    text => text.split('\n').slice(1).join('\n'),
    text => text + text.split('\n')[0] + '\n',
    text => text.replace('  KodiReader-', '  ../KodiReader-'),
  ]) {
    const f = fixture(); f.updateChecksums(change(f.files.get('SHA256SUMS').toString()));
    assert.equal((await invoke(f)).status, 503);
  }
  const f = fixture(); f.files.set('SHA256SUMS', Buffer.from('unverified checksum bytes'));
  assert.equal((await invoke(f)).status, 503);
});

test('declared and streamed responses stay bounded even when Content-Length is missing', async () => {
  for (const at of ['release', 'manifest']) {
    for (const declared of [true, false]) {
      const f = fixture(); let cancelled = false;
      const limit = at === 'release' ? 256 * 1024 : 2124;
      const fetchImpl = async (url, options) => {
        if (at === 'release' && url === api || at === 'manifest' && url === source + 'release-manifest.json') {
          const body = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(limit + 1)); }, cancel() { cancelled = true; } });
          return new Response(body, { headers: declared ? { 'content-length': String(limit + 1) } : {} });
        }
        return f.fetchImpl(url, options);
      };
      assert.equal((await createDesktopPreviewHandler({ fetchImpl })()).status, 503);
      if (!declared) assert.equal(cancelled, true);
    }
  }
  const f = fixture(); f.assets.find(item => item.name === 'SHA256SUMS').size = 16 * 1024 + 1;
  assert.equal((await invoke(f)).status, 503);
});

test('GitHub asset redirects allow its HTTPS release CDN and reject private or unrelated destinations', async () => {
  for (const destination of ['https://release-assets.githubusercontent.com/github-production-release-asset/fixture?signature=public', 'http://127.0.0.1/private', 'https://evil.example/private', 'https://github.com/other/repo/releases/download/tag/file']) {
    const f = fixture(); let cdnCalls = 0;
    const fetchImpl = async (url, options) => {
      if (url === source + 'release-manifest.json') return new Response(null, { status: 302, headers: { location: destination } });
      if (url === destination) { cdnCalls++; return new Response(f.files.get('release-manifest.json')); }
      return f.fetchImpl(url, options);
    };
    const response = await createDesktopPreviewHandler({ fetchImpl })();
    const allowed = destination.startsWith('https://release-assets.githubusercontent.com/');
    assert.equal(response.status, allowed ? 200 : 503); assert.equal(cdnCalls, allowed ? 1 : 0);
  }
});
