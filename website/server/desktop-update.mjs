const RELEASES = 'https://api.github.com/repos/dev-olly/kodi-reader/releases?per_page=30';
const ASSET_PREFIX = 'https://github.com/dev-olly/kodi-reader/releases/download/';
export function createDesktopUpdateHandler({ fetchImpl = fetch } = {}) {
  return async function GET() {
    const headers = { 'Cache-Control': 'public, max-age=60, s-maxage=300', 'X-Content-Type-Options': 'nosniff' };
    try {
      const response = await fetchImpl(RELEASES, { headers: { Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error('Release metadata unavailable');
      const releases = await response.json();
      const release = Array.isArray(releases) && releases.find(item => !item.draft && !item.prerelease && /^desktop-v\d/.test(item.tag_name || '') && (item.assets || []).some(asset => asset.name === 'latest.json'));
      if (!release) return new Response(null, { status: 204, headers });
      const manifest = release.assets.find(asset => asset.name === 'latest.json');
      if (typeof manifest.browser_download_url !== 'string' || !manifest.browser_download_url.startsWith(ASSET_PREFIX)) throw new Error('Invalid manifest source');
      const downloaded = await fetchImpl(manifest.browser_download_url, { signal: AbortSignal.timeout(10000) });
      if (!downloaded.ok || Number(downloaded.headers.get('content-length') || 0) > 65536) throw new Error('Manifest unavailable');
      const text = await downloaded.text();
      if (text.length > 65536) throw new Error('Manifest is too large');
      const value = JSON.parse(text);
      if (typeof value.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/.test(value.version) || !value.platforms || typeof value.platforms !== 'object') throw new Error('Invalid update version');
      for (const [target, platform] of Object.entries(value.platforms)) {
        if (!['windows-x86_64', 'linux-x86_64'].includes(target) || !platform || typeof platform.url !== 'string' || !platform.url.startsWith(ASSET_PREFIX) || typeof platform.signature !== 'string' || !platform.signature.trim()) throw new Error('Invalid signed update target');
      }
      if (!Object.keys(value.platforms).length) throw new Error('Empty update manifest');
      return Response.json(value, { headers });
    } catch {
      return Response.json({ error: 'Desktop updates are temporarily unavailable.' }, { status: 503, headers: { ...headers, 'Cache-Control': 'no-store' } });
    }
  };
}
