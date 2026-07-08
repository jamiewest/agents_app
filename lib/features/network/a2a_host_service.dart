// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:a2a/a2a.dart' as a2a;
import 'package:agents/agents.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:extensions_flutter/extensions_flutter.dart';
import 'package:pool/pool.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// One agent this host offers over A2A.
class HostedAgent {
  HostedAgent._(this.path, this.config, this._transport);

  /// The agent's path on this host (e.g. `/agents/researcher`).
  final String path;

  /// The saved agent being served.
  final SavedAgentConfig config;

  final a2a.A2AJsonRpcTransportHandler _transport;
}

/// Issues and validates single-use pairing tokens (in-memory, short TTL).
class PairingTokenStore {
  final Map<String, DateTime> _tokens = {};

  /// Issues a new token valid until [expiresAt].
  void issue(String token, DateTime expiresAt) => _tokens[token] = expiresAt;

  /// Consumes [token]; returns whether it was valid and unexpired.
  ///
  /// Tokens are single-use: valid or not, the token is removed.
  bool consume(String token) {
    final expiresAt = _tokens.remove(token);
    return expiresAt != null && DateTime.now().toUtc().isBefore(expiresAt);
  }
}

/// Paired clients, persisted as SHA-256 hashes of their bearers.
class AuthorizedClientsStore {
  /// Creates an [AuthorizedClientsStore] over [keyValueStore].
  AuthorizedClientsStore(this._keyValueStore);

  static const String _prefix = 'agents_app.a2a.client.';

  final KeyValueStore _keyValueStore;

  /// Records a paired client. Only the bearer's hash is stored.
  Future<void> add({
    required String clientId,
    required String clientName,
    required String bearerHash,
  }) => _keyValueStore.write(
    '$_prefix$bearerHash',
    jsonEncode({
      'clientId': clientId,
      'clientName': clientName,
      'pairedAt': DateTime.now().toUtc().toIso8601String(),
    }),
  );

  /// Whether [bearer] belongs to a paired client.
  Future<bool> verify(String bearer) async {
    final hash = PairingCrypto.sha256Hex(bearer);
    for (final key in await _keyValueStore.keys(prefix: _prefix)) {
      if (PairingCrypto.constantTimeEquals(
        key.substring(_prefix.length),
        hash,
      )) {
        return true;
      }
    }
    return false;
  }
}

/// Serves selected local agents to paired devices over the A2A protocol.
///
/// Native only. Routes: `POST /pair` (unauthenticated, single-use token);
/// authenticated: `GET /agents`, per-agent
/// `GET <path>/.well-known/agent-card.json` and `POST <path>` (JSON-RPC,
/// SSE for streaming). Inbound runs queue through a single-slot pool so a
/// busy host (one loaded local model) serves peers in order instead of
/// bouncing them.
class A2AHostService {
  /// Creates an [A2AHostService].
  A2AHostService(this._services, {this.deviceName = 'agents_app host'});

  /// The name shown to pairing clients.
  final String deviceName;

  final ServiceProvider _services;
  final PairingTokenStore _tokens = PairingTokenStore();
  final Pool _runPool = Pool(1);
  final Map<String, HostedAgent> _agentsByPath = {};

  HttpServer? _server;
  String? _hostId;

  /// Whether the server is running.
  bool get isRunning => _server != null;

  /// The bound port, when running.
  int? get port => _server?.port;

  AuthorizedClientsStore get _clients =>
      AuthorizedClientsStore(_services.getRequiredService<KeyValueStore>());

  Future<String> _ensureHostId() async {
    if (_hostId != null) return _hostId!;
    final keyValueStore = _services.getRequiredService<KeyValueStore>();
    const key = 'agents_app.a2a.hostId';
    final stored = await keyValueStore.read(key);
    var id = stored ?? '';
    if (id.isEmpty) {
      id = PairingCrypto.newToken().substring(0, 16);
      await keyValueStore.write(key, id);
    }
    return _hostId = id;
  }

