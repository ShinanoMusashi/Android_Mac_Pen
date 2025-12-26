# Android Mac Pen - Christmas Break Improvements

## Project Overview

Android tablet pen input system with two modes:
- **Touchpad/Cursor Mode**: Use tablet as a Mac trackpad with pen
- **Screen Mirror Mode**: Mirror Mac screen to tablet with pen control

---

## Task Checklist

### Task 1: Disconnect Popup in Cursor Mode
- [ ] **Status**: Not started
- **Problem**: No popup notification when disconnected in Touchpad mode (unlike Monitor mode behavior expected)
- **Current Behavior**: Both modes just change status text color to red, no actual popup exists in either
- **Solution**: Add overlay/dialog that appears on unexpected disconnect
- **Files to modify**:
  - `Android/app/src/main/java/com/example/tabletpen/ui/TouchpadFragment.kt`
  - Consider creating `DisconnectOverlayView.kt` or use AlertDialog

---

### Task 2: Performance Stats Overlay (Monitor Mode)
- [ ] **Status**: Not started
- **Problem**: No way to see latency, FPS, resolution, etc. during mirroring
- **Features needed**:
  - [ ] Real-time latency display (ms)
  - [ ] Decoded FPS counter
  - [ ] Current resolution display
  - [ ] Bitrate indicator
  - [ ] Dropped frame counter
  - [ ] Toggle button to show/hide stats
- **Files to modify**:
  - `Android/app/src/main/java/com/example/tabletpen/ui/MirrorFragment.kt`
  - `Android/app/src/main/java/com/example/tabletpen/mirror/VideoDecoder.kt`
  - `Android/app/res/layout/fragment_mirror.xml`

---

### Task 3: Fix High Latency Issues
- [ ] **Status**: Not started
- **Problem**: Noticeable delay between pen movement and screen response
- **Current latency sources**:
  | Source | Current | Target |
  |--------|---------|--------|
  | Network (WiFi) | 5-20ms | 1-2ms (USB) |
  | H.264 Encoding | ~16ms | ~16ms (1 frame) |
  | Decode Queue | 30 frames | 5-10 frames |
  | Display | ~16ms | VSync bound |
- **Optimizations**:
  - [ ] Reduce decode queue: `LinkedBlockingQueue(30)` → `LinkedBlockingQueue(5)` in `VideoDecoder.kt:25`
  - [ ] Add frame timestamp validation (drop stale frames)
  - [ ] Implement PING/PONG latency measurement
  - [ ] Consider adaptive bitrate based on measured latency
- **Files to modify**:
  - `Android/app/src/main/java/com/example/tabletpen/mirror/VideoDecoder.kt`
  - `Android/app/src/main/java/com/example/tabletpen/mirror/MirrorClient.kt`
  - `TabletPenMac/TabletPenMac/PenServer.swift`
  - `TabletPenMac/TabletPenMac/VideoEncoder.swift`

---

### Task 4: Fix Low Resolution Issues
- [ ] **Status**: Not started
- **Problem**: Resolution is hardcoded, may appear blurry on high-DPI tablets
- **Current config** (hardcoded in VideoEncoder.swift):
  ```swift
  width: 1920, height: 1080  // Fixed
  bitrate: 15_000_000        // 15 Mbps fixed
  ```
- **Solution**:
  - [ ] Add resolution selection in Android UI (720p, 1080p, 1440p, native)
  - [ ] Add quality presets (Low/Medium/High/Ultra)
  - [ ] Send resolution preference to Mac via protocol
  - [ ] Display actual resolution in stats overlay
- **Files to modify**:
  - `Android/app/src/main/java/com/example/tabletpen/ui/MirrorFragment.kt`
  - `Android/app/src/main/java/com/example/tabletpen/protocol/MessageType.kt`
  - `TabletPenMac/TabletPenMac/VideoEncoder.swift`
  - `TabletPenMac/TabletPenMac/ScreenCapture.swift`

---

