# Session Status - Android Mac Pen

**Last Updated**: 2026-09-23 (Session 3)

---

## Most Recent Session (2026-09-23 - Session 3)

**Focus**: Reviving the Mac side + fixing USB mirror video, then latency/quality tuning.

**Environment setup (Mac side)**:
- Build/run via `Mac/bundle.sh` → produces `Mac/TabletPenMac.app` (ad-hoc signed).
  The `.app` bundle is REQUIRED — a bare SwiftPM binary can't hold a Screen Recording grant.
- Screen Recording permission must be granted to `TabletPenMac.app` (System Settings → Privacy).
- USB mode needs `adb reverse tcp:9876 tcp:9876` and `adb reverse tcp:9877 tcp:9877`
  (re-run after every replug / adb restart). Android USB toggle → connects to 127.0.0.1.

**Bugs fixed**:
- USB video was black: Mac sent video via UDP to 127.0.0.1 (loops back). Now auto-forces
  TCP video for loopback clients (`main.swift`, in the client-connect handler).
- Encoder failed every frame with -12905 on the 16" MBP (1728x1117): odd height. Now rounds
  output dimensions down to even (`main.swift`).

**Latency/quality work**:
- Network-paced pipeline: encode is gated on send-drain; stale frames dropped at the CAPTURE
  input (never post-encode → no more delta-chain corruption). See `encodeNextFrameIfReady()`.
- Pipeline depth = 2 (`maxFramesInFlight`) to absorb adb-tunnel jitter (motion stutter).
- Keyframe interval 1s → 5s (fewer big I-frame bursts; TCP is lossless so recovery not needed).
- USB bitrate capped on Mac side (`usbBitrateCapMbps`, currently 70). Measured USB link:
  USB 2.0, ~258 Mbps real throughput — bandwidth is NOT the limiter, jitter is.

**Status**: USB mirror works well. Minor: brief color blocks at connect until first keyframe.

**Uncommitted**: all Session 3 Mac changes + earlier WIP are unstaged (see `git status`).

---

## Quick Summary

Android tablet pen input system with two modes:
- **Touchpad Mode**: Tablet acts as Mac trackpad with pen
- **Screen Mirror Mode**: Mac screen streamed to tablet with pen control

---

## Current Work Status

### Most Recent Session (2025-12-30 - Session 2)
**What was happening**: Increased video quality settings (reversed previous lowering)

**Changes made**:
- Modified `Mac/TabletPenMac/VideoEncoder.swift`:
  - Bitrate: 4 Mbps → 8 Mbps (line 62)
  - Quality: 0.5 → 0.75 (line 229)

**Current state**: App built and running successfully

---

### Previous Session (2025-12-30 - Session 1)
**What happened**: Fixed unsafe pointer handling in `VideoDecoder.swift`

**Changes made**:
- Modified `Mac/TabletPenMac/VideoDecoder.swift`:
  - Fixed `createHEVCFormatDescription()` - pointer lifetime issue
  - Fixed `createH264FormatDescription()` - pointer lifetime issue
  - Used proper `withUnsafeBufferPointer` nesting to ensure pointer validity

---

## Task Progress

| Task | Status | Notes |
|------|--------|-------|
| Task 1: Disconnect Popup | DONE | Added overlay for unexpected disconnects in Touchpad mode |
| Task 2: Performance Stats | DONE | FPS, latency, resolution, bitrate, dropped frames |
| Task 3: Fix High Latency | NOT STARTED | Reduce decode queue, drop stale frames |
| Task 4: Fix Low Resolution | NOT STARTED | Add resolution selection UI |
| Task 5: USB/Wired Support | NOT STARTED | ADB port forwarding |

---

## Build Status

**Mac App**: ✅ Builds successfully
```bash
cd /Users/user/AndroidStudioProjects/Android_Mac_Pen/Mac && swift build -c release
```

**Android App**: Build with:
```bash
cd /Users/user/AndroidStudioProjects/Android_Mac_Pen/Android && ./gradlew assembleDebug
```

---

## How to Run

### Mac App
```bash
# Build and run
cd /Users/user/AndroidStudioProjects/Android_Mac_Pen/Mac
swift build -c release
.build/release/TabletPenMac
```

### Android App
- Open in Android Studio and run on device
- Or: `adb install Android/app/build/outputs/apk/debug/app-debug.apk`

### Connection
1. Mac and Android on same WiFi network
2. Note Mac's IP address
3. Enter IP in Android app and connect

---

## Key Files Reference

### Mac (Swift)
| File | Purpose |
|------|---------|
| `Mac/TabletPenMac/main.swift` | Entry point, menu bar |
| `Mac/TabletPenMac/PenServer.swift` | TCP server, client handling |
| `Mac/TabletPenMac/CursorController.swift` | Mouse cursor control |
| `Mac/TabletPenMac/ScreenCapture.swift` | Screen capture (CGDisplayStream) |
| `Mac/TabletPenMac/VideoEncoder.swift` | H.264 encoding (VideoToolbox) |
| `Mac/TabletPenMac/VideoDecoder.swift` | H.264/HEVC decoding |
| `Mac/TabletPenMac/ProtocolMessage.swift` | Binary protocol |

### Android (Kotlin)
| File | Purpose |
|------|---------|
| `Android/.../MainActivity.kt` | Navigation host |
| `Android/.../ui/HomeFragment.kt` | Mode selection screen |
| `Android/.../ui/TouchpadFragment.kt` | Cursor mode UI |
| `Android/.../ui/MirrorFragment.kt` | Mirror mode UI |
| `Android/.../PenClient.kt` | Touchpad TCP client |
| `Android/.../mirror/MirrorClient.kt` | Mirror TCP client |
| `Android/.../mirror/VideoDecoder.kt` | H.264 MediaCodec decoder |

---

## Known Issues / In Progress

1. **VideoDecoder pointer fixes**: Just completed - need to test the app to verify fix works
2. **Latency**: Still ~50-100ms, Task 3 aims to reduce this
3. **Resolution**: Hardcoded 1920x1080, Task 4 will add selection

---

## Protocol Quick Reference

| Message | Code | Direction |
|---------|------|-----------|
| PEN_DATA | 0x01 | Android → Mac |
| MODE_REQUEST | 0x02 | Android → Mac |
| MODE_ACK | 0x03 | Mac → Android |
| VIDEO_FRAME | 0x10 | Mac → Android |
| VIDEO_CONFIG | 0x11 | Mac → Android |
| PING | 0xF0 | Bidirectional |
| PONG | 0xF1 | Bidirectional |

---

## Session History

| Date | Summary |
|------|---------|
| Dec 26, 2024 | Completed Task 1 (Disconnect popup) and Task 2 (Stats overlay) |
| Dec 30, 2025 | Session 1: Fixed VideoDecoder.swift pointer lifetime issues |
| Dec 30, 2025 | Session 2: Increased video quality (bitrate 4→8 Mbps, quality 0.5→0.75) |

---

## Next Steps (When Resuming)

1. Test the VideoDecoder.swift fixes by running the Mac app
2. Begin Task 3 (Fix High Latency) if everything works
3. Consider starting Task 5 (USB support) for better latency

---

*Update this file at the start and end of each session*
