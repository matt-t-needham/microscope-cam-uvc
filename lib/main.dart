import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:gal/gal.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UVC Microscope',
      theme: ThemeData.dark(),
      home: CameraScreen(cameras: cameras),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraScreen({super.key, required this.cameras});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with TickerProviderStateMixin {
  CameraController? controller;
  int _selectedCameraIndex = 0;
  bool isRecording = false;
  bool flipOrientation = false;
  double brightness = 0.0;
  bool showControls = true;

  // Capture resolution — null until the first photo is taken
  Size? _captureResolution;

  late AnimationController _captureFlashController;
  late Animation<double> _captureFlashAnim;

  @override
  void initState() {
    super.initState();
    _captureFlashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    // Quick flash in, slow fade out
    _captureFlashAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 85),
    ]).animate(_captureFlashController);
    initCameraAt(0);
  }

  void initCameraAt(int index) {
    if (widget.cameras.isEmpty) return;
    controller = CameraController(
      widget.cameras[index],
      ResolutionPreset.max,
      enableAudio: true,
    );
    controller!.initialize().then((_) {
      if (!mounted) return;
      debugPrint(
        '[Camera] previewSize=${controller!.value.previewSize}  '
        'aspectRatio=${controller!.value.aspectRatio.toStringAsFixed(4)}  '
        'sensorOrientation=${widget.cameras[index].sensorOrientation}',
      );
      setState(() {});
    }).catchError((e) {
      debugPrint('[Camera] init error: $e');
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    _captureFlashController.dispose();
    super.dispose();
  }

  Future<void> captureImage() async {
    if (controller == null || !controller!.value.isInitialized) return;
    try {
      final image = await controller!.takePicture();
      await Gal.putImage(image.path, album: 'Microscope');
      if (mounted) {
        _captureFlashController.forward(from: 0);
      }
      // Read actual capture dimensions from the saved file
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
    if (controller == null || !controller!.value.isInitialized) return;
    if (isRecording) {
      try {
        final video = await controller!.stopVideoRecording();
        await Gal.putVideo(video.path, album: 'Microscope');
        setState(() => isRecording = false);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error stopping recording: $e')),
          );
        }
      }
    } else {
      try {
        await controller!.startVideoRecording();
        setState(() => isRecording = true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error starting recording: $e')),
          );
        }
      }
    }
  }

  void showCameraPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Select Camera',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const Divider(height: 1),
            ...widget.cameras.asMap().entries.map((entry) {
              final idx = entry.key;
              final cam = entry.value;
              final isSelected = idx == _selectedCameraIndex;
              return ListTile(
                leading: Icon(
                  _cameraIcon(cam),
                  color: isSelected ? Colors.white : Colors.white54,
                ),
                title: Text(
                  _cameraLabel(cam),
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                // Show the raw Android Camera2 ID — helps distinguish
                // logical cameras (e.g. two "Front" entries = physical + logical)
                subtitle: Text(
                  'Camera ID: ${cam.name}  ·  ${cam.sensorOrientation}° sensor',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                trailing: isSelected
                    ? const Icon(Icons.check, color: Colors.white)
                    : null,
                onTap: () async {
                  Navigator.pop(context);
                  if (idx == _selectedCameraIndex) return;
                  await controller?.dispose();
                  setState(() {
                    controller = null;
                    _selectedCameraIndex = idx;
                    _captureResolution = null; // reset for new camera
                  });
                  initCameraAt(idx);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _cameraLabel(CameraDescription cam) {
    switch (cam.lensDirection) {
      case CameraLensDirection.front:
        return 'Front Camera';
      case CameraLensDirection.back:
        return 'Rear Camera';
      case CameraLensDirection.external:
        return 'External Camera (USB)';
    }
  }

  IconData _cameraIcon(CameraDescription cam) {
    switch (cam.lensDirection) {
      case CameraLensDirection.front:
        return Icons.camera_front;
      case CameraLensDirection.back:
        return Icons.camera_rear;
      case CameraLensDirection.external:
        return Icons.usb;
    }
  }

  String get _streamResolutionLabel {
    final size = controller?.value.previewSize;
    if (size == null) return '—';
    final w = size.width > size.height ? size.width.toInt() : size.height.toInt();
    final h = size.width > size.height ? size.height.toInt() : size.width.toInt();
    return '${w}×${h}';
  }

  String get _captureResolutionLabel {
    final res = _captureResolution;
    if (res == null) return '—';
    final w = res.width > res.height ? res.width.toInt() : res.height.toInt();
    final h = res.width > res.height ? res.height.toInt() : res.width.toInt();
    return '${w}×${h}';
  }

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
                  value: flipOrientation,
                  onChanged: (value) {
                    setState(() => flipOrientation = value);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Brightness'),
                Expanded(
                  child: Slider(
                    value: brightness,
                    min: -1.0,
                    max: 1.0,
                    onChanged: (value) {
                      setState(() => brightness = value);
                      controller?.setExposureOffset(value);
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

  @override
  Widget build(BuildContext context) {
    if (widget.cameras.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.usb_off, size: 64, color: Colors.white54),
              SizedBox(height: 16),
              Text(
                'No camera detected',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              SizedBox(height: 8),
              Text(
                'Please connect your USB microscope',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final orientation = MediaQuery.of(context).orientation;
    final cameraAR = controller!.value.aspectRatio;
    final displayAR = orientation == Orientation.portrait
        ? (cameraAR > 1 ? 1.0 / cameraAR : cameraAR)
        : (cameraAR < 1 ? 1.0 / cameraAR : cameraAR);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => showControls = !showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview — centred at native aspect ratio, black bars fill rest
            Center(
              child: AspectRatio(
                aspectRatio: displayAR,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..scale(flipOrientation ? -1.0 : 1.0, 1.0),
                  child: CameraPreview(controller!),
                ),
              ),
            ),

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
            if (isRecording)
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
            if (showControls)
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
                      // Resolution readout — stream left, capture right
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Column(
                              children: [
                                const Text(
                                  'Stream',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                Text(
                                  _streamResolutionLabel,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              children: [
                                const Text(
                                  'Capture',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                Text(
                                  _captureResolutionLabel,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    letterSpacing: 0.5,
                                  ),
                                ),
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
                              isRecording
                                  ? Icons.stop_circle
                                  : Icons.videocam,
                              size: 32,
                            ),
                            onPressed: toggleRecording,
                            color: isRecording ? Colors.red : Colors.white,
                          ),
                          IconButton(
                            icon: const Icon(Icons.cameraswitch, size: 32),
                            onPressed: widget.cameras.length > 1
                                ? showCameraPicker
                                : null,
                            color: widget.cameras.length > 1
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
