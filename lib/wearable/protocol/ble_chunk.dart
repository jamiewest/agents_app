/// BLE fallback transfer framing (PROTOCOL.md §6).
library;

import 'dart:typed_data';

/// Sentinel id signalling end of the whole transfer.
const int bleTransferEndId = 0xFFFFFFFF;

/// One data chunk notified on the Data characteristic.
class BleChunk {
  /// Creates a [BleChunk].
  const BleChunk({
    required this.id,
    required this.offset,
    required this.payload,
  });

  /// Parses a Data notification. Returns `null` for frames too short to
  /// carry a header or whose declared length disagrees with the payload —
  /// callers treat that as a gap and re-ack their last good offset.
  static BleChunk? parse(List<int> bytes) {
    if (bytes.length < 10) return null;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final len = data.getUint16(8, Endian.little);
    if (bytes.length != 10 + len) return null;
    return BleChunk(
      id: data.getUint32(0, Endian.little),
      offset: data.getUint32(4, Endian.little),
      payload: Uint8List.sublistView(Uint8List.fromList(bytes), 10),
    );
  }

  /// Capture id the chunk belongs to; [bleTransferEndId] ends the transfer.
  final int id;

  /// Byte offset of [payload] within the file.
  final int offset;

  /// Chunk payload; empty signals end of this file.
  final Uint8List payload;

  /// True when this chunk ends the current file.
  bool get isEndOfFile => payload.isEmpty && id != bleTransferEndId;

  /// True when this chunk ends the whole transfer.
  bool get isEndOfTransfer => id == bleTransferEndId;
}

/// Builds the 8-byte ack written to the Data ACK characteristic:
/// "I have file [id] contiguous through byte [nextOffset]."
Uint8List buildBleAck({required int id, required int nextOffset}) {
  final bytes = ByteData(8)
    ..setUint32(0, id, Endian.little)
    ..setUint32(4, nextOffset, Endian.little);
  return bytes.buffer.asUint8List();
}
