import test from 'node:test';
import assert from 'node:assert/strict';
import { createDesktopUpdateHandler } from './desktop-update.mjs';
const source = 'https://github.com/dev-olly/kodi-reader/releases/download/desktop-v0.1.0/';
const release = { tag_name: 'desktop-v0.1.0', assets: [{ name: 'latest.json', browser_download_url: source + 'latest.json' }] };
const manifest = { version: '0.1.0', platforms: { 'windows-x86_64': { url: source + 'Kodi_0.1.0_x64-setup.exe', signature: 'verified-by-native-updater' } } };
test('no published desktop release returns no update and preserves the Mac channel', async () => {
  const response = await createDesktopUpdateHandler({ fetchImpl: async () => Response.json([{tag_name:'0.4.11',assets:[]},{...release,draft:true}]) })();
  assert.equal(response.status, 204);
});
test('published desktop manifests retain their artifact signatures', async () => {
  let count=0;
  const response=await createDesktopUpdateHandler({fetchImpl:async()=>Response.json(count++ ? manifest : [release])})();
  assert.equal(response.status,200);assert.deepEqual(await response.json(),manifest);
});
test('unexpected manifest hosts, unsigned targets and outages fail without publishing update data', async () => {
  for (const invalid of [{...release,assets:[{name:'latest.json',browser_download_url:'https://evil.example/manifest'}]},release]) {
    let count=0;
    const response=await createDesktopUpdateHandler({fetchImpl:async()=>Response.json(count++?{...manifest,platforms:{'windows-x86_64':{url:source+'setup.exe',signature:''}}}:[invalid])})();
    assert.equal(response.status,503);
  }
  assert.equal((await createDesktopUpdateHandler({fetchImpl:async()=>{throw new Error('offline')}})()).status,503);
});
