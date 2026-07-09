/// Pure Dart protocol layer for the wearable capture device.
///
/// Mirrors `capture_firmware/docs/PROTOCOL.md` (authoritative). This library
/// must stay free of Flutter and BLE imports so it is unit-testable with
/// plain fixtures; transport lives in `lib/wearable/transport/`.
library;

export 'ble_chunk.dart';
export 'capture_control.dart';
export 'capture_manifest.dart';
export 'capture_uuids.dart';
export 'crc32.dart';
export 'device_endpoint.dart';
export 'device_status.dart';
