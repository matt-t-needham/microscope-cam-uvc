PRD: UVC Microscope Viewer — Android App

Goal
A simple Android app that connects to a USB UVC microscope and provides a live fullscreen view, still image capture, and video recording. Built specifically for use with the Teslong MS100-C or any standard UVC-compliant USB microscope.
Target Platforms

Android only (min SDK 24 / Android 7.0+)

Core Principles

As few features as possible
No network access, no accounts, no cloud
Fast to open, immediately useful when microscope is plugged in


User Stories

 1. Connect to device — On launch, the app detects any connected USB device and checks if it presents as a UVC device. If found, it requests USB permission and opens the stream automatically.
 2. Live view — Displays the UVC stream fullscreen with minimal UI overlay. Stream is live and low-latency.
 3. Capture still image — A single button tap captures the current frame and saves it as a JPEG to the device gallery.
 4. Record video — A start/stop toggle records the stream as an MP4 and saves it to the device gallery. A visible indicator shows when recording is active.
 5. Brightness adjustment — Settings panel exposes brightness control, mapped to the UVC brightness control if supported by the device.
 6. Orientation flip — Settings panel includes a toggle to flip the image orientation (front/rear).
 7. Disconnection handling — App gracefully handles device disconnection mid-session and reconnection, returning to live view automatically when the device is plugged back in.
 8. Empty state — When no USB device is detected, show a clear prompt instructing the user to connect their USB microscope.


Tech Stack

Kotlin (Android native)
libuvccamera — UVC device interfacing and frame capture
AndroidX — UI components
MediaMuxer — MP4 video encoding from raw UVC frames
No backend, no proprietary SDKs


Permissions

USB_HOST — communicate with USB device
WRITE_EXTERNAL_STORAGE — save images and video to gallery
No CAMERA permission (bypasses Android camera API entirely)


Data Model
No persistence required. All state is session-based.

Out of Scope

Timelapse
Zoom controls
Any cloud or sharing functionality
iOS support


Completion Signal
Output <promise>COMPLETE</promise> when:

All 8 user stories are implemented
App builds successfully: ./gradlew assembleDebug
./gradlew lint returns no errors