### Task 5: USB/Wired Connection Support
- [ ] **Status**: Not started
- **Problem**: WiFi-only connection has latency and requires manual IP entry
- **Solution**: Support USB via ADB port forwarding
- **How it works**:
  ```bash
  # User runs on Mac terminal:
  adb forward tcp:9876 tcp:9876

  # Android connects to 127.0.0.1:9876 (localhost)
  ```
- **Implementation**:
  - [ ] Detect USB connection state on Android
  - [ ] Add "USB Mode" toggle in HomeFragment
  - [ ] Auto-fill 127.0.0.1 when USB mode selected
  - [ ] Add connection type indicator (WiFi/USB icon)
  - [ ] Show instructions for running ADB command
  - [ ] Auto-detect wired vs wireless and suggest optimal settings
- **Files to modify**:
  - `Android/app/src/main/java/com/example/tabletpen/ui/HomeFragment.kt`
  - Create new `ConnectionManager.kt`
  - Update `PenClient.kt` and `MirrorClient.kt`

---

## Priority Order (Suggested)

1. **Task 2** - Performance Stats Overlay (helps debug everything else)
2. **Task 3** - Implement latency measurement first (part of Task 2)
3. **Task 1** - Disconnect Popup (quick UI improvement)
4. **Task 3** - Fix latency (verify with stats)
5. **Task 4** - Fix resolution (add UI controls)
6. **Task 5** - USB Support (biggest change, save for last)

---

## Key Files Reference

```
Android_Mac_Pen/
├── Android/app/src/main/java/com/example/tabletpen/
│   ├── MainActivity.kt           # Navigation host
│   ├── PenClient.kt              # Touchpad TCP client
│   ├── PenData.kt                # Pen event data model
│   ├── PenInputView.kt           # Custom touch input view
│   ├── ui/
│   │   ├── HomeFragment.kt       # Mode selection screen
│   │   ├── TouchpadFragment.kt   # Cursor mode UI
│   │   └── MirrorFragment.kt     # Mirror mode UI
│   ├── mirror/
│   │   ├── MirrorClient.kt       # Mirror TCP client
│   │   └── VideoDecoder.kt       # H.264 MediaCodec decoder
│   └── protocol/
│       ├── MessageType.kt        # Protocol message types
│       └── ProtocolCodec.kt      # Binary encode/decode
│
├── TabletPenMac/TabletPenMac/
│   ├── main.swift                # App entry, menu bar
│   ├── PenServer.swift           # TCP server
│   ├── CursorController.swift    # Mac cursor control
│   ├── ScreenCapture.swift       # CGDisplayStream capture
│   ├── VideoEncoder.swift        # H.264 VideoToolbox encoder
│   └── ProtocolMessage.swift     # Binary protocol
│
├── TECHNICAL_DOCUMENTATION.md    # Existing detailed docs
└── IMPROVEMENT_TASKS.md          # This file
```

---

## Protocol Message Types (for reference)

| Type | Code | Direction | Purpose |
|------|------|-----------|---------|
| PEN_DATA | 0x01 | Android → Mac | Pen position, pressure, tilt |
| MODE_REQUEST | 0x02 | Android → Mac | Request mode change |
| MODE_ACK | 0x03 | Mac → Android | Confirm mode |
| VIDEO_FRAME | 0x10 | Mac → Android | H.264 encoded frame |
| VIDEO_CONFIG | 0x11 | Mac → Android | Resolution, FPS, bitrate |
| PING | 0xF0 | Either | Latency measurement |
| PONG | 0xF1 | Either | Latency response |

---

## Notes

- PING/PONG messages exist in protocol but are NOT implemented yet
- Current video: H.264 Main profile, CAVLC entropy, no B-frames
- Hardware acceleration: VideoToolbox (Mac), MediaCodec (Android)
- TCP_NODELAY already enabled (Nagle disabled)

---

## Progress Log

| Date | Task | Status | Notes |
|------|------|--------|-------|
| Dec 26, 2024 | Project Analysis | Done | Identified all improvement areas |
| | | | |
| | | | |

