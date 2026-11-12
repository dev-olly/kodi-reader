import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../download.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const site = 'https://www.kodi-reader.app/';
const fallback = 'https://github.com/dev-olly/kodi-reader/releases/download/v0.4.12/KodiReader.dmg';

// The harness reads the real page's download anchors and card text. It implements
// only the DOM operations used by the production script; unexpected selectors
// fail the test instead of silently returning an unrelated element.
function node(attributes = {}, textContent = '') {
  const attrs = new Map(Object.entries(attributes));
  const classes = new Set((attrs.get('class') || '').split(/\s+/).filter(Boolean));
  return {
    textContent,
    get href() { return attrs.get('href') || ''; },
    set href(value) { attrs.set('href', value); },
    getAttribute(name) { return attrs.get(name) ?? null; },
    setAttribute(name, value) { attrs.set(name, value); },
    removeAttribute(name) { attrs.delete(name); },
    classList: {
      remove(name) { classes.delete(name); },
      contains(name) { return classes.has(name); },
      toggle(name, force) {
        const enabled = force ?? !classes.has(name);
        if (enabled) classes.add(name); else classes.delete(name);
        return enabled;
      },
    },
  };
}

function attributes(markup) {
  return Object.fromEntries([...markup.matchAll(/([^\s"'<>/=]+)(?:="([^"]*)")?/g)].map(match => [match[1], match[2] ?? '']));
}

function makeDocument(config) {
  const links = [...html.matchAll(/<a\b([^>]*\bdata-download-platform="[^"]+"[^>]*)>([\s\S]*?)<\/a>/g)]
    .map(match => node(attributes(match[1]), match[2].replace(/<[^>]*>/g, '')));
  const cards = new Map();
  const summaries = new Map();
  for (const platform of ['macos', 'windows', 'linux']) {
    const cardHtml = html.match(new RegExp('<article\\b[^>]*data-platform-card="' + platform + '"[^>]*>([\\s\\S]*?)<\\/article>'))?.[1];
    assert.ok(cardHtml, 'Page includes the ' + platform + ' download card');
    const children = new Map();
    for (const attribute of ['data-platform-status', 'data-platform-version', 'data-platform-note']) {
      const match = cardHtml.match(new RegExp('<[^>]*\\b' + attribute + '\\b[^>]*>([^<]*)'));
      if (match) children.set('[' + attribute + ']', node(attributes(match[0].split('>')[0]), match[1]));
    }
    cards.set(platform, { querySelector(selector) { return children.get(selector) || null; } });
    summaries.set(platform, node({}, platform === 'macos' ? 'Available now' : 'In testing'));
  }
  const packageNote = node();
  const availability = node();
  const configured = config ?? JSON.parse(html.match(/<script id="desktop-download-config"[^>]*>([^<]*)<\/script>/)[1]);
  const document = {
    getElementById(id) {
      assert.equal(id, 'desktop-download-config');
      return node({}, JSON.stringify(configured));
    },
    querySelectorAll(selector) {
      if (selector === '[data-download-platform="macos"], [data-download]') {
        return links.filter(link => link.getAttribute('data-download-platform') === 'macos' || link.getAttribute('data-download') !== null);
      }
      const match = selector.match(/^\[data-download-platform="([^"]+)"\]\[data-download-package="([^"]+)"\]$/);
      assert.ok(match, 'Recognized download selector: ' + selector);
      return links.filter(link => link.getAttribute('data-download-platform') === match[1] && link.getAttribute('data-download-package') === match[2]);
    },
    querySelector(selector) {
      const card = selector.match(/^\[data-platform-card="([^"]+)"\]$/);
      if (card) return cards.get(card[1]) || null;
      const summary = selector.match(/^\[data-platform-summary="([^"]+)"\]$/);
      if (summary) return summaries.get(summary[1]) || null;
      if (selector === '.linux-packages > span') return packageNote;
      if (selector === '.download-heading > p > span') return availability;
      assert.fail('Unexpected document selector: ' + selector);
    },
  };
  return {
    document, links, cards, summaries, packageNote, availability,
    link(platform, kind) { return links.find(item => item.getAttribute('data-download-platform') === platform && (!kind || item.getAttribute('data-download-package') === kind)); },
    text(platform, attribute) { return cards.get(platform).querySelector('[' + attribute + ']').textContent; },
  };
}

async function runDownloads({ releases = [], manifest = null, config, failReleases = false, failManifest = false } = {}) {
  const dom = makeDocument(config);
  const requests = [];
  const fetch = async raw => {
    const url = new URL(raw, site);
    requests.push(url.href);
    if (url.hostname === 'api.github.com') {
      if (failReleases) throw new Error('GitHub unavailable');
      return Response.json(releases);
    }
    assert.equal(url.origin, new URL(site).origin, 'Manifest requests remain on this website');
    assert.equal(url.pathname, '/api/desktop-update');
    if (failManifest) throw new Error('Update receiver unavailable');
    return manifest ? Response.json(manifest) : new Response(null, { status: 204 });
  };
  runInNewContext(script, { document: dom.document, window: { location: new URL(site) }, URL, AbortSignal, fetch });
  await new Promise(setImmediate);
  return { ...dom, requests };
}

function asset(tag, name) {
  return { name, browser_download_url: 'https://github.com/dev-olly/kodi-reader/releases/download/' + tag + '/' + encodeURIComponent(name) };
}

function desktopFixture({ version = '0.1.0', prerelease = false, draft = false } = {}) {
  const tag = 'desktop-v' + version;
  const windows = asset(tag, 'KodiReader_' + version + '_x64-setup.exe');
  const linux = asset(tag, 'Kodi Reader_' + version + '_amd64.AppImage');
  const deb = asset(tag, 'KodiReader_' + version + '_amd64.deb');
  const rpm = asset(tag, 'KodiReader-' + version + '-1.x86_64.rpm');
  const release = {
    tag_name: tag, prerelease, draft,
    assets: [asset(tag, 'latest.json'), windows, asset(tag, windows.name + '.sig'), linux, asset(tag, linux.name + '.sig'), deb, rpm],
  };
  const manifest = {
    version,
    platforms: {
      'windows-x86_64': { url: windows.browser_download_url, signature: 'signed-windows-update-metadata' },
      'linux-x86_64': { url: linux.browser_download_url, signature: 'signed-linux-update-metadata' },
    },
  };
  return { release, manifest, windows, linux, deb, rpm };
}

function assertPending(dom) {
  const desktopLinks = dom.links.filter(link => link.getAttribute('data-download-platform') !== 'macos');
  assert.equal(desktopLinks.length, 4);
  for (const link of desktopLinks) {
    assert.equal(link.getAttribute('href'), null, 'Pending packages have no download URL');
    assert.equal(link.getAttribute('aria-disabled'), 'true');
  }
  for (const platform of ['windows', 'linux']) {
    assert.equal(dom.text(platform, 'data-platform-status'), 'In testing');
    assert.equal(dom.summaries.get(platform).textContent, 'In testing');
  }
}

test('metadata network failures retain the immutable Mac installer and pending desktop links', async () => {
  for (const failure of [{ failReleases: true, failManifest: true }, { failManifest: true }, { manifest: null }]) {
    const dom = await runDownloads(failure);
    assert.equal(dom.link('macos').href, fallback);
    assert.equal(dom.text('macos', 'data-platform-version'), 'v0.4.12');
    assertPending(dom);
  }
});

test('a failed manifest does not prevent an independently published Mac update', async () => {
  const dmg = asset('v0.4.13', 'KodiReader.dmg');
  const dom = await runDownloads({ releases: [{ tag_name: 'v0.4.13', assets: [dmg] }], failManifest: true });
  assert.equal(dom.link('macos').href, dmg.browser_download_url);
  assert.equal(dom.text('macos', 'data-platform-version'), 'v0.4.13');
  assertPending(dom);
});

test('a valid signed stable release enables the exact Windows and Linux package URLs', async () => {
  const fixture = desktopFixture();
  const dom = await runDownloads({ releases: [fixture.release], manifest: fixture.manifest });
  assert.equal(dom.link('macos').href, fallback, 'Desktop-only metadata keeps the Mac channel intact');
  for (const [platform, kind, expected] of [
    ['windows', 'nsis', fixture.windows], ['linux', 'appimage', fixture.linux],
    ['linux', 'deb', fixture.deb], ['linux', 'rpm', fixture.rpm],
  ]) {
    const link = dom.link(platform, kind);
    assert.equal(link.href, expected.browser_download_url);
    assert.equal(link.getAttribute('aria-disabled'), null);
    assert.equal(link.getAttribute('tabindex'), null);
    assert.equal(link.getAttribute('role'), null);
  }
  for (const platform of ['windows', 'linux']) {
    assert.equal(dom.text(platform, 'data-platform-status'), 'Available now');
    assert.equal(dom.text(platform, 'data-platform-version'), 'v0.1.0');
    assert.equal(dom.summaries.get(platform).textContent, 'Available now');
    assert.equal(dom.cards.get(platform).querySelector('[data-platform-status]').classList.contains('release-status-testing'), false);
  }
  assert.match(dom.availability.textContent, /Available for Mac, Windows 11, and Linux/);
});

test('desktop artifacts cannot replace a Mac installer even when their release appears first', async () => {
  const fixture = desktopFixture();
  fixture.release.assets.push(asset(fixture.release.tag_name, 'KodiReader.dmg'));
  const dmg = asset('v0.4.12', 'KodiReader.dmg');
  const dom = await runDownloads({ releases: [fixture.release, { tag_name: 'v0.4.12', assets: [dmg] }], manifest: fixture.manifest });
  assert.equal(dom.link('macos').href, dmg.browser_download_url);
  assert.equal(dom.text('macos', 'data-platform-version'), 'v0.4.12');
  assert.equal(dom.link('windows', 'nsis').href, fixture.windows.browser_download_url);
});

test('draft and prerelease desktop packages remain unavailable on the default stable channel', async () => {
  for (const options of [{ draft: true }, { prerelease: true }, { version: '0.1.0-beta.1', prerelease: true }]) {
    const fixture = desktopFixture(options);
    const dom = await runDownloads({ releases: [fixture.release], manifest: fixture.manifest });
    assertPending(dom);
    assert.equal(dom.link('macos').href, fallback);
  }
});

test('wrong hosts, repositories, tags, paths and filenames cannot become download links', async () => {
  const mutations = [
    url => url.replace('github.com', 'github.com.evil.example'),
    url => url.replace('/dev-olly/kodi-reader/', '/someone-else/kodi-reader/'),
    url => url.replace('/desktop-v0.1.0/', '/desktop-v9.0.0/'),
    url => url.replace('/desktop-v0.1.0/', '/desktop-v0.1.0/extra/'),
    url => url.replace('KodiReader_', 'AnotherReader_'),
    url => url + '?redirect=elsewhere',
    url => url.replace('https://github.com/', 'https://visitor@github.com/'),
  ];
  for (const mutate of mutations) {
    const fixture = desktopFixture();
    const forged = mutate(fixture.windows.browser_download_url);
    fixture.windows.browser_download_url = forged;
    fixture.manifest.platforms['windows-x86_64'].url = forged;
    const dom = await runDownloads({ releases: [fixture.release], manifest: fixture.manifest });
    assertPending(dom);
    assert.equal(dom.link('macos').href, fallback);
  }
});

test('a complete release needs the exact signature sidecar for each updater package', async () => {
  for (const missing of ['windows', 'linux']) {
    const fixture = desktopFixture();
    fixture.release.assets = fixture.release.assets.filter(item => item.name !== fixture[missing].name + '.sig');
    fixture.release.assets.push(asset(fixture.release.tag_name, 'unrelated-package.sig'));
    const dom = await runDownloads({ releases: [fixture.release], manifest: fixture.manifest });
    assertPending(dom);
  }
});

test('empty signatures, missing platforms and manifest/version mismatches keep desktop downloads pending', async () => {
  const mutations = [
    fixture => { fixture.manifest.platforms['windows-x86_64'].signature = '  '; },
    fixture => { delete fixture.manifest.platforms['linux-x86_64']; },
    fixture => { fixture.manifest.version = '9.0.0'; },
    fixture => { fixture.release.assets = fixture.release.assets.filter(item => item.name !== 'latest.json'); },
    fixture => { fixture.release.assets.find(item => item.name === 'latest.json').browser_download_url = 'https://evil.example/latest.json'; },
  ];
  for (const mutate of mutations) {
    const fixture = desktopFixture();
    mutate(fixture);
    assertPending(await runDownloads({ releases: [fixture.release], manifest: fixture.manifest }));
  }
});

test('an unsafe optional Linux package stays disabled without blocking valid signed updater packages', async () => {
  const fixture = desktopFixture();
  fixture.deb.browser_download_url = fixture.deb.browser_download_url.replace('github.com', 'evil.example');
  const dom = await runDownloads({ releases: [fixture.release], manifest: fixture.manifest });
  assert.equal(dom.link('linux', 'deb').getAttribute('href'), null);
  assert.equal(dom.link('linux', 'deb').getAttribute('aria-disabled'), 'true');
  assert.equal(dom.link('linux', 'rpm').href, fixture.rpm.browser_download_url);
  assert.equal(dom.link('linux', 'appimage').href, fixture.linux.browser_download_url);
});

test('malformed release data and untrusted Mac URLs preserve the known Mac installer', async () => {
  const dmg = asset('v0.4.12', 'KodiReader.dmg');
  dmg.browser_download_url = dmg.browser_download_url.replace('github.com', 'evil.example');
  for (const releases of [{ unexpected: true }, [null, { tag_name: 'v0.4.12', assets: 'not-an-array' }], [{ tag_name: 'v0.4.12', assets: [dmg] }]]) {
    const dom = await runDownloads({ releases });
    assert.equal(dom.link('macos').href, fallback);
    assertPending(dom);
  }
});

test('only an explicitly selected matching prerelease is labelled and offered as a public beta', async () => {
  const fixture = desktopFixture({ version: '0.1.0-beta.1', prerelease: true });
  const dom = await runDownloads({
    releases: [fixture.release],
    config: { channel: 'beta', releaseTag: fixture.release.tag_name, manifest: fixture.manifest },
  });
  assert.equal(dom.link('windows', 'nsis').href, fixture.windows.browser_download_url);
  assert.equal(dom.text('windows', 'data-platform-status'), 'Public beta');
  assert.equal(dom.text('linux', 'data-platform-status'), 'Public beta');
  assert.match(dom.link('windows', 'nsis').getAttribute('aria-label'), /public beta/);
  assert.equal(dom.link('macos').href, fallback);
  assert.equal(dom.requests.length, 1, 'Explicit beta metadata needs only the GitHub artifact lookup');

  const mismatch = await runDownloads({ releases: [fixture.release], config: { channel: 'beta', releaseTag: 'desktop-v0.2.0-beta.1', manifest: fixture.manifest } });
  assertPending(mismatch);
});

test('external manifest configuration is ignored in favor of the same-origin stable receiver', async () => {
  const dom = await runDownloads({ config: { manifestUrl: 'https://evil.example/update', channel: 'beta', releaseTag: 'desktop-v0.1.0-beta.1' } });
  assert.ok(dom.requests.includes(site + 'api/desktop-update'));
  assert.equal(dom.link('macos').href, fallback);
  assertPending(dom);
});
