import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../../website/checkout.js', import.meta.url), 'utf8');
const order = '0a11ce00-0000-4000-8000-000000000002';
for (const environment of ['sandbox', 'live']) test(`${environment} completion returns once to the correct app`, () => {
  let callback, script;
  const redirects = [];
  const elements = Object.fromEntries(['checkout-status', 'checkout-return', 'return-to-app'].map(id => [id, {hidden:true}]));
  const paddle = { Environment: {set() {}}, Initialize(config) {callback=config.eventCallback;}, Checkout: {close() {callback({name:'checkout.closed'});}} };
  vm.runInNewContext(source, {
    URLSearchParams, window:{kodiCheckout:{enabled:true,environment,clientToken:environment==='sandbox'?'test_public':'live_public'},Paddle:paddle},
    document:{getElementById:id=>elements[id], createElement:()=>script={}, head:{appendChild:()=>script.onload()}},
    location:{search:'?_ptxn=txn_test',assign:url=>redirects.push(url)},
  });
  callback({name:'checkout.completed',data:{transaction_id:'txn_other',custom_data:{kodi_order_id:order}}});
  callback({name:'checkout.completed',data:{transaction_id:'txn_test',custom_data:{kodi_order_id:'javascript:bad'}}});
  assert.equal(redirects.length,0);
  const event={name:'checkout.completed',data:{transaction_id:'txn_test',custom_data:{kodi_order_id:order}}};
  callback(event);callback(event);
  assert.deepEqual(redirects,[`com.olly.KodiReader${environment==='sandbox'?'.Sandbox':''}://credits/complete?order=${order}`]);
  assert.equal(elements['checkout-return'].hidden,false);
  assert.equal(elements['return-to-app'].href,redirects[0]);
  assert.match(elements['checkout-status'].textContent,/Opening Kodi Reader/);
});
