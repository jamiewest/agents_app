// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;

/// Opens the camera as a full-screen modal on macOS and resolves with the
/// captured photo, or `null` if the user cancels.
///
/// `image_picker` has no camera support on desktop, so this fills the gap
/// with `camera_macos`. The captured bytes are written to a temporary file so
/// the returned [XFile] has a real path and name, matching what
/// `ImagePicker.pickImage` produces on mobile.
Future<XFile?> takePhotoMacOS(BuildContext context) =>
    Navigator.of(context).push<XFile>(
      MaterialPageRoute<XFile>(
        fullscreenDialog: true,
        builder: (context) => const MacOSCameraScreen(),
      ),
    );

/// A full-screen camera preview with a shutter button that returns the
/// captured photo as an [XFile].
class MacOSCameraScreen extends StatefulWidget {
  /// Creates a [MacOSCameraScreen].
  const MacOSCameraScreen({super.key});

  @override
  State<MacOSCameraScreen> createState() => _MacOSCameraScreenState();
}

class _MacOSCameraScreenState extends State<MacOSCameraScreen> {
  CameraMacOSController? _controller;
  bool _capturing = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_controller?.destroy());
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _capturing) return;
    setState(() {
      _capturing = true;
      _error = null;
    });
    try {
      final capture = await controller.takePicture();
      final bytes = capture?.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw CameraMacOSException(message: 'The camera returned no image.');
      }
      final dir = await Directory.systemTemp.createTemp('agents_photo');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}${Platform.pathSeparator}photo_$stamp.jpg');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      Navigator.of(context).pop(XFile(file.path, mimeType: 'image/jpeg'));
    } on CameraMacOSException catch (ex) {
      setState(() => _error = ex.message.isEmpty ? ex.toJson() : ex.message);
    } on Exception catch (ex) {
      setState(() => _error = ex.toString());
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      title: const Text('Take Photo'),
      backgroundColor: Colors.black.withValues(alpha: 0.5),
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    body: Stack(
      children: [
        Positioned.fill(
          child: CameraMacOSView(
            cameraMode: CameraMacOSMode.photo,
            pictureFormat: PictureFormat.jpeg,
            enableAudio: false,
            fit: BoxFit.contain,
            onCameraInizialized: (controller) =>
                setState(() => _controller = controller),
            onCameraLoading: (_) => const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        ),
        if (_error != null)
          Positioned(
            bottom: 120,
            left: 32,
            right: 32,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Center(child: _ShutterButton(onPressed: _capture)),
        ),
      ],
    ),
  );
}

/// A round white shutter button in the style of the system camera apps.
class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onPressed,
    child: Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 4),
      ),
      padding: const EdgeInsets.all(4),
      child: const DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white),
      ),
    ),
  );
}
