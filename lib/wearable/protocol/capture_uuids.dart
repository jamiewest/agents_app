/// GATT and HTTP constants for the capture device.
///
/// Mirrors `capture_firmware/docs/PROTOCOL.md` (authoritative). Protocol
/// constants must never be hardcoded outside `lib/wearable/protocol/`.
library;

/// BLE advertising name prefix (`capture-XXXX`).
const String captureNamePrefix = 'capture-';

/// Capture Service UUID (PROTOCOL.md §2).
const String captureServiceUuid = 'c0de0001-6e64-4c9e-9a52-3ab2f75d3f10';

/// Status characteristic — read, notify (§2.1).
const String statusCharacteristicUuid = 'c0de0002-6e64-4c9e-9a52-3ab2f75d3f10';

/// Control characteristic — write (§2.2).
const String controlCharacteristicUuid = 'c0de0003-6e64-4c9e-9a52-3ab2f75d3f10';

/// Control Response characteristic — notify (§2.3).
const String controlResponseCharacteristicUuid =
    'c0de0004-6e64-4c9e-9a52-3ab2f75d3f10';

/// Endpoint characteristic — read, notify (§2.4).
const String endpointCharacteristicUuid =
    'c0de0005-6e64-4c9e-9a52-3ab2f75d3f10';

/// WiFi Provision characteristic — write (§2).
const String wifiProvisionCharacteristicUuid =
    'c0de0006-6e64-4c9e-9a52-3ab2f75d3f10';

/// Data characteristic for BLE fallback transfer — notify (§6).
const String dataCharacteristicUuid = 'c0de0007-6e64-4c9e-9a52-3ab2f75d3f10';

/// Data ACK characteristic for BLE fallback transfer — write (§6).
const String dataAckCharacteristicUuid = 'c0de0008-6e64-4c9e-9a52-3ab2f75d3f10';

/// Device-hosted HTTP port for the bulk plane (§5).
const int captureHttpPort = 8080;

/// Minimum MTU required so control JSON fits a single write (§2).
const int captureMinimumMtu = 185;
