import { AsyncLocalStorage } from 'node:async_hooks';
import { createApp } from '../../../kodi-reader-ai/src/app.js';
import { ServiceError } from '../../../kodi-reader-ai/src/auth.js';

// Exercise the actual backend routes/accounting against the local ledger.
// AI requests retain their user's authorization and go to the existing Kodi service.
export function createNativeApp({ baseAuth, credits, paddle, registerUser, forward = fetch }) {
  const context = new AsyncLocalStorage();
  const auth = {
    async authenticate(header) {
      const user = await baseAuth.authenticate(header);
      await registerUser(user);
      context.getStore().authorization = header;
      return user;
    },
    async deleteAccount() {
      throw new ServiceError(403, 'sandbox_only', 'Account deletion is disabled in this payment test build. Use the regular app to manage your account.');
    },
  };
  const server = createApp({
    env: { CREDITS_ENFORCED: 'true', OPENAI_MODEL: 'gpt-5.6-terra', OPENAI_API_KEY: 'local-proxy-not-an-api-key' },
    auth, credits, paddle,
    fetchImpl: async (url, init) => {
      const authorization = context.getStore()?.authorization;
      if (url !== 'https://api.openai.com/v1/chat/completions' || !authorization)
        throw new Error('Unexpected proxy destination');
      // No credit-protocol header: if production begins enforcing credits, fail
      // closed with 426 rather than charging production and sandbox balances.
      return forward('https://kodi-reader-ai.fly.dev/v1/chat/completions', {
        ...init, redirect: 'error', headers: { authorization,
          'content-type': 'application/json', accept: 'text/event-stream' },
      });
    },
  });
  const handler = server.listeners('request')[0];
  server.removeListener('request', handler);
  server.on('request', (req, res) => {
    // The local listener has no reverse proxy. Do not accept spoofed Fly IPs.
    delete req.headers['fly-client-ip'];
    context.run({}, () => handler(req, res));
  });
  return server;
}
