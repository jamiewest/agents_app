// Injects Cross-Origin-Opener-Policy / Cross-Origin-Embedder-Policy headers
// into every same-origin response so the page becomes cross-origin isolated
// even when the hosting server does not send them (e.g. `flutter run`).
//
// Cross-origin isolation enables SharedArrayBuffer, which wasm engines
// (wllama) need for multi-threaded inference. Without it, local llama models
// run on a single wasm thread and large models look like they hang.
//
// COEP `credentialless` keeps cross-origin subresources (CDN modules,
// CanvasKit) working without requiring CORP headers from every host.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) =>
  event.waitUntil(self.clients.claim()),
);

self.addEventListener('fetch', (event) => {
  const request = event.request;
  // Pass through requests the SW cannot faithfully replay.
  if (request.cache === 'only-if-cached' && request.mode !== 'same-origin') {
    return;
  }

  event.respondWith(
    fetch(request).then((response) => {
      // Opaque responses (status 0) cannot be rewrapped.
      if (response.status === 0) {
        return response;
      }
      const headers = new Headers(response.headers);
      headers.set('Cross-Origin-Opener-Policy', 'same-origin');
      headers.set('Cross-Origin-Embedder-Policy', 'credentialless');
      headers.set('Cross-Origin-Resource-Policy', 'cross-origin');
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers,
      });
    }),
  );
});
