(() => {
  const config = window.kodiCheckout;
  const status = document.getElementById('checkout-status');
  const transaction = new URLSearchParams(location.search).get('_ptxn');
  if (!config?.enabled) return;
  const sandbox = config.environment === 'sandbox';
  let completed = false;
  if ((!sandbox && config.environment !== 'live') || typeof config.clientToken !== 'string' ||
      !config.clientToken.startsWith(sandbox ? 'test_' : 'live_')) return;
  if (!/^txn_[a-z0-9]+$/.test(transaction || '')) {
    status.textContent = 'Open Buy credits inside Kodi Reader to start a purchase for your account.'; return;
  }
  status.textContent = sandbox ? 'Opening test checkout — no real payment.' : 'Opening secure checkout…';
  const script = document.createElement('script');
  script.src = 'https://cdn.paddle.com/paddle/v2/paddle.js';
  script.onerror = () => { status.textContent = 'Checkout could not load. Please try again from Kodi Reader.'; };
  script.onload = () => {
    if (sandbox) window.Paddle.Environment.set('sandbox');
    window.Paddle.Initialize({token:config.clientToken, eventCallback:event => {
      if (event.name === 'checkout.completed') {
        if (completed || event.data?.transaction_id !== transaction) return;
        const order = event.data?.custom_data?.kodi_order_id;
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(order || '')) return;
        completed = true;
        // This is navigation only. The app waits for its authenticated server's
        // webhook-confirmed order state before showing credited success.
        const scheme = sandbox ? 'com.olly.KodiReader.Sandbox' : 'com.olly.KodiReader';
        const returnURL = `${scheme}://credits/complete?order=${encodeURIComponent(order)}`;
        const link = document.getElementById('return-to-app');
        link.href = returnURL;
        document.getElementById('checkout-return').hidden = false;
        status.textContent = 'Payment completed. Opening Kodi Reader to confirm your credits… If it does not open, use the button below.';
        window.Paddle.Checkout.close();
        location.assign(returnURL);
      } else if (event.name === 'checkout.closed' && !completed) {
        status.textContent = 'You can return to Kodi Reader. Your balance updates automatically after payment confirmation.';
      }
    }});
    // Paddle opens the server-created transaction from _ptxn. No catalog or account IDs from the browser.
  };
  document.head.appendChild(script);
})();
