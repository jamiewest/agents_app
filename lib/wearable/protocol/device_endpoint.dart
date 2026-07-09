/// Endpoint JSON model (PROTOCOL.md §2.4).
library;

import 'dart:convert';

/// The device's bulk-plane HTTP endpoint, published over BLE while WiFi is
/// up. `null` result from [DeviceEndpoint.fromBytes] means WiFi is down.
class DeviceEndpoint {
  /// Creates a [DeviceEndpoint].
  const DeviceEndpoint({
    required this.ip,
    required this.port,
    required this.token,
  });

  /// Decodes an Endpoint characteristic value; returns `null` for the empty
  /// object (WiFi down) or a payload missing any required field.
  static DeviceEndpoint? fromBytes(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final ip = json['ip'] as String?;
    final port = (json['port'] as num?)?.toInt();
    final token = json['token'] as String?;
    if (ip == null || port == null || token == null) return null;
    return DeviceEndpoint(ip: ip, port: port, token: token);
  }

  /// IPv4 address on the local network.
  final String ip;

  /// HTTP port.
  final int port;

  /// Bearer token required on every HTTP request; rotates per `wifi_join`.
  final String token;

  /// Base URI for bulk-plane requests.
  Uri get baseUri => Uri(scheme: 'http', host: ip, port: port);

  /// The `Authorization` header value.
  String get authorizationHeader => 'Bearer $token';
}
