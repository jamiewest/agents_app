// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Opens the barcode scanner as a full-screen modal and resolves with the
/// decoded value the user selects, or `null` if they cancel.
///
/// Backed by `mobile_scanner`. The caller decides what to do with the value —
/// the chat input inserts it into the message field so the agent can act on it.
Future<String?> scanBarcode(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (context) => const BarcodeScannerScreen(),
      ),
    );

/// A full-screen camera view that detects barcodes and QR codes and returns
/// the value the user taps.
///
/// This is a trimmed adaptation of the scanner in the WhereIsIt sample: it
/// keeps live detection, a framing overlay, a torch toggle, and a tap-to-use
/// list of detected codes, but drops the sample's lens-switching and
/// zoom-preset UI (which relied on a forked `mobile_scanner`).
class BarcodeScannerScreen extends StatefulWidget {
  /// Creates a [BarcodeScannerScreen].
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  /// The formats worth scanning for inventory intake: 2D codes used on asset
  /// labels plus the linear formats used on service tags and retail packaging.
  static const List<BarcodeFormat> _formats = [
    BarcodeFormat.qrCode,
    BarcodeFormat.dataMatrix,
    BarcodeFormat.aztec,
    BarcodeFormat.pdf417,
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.codabar,
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.itf14,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
  ];

  final MobileScannerController _controller = MobileScannerController(
    formats: _formats,
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  final List<String> _detectedValues = [];
  bool _showInstructions = true;

  @override
  void initState() {
    super.initState();
    // The MobileScanner widget starts the camera (autoStart is true); we only
    // fade the instructions out after a moment.
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showInstructions = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Reads a usable string from a [Barcode], preferring the decoded value and
  /// falling back to raw bytes (UTF-8, then hex) for binary payloads.
  String? _extractBarcodeValue(Barcode barcode) {
    final raw = barcode.rawValue?.trim();
    if (raw != null && raw.isNotEmpty) return raw;

    final display = barcode.displayValue?.trim();
    if (display != null && display.isNotEmpty) return display;

    final bytes = switch (barcode.rawDecodedBytes) {
      DecodedBarcodeBytes(:final bytes) => bytes,
      DecodedVisionBarcodeBytes(:final bytes, :final rawBytes) =>
        bytes ?? rawBytes,
      null => null,
    };
    if (bytes != null && bytes.isNotEmpty) {
      try {
        final decoded = utf8.decode(bytes);
        if (decoded.trim().isNotEmpty) return decoded;
      } on FormatException {
        // Fall through to a hex representation for non-text payloads.
      }
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
    return null;
  }

  void _handleDetection(BarcodeCapture capture) {
    if (!mounted) return;
    final values = capture.barcodes
        .map(_extractBarcodeValue)
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);

    setState(() {
      for (final value in values) {
        if (_detectedValues.contains(value)) continue;
        _detectedValues.add(value);
        if (_detectedValues.length > 12) _detectedValues.removeAt(0);
      }
    });
  }

  Future<void> _selectValue(String value) async {
    // Stop the camera before navigating away to avoid snapshot errors on iOS.
    await _controller.stop();
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      title: const Text('Scan Barcode'),
      backgroundColor: Colors.black.withValues(alpha: 0.5),
      foregroundColor: Colors.white,
      elevation: 0,
      actions: [_TorchButton(controller: _controller)],
    ),
    body: Stack(
      children: [
        MobileScanner(controller: _controller, onDetect: _handleDetection),
        CustomPaint(painter: _ScannerOverlay(), child: const SizedBox.expand()),
        if (_detectedValues.isNotEmpty)
          _DetectedCodesList(
            values: _detectedValues,
            onSelect: _selectValue,
          ),
        if (_showInstructions)
          Positioned(
            bottom: 32,
            left: 32,
            right: 32,
            child: GestureDetector(
              onTap: () => setState(() => _showInstructions = false),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Point the camera at a barcode or QR code, then tap the '
                  'detected value to use it.',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A torch (flashlight) toggle that reflects the camera's current torch state
/// and hides itself when the device has no torch.
class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.controller});

  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, MobileScannerState state, child) {
      switch (state.torchState) {
        case TorchState.unavailable:
          return const SizedBox.shrink();
        case TorchState.on:
        case TorchState.auto:
          return IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.amber),
            onPressed: controller.toggleTorch,
          );
        case TorchState.off:
          return IconButton(
            icon: const Icon(Icons.flash_off, color: Colors.white),
            onPressed: controller.toggleTorch,
          );
      }
    },
  );
}

/// The overlay list of detected codes, anchored above the bottom instructions.
class _DetectedCodesList extends StatelessWidget {
  const _DetectedCodesList({required this.values, required this.onSelect});

  final List<String> values;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 16,
    right: 16,
    bottom: 140,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Detected codes (tap to use)',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: values.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final value = values[values.length - 1 - index];
                return ListTile(
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  title: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () => onSelect(value),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// Dims the screen outside a centered cutout and draws corner brackets to help
/// the user frame a code.
class _ScannerOverlay extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.7,
      height: size.height * 0.4,
    );

    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutoutPath = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, backgroundPath, cutoutPath),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    const cornerLength = 30.0;

    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(cornerLength, 0),
      borderPaint,
    );
    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(0, cornerLength),
      borderPaint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight + const Offset(-cornerLength, 0),
      borderPaint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight + const Offset(0, cornerLength),
      borderPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(cornerLength, 0),
      borderPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(0, -cornerLength),
      borderPaint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(-cornerLength, 0),
      borderPaint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(0, -cornerLength),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