  /// Starts serving [agents], preferring [port] with an ephemeral fallback.
  Future<void> start(List<SavedAgentConfig> agents, {int port = 41888}) async {
    await stop();
    final factory = _services.getRequiredService<ConfiguredAgentFactory>();

    _agentsByPath.clear();
    for (final config in agents) {
      final slug = config.name
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      final path = '/agents/${slug.isEmpty ? config.id : slug}';
      final agent = await factory.createAgent(config);
      // Sessions are scoped per paired client so two peers talking to the
      // same hosted agent never share conversation state.
      final host = AIHostAgent(
        agent,
        IsolationKeyScopedAgentSessionStore(
          InMemoryAgentSessionStore(),
          _CallerIsolationKeyProvider(),
        ),
      );
      final handler = A2AAgentHandler(host, AgentRunMode.disallowBackground);
      final requestHandler = a2a.A2ADefaultRequestHandler(
        _cardFor(config, path),
        a2a.A2AInMemoryTaskStore(),
        handler,
        a2a.A2ADefaultExecutionEventBusManager(),
        null,
      );
      _agentsByPath[path] = HostedAgent._(
        path,
        config,
        a2a.A2AJsonRpcTransportHandler(requestHandler),
      );
    }

    try {
      _server = await shelf_io.serve(_handle, InternetAddress.anyIPv4, port);
    } on SocketException {
      // The preferred stable port is taken; fall back to an OS-assigned one.
      _server = await shelf_io.serve(_handle, InternetAddress.anyIPv4, 0);
    }
  }

