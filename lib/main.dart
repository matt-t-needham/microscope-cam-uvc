import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';

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

class _CameraScreenState extends State<CameraScreen> {
  CameraController? controller;
  bool isRecording = false;
  bool flipOrientation = false;
  double brightness = 0.0;
  bool showControls = true;

  @override
  void initState() {
    super.initState();
    initCamera();
  }

  void initCamera() {
    if (widget.cameras.isEmpty) {
      return;
    }
    controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.high,
      enableAudio: true,
    );
    controller!.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    }).catchError((e) {
      // Error initializing camera
    });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  Future<void> captureImage() async {
    if (controller == null || !controller!.value.isInitialized) {
      return;
    }
    try {
      final image = await controller!.takePicture();
      final directory = await getApplicationDocumentsDirectory();
      final imagePath = '${directory.path}/microscope_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(image.path).copy(imagePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image saved: $imagePath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error capturing image: $e')),
        );
      }
    }
  }

  Future<void> toggleRecording() async {
    if (controller == null || !controller!.value.isInitialized) {
      return;
    }
    if (isRecording) {
      try {
        final video = await controller!.stopVideoRecording();
        final directory = await getApplicationDocumentsDirectory();
        final videoPath = '${directory.path}/microscope_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await File(video.path).copy(videoPath);
        setState(() {
          isRecording = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Video saved: $videoPath')),
          );
        }
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
        setState(() {
          isRecording = true;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error starting recording: $e')),
          );
        }
      }
    }
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
                    setState(() {
                      flipOrientation = value;
                    });
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
                      setState(() {
                        brightness = value;
                      });
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          setState(() {
            showControls = !showControls;
          });
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()..scale(flipOrientation ? -1.0 : 1.0, 1.0),
              child: CameraPreview(controller!),
            ),
            if (isRecording)
              Positioned(
                top: 48,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.fiber_manual_record, size: 16, color: Colors.white),
                      SizedBox(width: 4),
                      Text('REC', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
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
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.camera_alt, size: 32),
                        onPressed: captureImage,
                        color: Colors.white,
                      ),
                      IconButton(
                        icon: Icon(
                          isRecording ? Icons.stop_circle : Icons.videocam,
                          size: 32,
                        ),
                        onPressed: toggleRecording,
                        color: isRecording ? Colors.red : Colors.white,
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings, size: 32),
                        onPressed: showSettingsDialog,
                        color: Colors.white,
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
