// Reference implementation of the `globalThis.torBridge` contract that
// `WebTorPlatform` drives. Copy this into your app's `web/` directory and
// reference it from `index.html`; it cannot ship as a Flutter asset, because
// the fetch shim has to be installed before any Dart code runs.
//
// Why a JS bridge at all: everything tor-js specific lives here, so the Dart
// side depends on a small stable surface rather than on tor-js's module shape.
//
// Three consumers need this, which is why `fetch` is part of the contract and
// not just lifecycle:
//
//   1. the globalThis.fetch shim, for package:oxy and A2AClient, which offer
//      no injection point;
//   2. a Dart http.BaseClient, for callers that do take an injected client;
//   3. WebTorPlatform, for start/stop and status.
//
// The shim resolves the client at call time rather than capturing it, so it can
// be installed before Tor starts — which it must be, since stacks that cache an
// HTTP client on first use would otherwise capture the unshimmed fetch.

import {
  TorClient,
  Log,
  setWasmUrl,
} from './torjs/entryPoints/wasm-file/index.js';

setWasmUrl('./torjs/tor_js_bg.wasm');

const realFetch = globalThis.fetch.bind(globalThis);

/** The live client, or null when Tor is not running. */
let client = null;
/** Resolves once `start` has finished bootstrapping. */
let ready = null;
/** Called with each status change; set by WebTorPlatform. */
let onStatus = () => {};

function isOnion(url) {
  try {
    return new URL(url, globalThis.location.href).hostname.endsWith('.onion');
  } catch {
    // A URL this malformed is not an onion address, and letting the real fetch
    // produce the error keeps the message the caller expects.
    return false;
  }
}

async function torFetch(input, init) {
  const request = input instanceof Request ? input : new Request(input, init);
  if (!isOnion(request.url)) return realFetch(input, init);

  // Fail closed. Falling through to the real fetch would leak a DNS lookup for
  // a name that cannot resolve publicly, and would surface as a confusing
  // network error rather than "Tor is not running".
  if (!client) {
    throw new TypeError(
      `Tor is not running; refusing to fetch ${request.url} directly.`,
    );
  }
  await ready;

  const headers = {};
  for (const [key, value] of request.headers) headers[key] = value;
  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';

  return client.fetch(request.url, {
    method: request.method,
    headers,
    ...(hasBody ? { body: await request.arrayBuffer() } : {}),
    signal: request.signal,
  });
}

globalThis.fetch = torFetch;

globalThis.torBridge = {
  /** Whether the shim is installed. Lets Dart verify its own wiring. */
  installed: true,

  /** Registers the status callback. */
  onStatus(callback) {
    onStatus = callback;
  },

  /**
   * Starts a client against `gateways` (an array of "ip:port:certhash").
   *
   * Resolves once bootstrapped. Rejects with the underlying error, which is
   * worth surfacing verbatim: a refused gateway and a failed bootstrap need
   * very different fixes.
   */
  async start(gateways) {
    if (client) return;
    onStatus({ state: 'bootstrapping', progress: 0, summary: 'starting' });
    const created = new TorClient({
      gateway: gateways,
      log: new Log(),
      logLevel: 'info',
    });
    client = created;
    ready = created.ready();
    try {
      await ready;
      onStatus({ state: 'ready' });
    } catch (error) {
      client = null;
      ready = null;
      onStatus({ state: 'failed', error: String(error?.message ?? error) });
      throw error;
    }
  },

  /** Stops the client. Safe to call when not running. */
  stop() {
    client?.close();
    client = null;
    ready = null;
    onStatus({ state: 'stopped' });
  },

  /** Fetches through Tor regardless of host; used by the Dart HTTP client. */
  fetch: torFetch,
};