  /// Stops serving.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Creates a pairing offer for the QR/paste flow.
  ///
  /// The returned payload's token is single-use and expires in two
  /// minutes. It must never be logged or placed in model context.
  Future<PairingPayload> createPairingOffer() async {
    final server = _server;
    if (server == null) {
      throw StateError('Start hosting before creating a pairing offer.');
    }
    final token = PairingCrypto.newToken();
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 2));
    _tokens.issue(token, expiresAt);
    return PairingPayload(
      hostId: await _ensureHostId(),
      host: await _lanAddress(),
      port: server.port,
      token: token,
      expiresAt: expiresAt,
    );
  }

  /// Best-effort LAN IPv4 of this device.
  static Future<String> _lanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    String? candidate;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        candidate ??= address.address;
        // Prefer private-range addresses (typical Wi-Fi/LAN).
        if (address.address.startsWith('192.168.') ||
            address.address.startsWith('10.')) {
          return address.address;
        }
      }
    }
    return candidate ?? InternetAddress.loopbackIPv4.address;
  }

  a2a.A2AAgentCard _cardFor(SavedAgentConfig config, String path) =>
      a2a.A2AAgentCard()
        ..name = config.name
        ..description = config.description
        ..version = '1.0.0'
        ..url = path
        ..preferredTransport = a2a.A2ATransportProtocol.jsonRpc
        ..defaultInputModes = <String>['text/plain']
        ..defaultOutputModes = <String>['text/plain']
        ..capabilities = (a2a.A2AAgentCapabilities()
          ..streaming = true
          ..pushNotifications = false
          ..stateTransitionHistory = false)
        ..skills = <a2a.A2AAgentSkill>[];

  Future<shelf.Response> _handle(shelf.Request request) async {
    try {
      final path = '/${request.url.path}'.replaceAll(RegExp(r'/$'), '');

      if (request.method == 'POST' && path == '/pair') {
        return _handlePair(request);
      }

      // Everything else requires a paired bearer.
      final authorization = request.headers['authorization'] ?? '';
      const scheme = 'Bearer ';
      if (!authorization.startsWith(scheme) ||
          !await _clients.verify(authorization.substring(scheme.length))) {
        return shelf.Response(401, body: 'Pairing required.');
      }
      // The bearer's hash doubles as the caller's session isolation key;
      // the raw bearer itself is never retained.
      final callerKey = PairingCrypto.sha256Hex(
        authorization.substring(scheme.length),
      );

      if (request.method == 'GET' && path == '/agents') {
        return shelf.Response.ok(
          jsonEncode({
            'agents': [
              for (final hosted in _agentsByPath.values)
                {
                  'path': hosted.path,
                  'name': hosted.config.name,
                  'description': hosted.config.description,
                },
            ],
          }),
          headers: const {'content-type': 'application/json'},
        );
      }

      for (final hosted in _agentsByPath.values) {
        if (request.method == 'GET' &&
            path == '${hosted.path}/.well-known/agent-card.json') {
          // The card's url is the RPC endpoint the client will POST to; it
          // must be absolute from the client's perspective.
          final origin = request.headers['host'];
          final card = _cardFor(
            hosted.config,
            origin == null ? hosted.path : 'http://$origin${hosted.path}',
          );
          return shelf.Response.ok(
            jsonEncode(card.toJson()),
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && path == hosted.path) {
          return _handleRpc(hosted, await request.readAsString(), callerKey);
        }
      }

      return shelf.Response.notFound('Not found.');
    } catch (e, s) {
      developer.log(
        'A2A host request failed.',
        name: 'agents_app.a2a_host',
        error: e,
        stackTrace: s,
      );
      return shelf.Response.internalServerError(body: 'Host error.');
    }
  }

  Future<shelf.Response> _handlePair(shelf.Request request) async {
    final body = (jsonDecode(await request.readAsString()) as Map)
        .cast<String, Object?>();
    final token = body['token'] as String? ?? '';
    if (!_tokens.consume(token)) {
      return shelf.Response(403, body: 'Invalid or expired pairing token.');
    }

    final bearer = PairingCrypto.newToken();
    await _clients.add(
      clientId: body['clientId'] as String? ?? 'unknown',
      clientName: body['clientName'] as String? ?? 'Unknown device',
      bearerHash: PairingCrypto.sha256Hex(bearer),
    );
    return shelf.Response.ok(
      jsonEncode({
        'credential': bearer,
        'hostId': await _ensureHostId(),
        'deviceName': deviceName,
      }),
      headers: const {'content-type': 'application/json'},
    );
  }

  Future<shelf.Response> _handleRpc(
    HostedAgent hosted,
    String body,
    String callerKey,
  ) =>
      // One inbound run at a time: peers queue instead of being bounced.
      // The caller key rides a zone value because the transport resolves
      // sessions deep inside `handle` (and, for streaming, after this
      // method has already returned its response).
      _runPool.withResource(
        () => runZoned(() async {
          final result = await hosted._transport.handle(body);
          if (result is Function) {
            // Streaming: the transport returns a generator of JSON-RPC
            // events; relay them as server-sent events.
            final stream = (result as dynamic)() as Stream<Object?>;
            final controller = StreamController<List<int>>();
            unawaited(() async {
              try {
                await for (final event in stream) {
                  final json = jsonEncode((event as dynamic).toJson());
                  controller.add(utf8.encode('data: $json\n\n'));
                }
              } catch (e, s) {
                developer.log(
                  'A2A streaming response failed.',
                  name: 'agents_app.a2a_host',
                  error: e,
                  stackTrace: s,
                );
              } finally {
                await controller.close();
              }
            }());
            return shelf.Response.ok(
              controller.stream,
              headers: const {
                'content-type': 'text/event-stream',
                'cache-control': 'no-cache',
              },
            );
          }
          return shelf.Response.ok(
            jsonEncode((result as dynamic).toJson()),
            headers: const {'content-type': 'application/json'},
          );
        }, zoneValues: {_CallerIsolationKeyProvider.zoneKey: callerKey}),
      );
}

/// Resolves the session isolation key from the zone value stamped by
/// [A2AHostService._handleRpc], so each paired client gets its own session
/// namespace in the hosted agent's session store.
class _CallerIsolationKeyProvider extends SessionIsolationKeyProvider {
  /// The zone key carrying the caller's bearer hash during RPC handling.
  static const Symbol zoneKey = #a2aCallerIsolationKey;

  @override
  Future<String?> getSessionIsolationKey({
    CancellationToken? cancellationToken,
  }) async => Zone.current[zoneKey] as String?;
}
