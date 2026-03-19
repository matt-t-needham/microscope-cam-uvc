import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uvccamera/uvccamera.dart';

// ---------------------------------------------------------------------------
// Active-camera union type
// ---------------------------------------------------------------------------

sealed class _ActiveCamera {}

class _BuiltinCamera extends _ActiveCamera {
  final CameraController controller;
  final CameraDescription description;
  _BuiltinCamera(this.controller, this.description);
}

class _UvcCamera extends _ActiveCamera {
  final UvcCameraController controller;
  final UvcCameraDevice device;
  _UvcCamera(this.controller, this.device);
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UVC Microscope',
      theme: ThemeData.dark(),
      home: const CameraScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Main screen
// ---------------------------------------------------------------------------

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with TickerProviderStateMixin {
  // Discovery results
  List<CameraDescription> _builtinCameras = [];
  List<UvcCameraDevice> _uvcDevices = [];

  // Active camera (null = initialising or nothing available)
  _ActiveCamera? _active;

  bool _isRecording = false;
  bool _flipOrientation = false;
  int _extraRotationTurns = 0; // 0–3 → 0°/90°/180°/270°
  double _brightness = 0.0;
  bool _showControls = true;
  Size? _captureResolution;

  // Flash animation
  late AnimationController _captureFlashController;
  late Animation<double> _captureFlashAnim;

  // USB hotplug
  StreamSubscription<UvcCameraDeviceEvent>? _uvcEventSub;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _captureFlashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _captureFlashAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 85),
    ]).animate(_captureFlashController);

    _initAll();
    _listenUvcEvents();
  }

  @override
  void dispose() {
    _uvcEventSub?.cancel();
    _captureFlashController.dispose();
    _disposeActive();
    super.dispose();
  }

  void _disposeActive() {
    switch (_active) {
      case _BuiltinCamera c:
        c.controller.dispose();
      case _UvcCamera c:
        c.controller.dispose();
      case null:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  Future<void> _initAll() async {
    await _requestPermissions();

    final builtins = await availableCameras();
    final uvcMap = await UvcCamera.getDevices();
    final uvcs = uvcMap.values.toList();

    if (!mounted) return;
    setState(() {
      _builtinCameras = builtins;
      _uvcDevices = uvcs;
    });

    // Prefer UVC (the whole point of this app), fall back to built-in
    if (uvcs.isNotEmpty) {
      await _activateUvc(uvcs.first);
    } else if (builtins.isNotEmpty) {
      await _activateBuiltin(builtins.first);
    }
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera].request();
  }

  // ---------------------------------------------------------------------------
  // USB hotplug
  // ---------------------------------------------------------------------------

  void _listenUvcEvents() {
    _uvcEventSub = UvcCamera.deviceEventStream.listen((event) async {
      final uvcMap = await UvcCamera.getDevices();
      if (!mounted) return;
      setState(() => _uvcDevices = uvcMap.values.toList());

      if (event.type == UvcCameraDeviceEventType.attached && _active == null) {
        await _activateUvc(event.device);
      }

      if (event.type == UvcCameraDeviceEventType.detached) {
        if (_active case _UvcCamera c
            when c.device.name == event.device.name) {
          await _deactivate();
          if (!mounted) return;
          if (_builtinCameras.isNotEmpty) {
            await _activateBuiltin(_builtinCameras.first);
          }
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Activation helpers
  // ---------------------------------------------------------------------------

  Future<void> _activateBuiltin(CameraDescription cam) async {
    await _deactivate();
    final c = CameraController(cam, ResolutionPreset.max, enableAudio: true);
    await c.initialize();
    if (!mounted) return;
    debugPrint(
      '[Camera/builtin] previewSize=${c.value.previewSize}  '
      'aspectRatio=${c.value.aspectRatio.toStringAsFixed(4)}  '
      'sensorOrientation=${cam.sensorOrientation}',
    );
    setState(() {
      _active = _BuiltinCamera(c, cam);
      _captureResolution = null;
    });
  }

  Future<void> _activateUvc(UvcCameraDevice device) async {
    await _deactivate();
    final granted = await UvcCamera.requestDevicePermission(device);
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'USB permission denied for ${device.name}')),
        );
      }
      return;
    }
    final c = UvcCameraController(
      device: device,
      resolutionPreset: UvcCameraResolutionPreset.max,
    );
    await c.initialize();
    if (!mounted) return;
    debugPrint('[Camera/uvc] device=${device.name}  '
        'previewMode=${c.value.previewMode}');
    setState(() {
      _active = _UvcCamera(c, device);
      _captureResolution = null;
    });
  }

  Future<void> _deactivate() async {
    final prev = _active;
    if (mounted) setState(() => _active = null);
    switch (prev) {
      case _BuiltinCamera c:
        await c.controller.dispose();
      case _UvcCamera c:
        await c.controller.dispose();
      case null:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Capture / record
  // ---------------------------------------------------------------------------

  Future<void> captureImage() async {
    try {
      final XFile image = switch (_active) {
        _BuiltinCamera c => await c.controller.takePicture(),
        _UvcCamera c => await c.controller.takePicture(),
        null => throw StateError('no camera'),
      };
      await Gal.putImage(image.path, album: 'Microscope');
      if (mounted) _captureFlashController.forward(from: 0);
      _updateCaptureResolution(image.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error capturing image: $e')),
        );
      }
    }
  }

  Future<void> _updateCaptureResolution(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (mounted) {
        setState(() => _captureResolution =
            Size(descriptor.width.toDouble(), descriptor.height.toDouble()));
      }
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {}
  }

  Future<void> toggleRecording() async {
    if (_isRecording) {
      try {
        final XFile video = switch (_active) {
          _BuiltinCamera c => await c.controller.stopVideoRecording(),
          _UvcCamera c => await c.controller.stopVideoRecording(),
          null => throw StateError('no camera'),
        };
        await Gal.putVideo(video.path, album: 'Microscope');
        if (mounted) setState(() => _isRecording = false);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error stopping recording: $e')),
          );
        }
      }
    } else {
      try {
        switch (_active) {
          case _BuiltinCamera c:
            await c.controller.startVideoRecording();
          case _UvcCamera c:
            final mode = c.controller.value.previewMode;
            if (mode == null) throw StateError('preview not ready');
            await c.controller.startVideoRecording(mode);
          case null:
            throw StateError('no camera');
        }
        if (mounted) setState(() => _isRecording = true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error starting recording: $e')),
          );
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Camera picker
  // ---------------------------------------------------------------------------

  void showCameraPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text('Select Camera',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // UVC cameras — listed first
                  if (_uvcDevices.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('USB / UVC',
                            style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                                letterSpacing: 1.2)),
                      ),
                    ),
                    ..._uvcDevices.map((device) {
                      final isSelected = _active is _UvcCamera &&
                          (_active as _UvcCamera).device.name == device.name;
                      final label = device.name.isNotEmpty ? device.name : 'USB Camera';
                      final sub =
                          'VID:${device.vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}  '
                          'PID:${device.productId.toRadixString(16).toUpperCase().padLeft(4, '0')}';
                      return ListTile(
                        leading: Icon(Icons.usb,
                            color: isSelected ? Colors.white : Colors.white54),
                        title: Text(label,
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            )),
                        subtitle: Text(sub,
                            style: const TextStyle(color: Colors.white38, fontSize: 11)),
                        trailing: isSelected
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                        onTap: () async {
                          Navigator.pop(context);
                          if (isSelected) return;
                          await _activateUvc(device);
                        },
                      );
                    }),
                  ],

                  // Built-in cameras — listed second
                  if (_builtinCameras.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('BUILT-IN',
                            style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                                letterSpacing: 1.2)),
                      ),
                    ),
                    ..._builtinCameras.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final cam = entry.value;
                      final isSelected = _active is _BuiltinCamera &&
                          (_active as _BuiltinCamera).description == cam;
                      return ListTile(
                        leading: Icon(
                          cam.lensDirection == CameraLensDirection.front
                              ? Icons.camera_front
                              : Icons.camera_rear,
                          color: isSelected ? Colors.white : Colors.white54,
                        ),
                        title: Text(
                          cam.lensDirection == CameraLensDirection.front
                              ? 'Front Camera'
                              : cam.lensDirection == CameraLensDirection.back
                                  ? 'Rear Camera'
                                  : 'External Camera',
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.white70,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          'Camera ID: ${cam.name}  ·  ${cam.sensorOrientation}° sensor',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                        onTap: () async {
                          Navigator.pop(context);
                          if (isSelected) return;
                          await _activateBuiltin(_builtinCameras[idx]);
                        },
                      );
                    }),
                  ],

                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  void showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Flip Orientation'),
                Switch(
                  value: _flipOrientation,
                  onChanged: (value) {
                    setState(() => _flipOrientation = value);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            StatefulBuilder(
              builder: (context, setLocal) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Rotate'),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.rotate_left),
                        onPressed: () {
                          setState(() => _extraRotationTurns = (_extraRotationTurns + 3) % 4);
                          setLocal(() {});
                        },
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${_extraRotationTurns * 90}°',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.rotate_right),
                        onPressed: () {
                          setState(() => _extraRotationTurns = (_extraRotationTurns + 1) % 4);
                          setLocal(() {});
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Brightness'),
                Expanded(
                  child: Slider(
                    value: _brightness,
                    min: -1.0,
                    max: 1.0,
                    onChanged: (value) {
                      setState(() => _brightness = value);
                      if (_active case _BuiltinCamera c) {
                        c.controller.setExposureOffset(value);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Resolution labels
  // ---------------------------------------------------------------------------

  String get _streamResolutionLabel {
    switch (_active) {
      case _BuiltinCamera c:
        final size = c.controller.value.previewSize;
        if (size == null) return '—';
        final w =
            size.width > size.height ? size.width.toInt() : size.height.toInt();
        final h =
            size.width > size.height ? size.height.toInt() : size.width.toInt();
        return '${w}×${h}';
      case _UvcCamera c:
        final mode = c.controller.value.previewMode;
        if (mode == null) return '—';
        return '${mode.frameWidth}×${mode.frameHeight}';
      case null:
        return '—';
    }
  }

  String get _captureResolutionLabel {
    final res = _captureResolution;
    if (res == null) return '—';
    final w =
        res.width > res.height ? res.width.toInt() : res.height.toInt();
    final h =
        res.width > res.height ? res.height.toInt() : res.width.toInt();
    return '${w}×${h}';
  }

  // ---------------------------------------------------------------------------
  // Preview builders
  // ---------------------------------------------------------------------------

  Widget _buildPreview() {
    return switch (_active) {
      _BuiltinCamera c => _buildBuiltinPreview(c),
      _UvcCamera c => _buildUvcPreview(c),
      null => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _buildBuiltinPreview(_BuiltinCamera active) {
    final orientation = MediaQuery.of(context).orientation;
    final cameraAR = active.controller.value.aspectRatio;
    final baseAR = orientation == Orientation.portrait
        ? (cameraAR > 1 ? 1.0 / cameraAR : cameraAR)
        : (cameraAR < 1 ? 1.0 / cameraAR : cameraAR);
    // Odd rotation turns swap portrait↔landscape, so invert the AR
    final effectiveAR = _extraRotationTurns % 2 == 0 ? baseAR : 1.0 / baseAR;

    return Center(
      child: AspectRatio(
        aspectRatio: effectiveAR,
        child: RotatedBox(
          quarterTurns: _extraRotationTurns,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scale(_flipOrientation ? -1.0 : 1.0, 1.0),
            child: CameraPreview(active.controller),
          ),
        ),
      ),
    );
  }

  Widget _buildUvcPreview(_UvcCamera active) {
    return ValueListenableBuilder<UvcCameraControllerState>(
      valueListenable: active.controller,
      builder: (_, state, __) {
        if (!state.isInitialized) {
          return const Center(child: CircularProgressIndicator());
        }
        final mode = state.previewMode;
        final baseAr =
            mode != null ? mode.frameWidth / mode.frameHeight : 16.0 / 9.0;
        final effectiveAr = _extraRotationTurns % 2 == 0 ? baseAr : 1.0 / baseAr;
        return Center(
          child: AspectRatio(
            aspectRatio: effectiveAr,
            child: RotatedBox(
              quarterTurns: _extraRotationTurns,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..scale(_flipOrientation ? -1.0 : 1.0, 1.0),
                child: UvcCameraPreview(active.controller),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  bool get _hasCameras =>
      _builtinCameras.isNotEmpty || _uvcDevices.isNotEmpty;

  bool get _isInitialised => switch (_active) {
        _BuiltinCamera c => c.controller.value.isInitialized,
        _UvcCamera c => c.controller.value.isInitialized,
        null => false,
      };

  int get _totalCameras => _builtinCameras.length + _uvcDevices.length;

  @override
  Widget build(BuildContext context) {
    // Still discovering
    if (_active == null && !_hasCameras) {
      // Only show "no camera" if we've finished init (give it a moment)
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.usb_off, size: 64, color: Colors.white54),
              SizedBox(height: 16),
              Text('No camera detected',
                  style: TextStyle(color: Colors.white, fontSize: 18)),
              SizedBox(height: 8),
              Text(
                'Plug in your USB microscope\nor grant camera permissions',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialised) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview
            _buildPreview(),

            // Left/right screen-edge capture flash
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _captureFlashAnim,
                builder: (_, __) {
                  if (_captureFlashAnim.value == 0) {
                    return const SizedBox.shrink();
                  }
                  final opacity = _captureFlashAnim.value * 0.85;
                  return Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.white.withOpacity(opacity),
                          Colors.transparent,
                          Colors.transparent,
                          Colors.white.withOpacity(opacity),
                        ],
                        stops: const [0.0, 0.2, 0.8, 1.0],
                      ),
                    ),
                  );
                },
              ),
            ),

            // REC badge
            if (_isRecording)
              Positioned(
                top: 48,
                right: 16,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.fiber_manual_record,
                          size: 16, color: Colors.white),
                      SizedBox(width: 4),
                      Text('REC',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),

            // Controls
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.8),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Resolution readout
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Column(
                              children: [
                                const Text('Stream',
                                    style: TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10,
                                        letterSpacing: 0.5)),
                                Text(_streamResolutionLabel,
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        letterSpacing: 0.5)),
                              ],
                            ),
                            Column(
                              children: [
                                const Text('Capture',
                                    style: TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10,
                                        letterSpacing: 0.5)),
                                Text(_captureResolutionLabel,
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        letterSpacing: 0.5)),
                              ],
                            ),
                          ],
                        ),
                      ),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.camera_alt, size: 32),
                            onPressed: captureImage,
                            color: Colors.white,
                          ),
                          IconButton(
                            icon: Icon(
                              _isRecording
                                  ? Icons.stop_circle
                                  : Icons.videocam,
                              size: 32,
                            ),
                            onPressed: toggleRecording,
                            color: _isRecording ? Colors.red : Colors.white,
                          ),
                          IconButton(
                            icon: const Icon(Icons.cameraswitch, size: 32),
                            onPressed:
                                _totalCameras > 1 ? showCameraPicker : null,
                            color: _totalCameras > 1
                                ? Colors.white
                                : Colors.white30,
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings, size: 32),
                            onPressed: showSettingsDialog,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
