/// IEEE (zlib) CRC-32, used to verify downloaded captures against their
/// manifest entries (PROTOCOL.md §4).
library;

import 'dart:typed_data';

final Uint32List _table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}

/// Computes the CRC-32 of [bytes], optionally continuing from a previous
/// [crc] so large files can be checksummed in streamed chunks.
int crc32(List<int> bytes, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _table[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
