# Android Mac Pen - Technical Documentation

## Table of Contents
1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Communication Protocol](#communication-protocol)
4. [Android Application](#android-application)
5. [Mac Application](#mac-application)
6. [Video Streaming Pipeline](#video-streaming-pipeline)
7. [Pen Input Processing](#pen-input-processing)
8. [Data Flow Diagrams](#data-flow-diagrams)

---

## Overview

Android Mac Pen is a system that turns an Android tablet with stylus support into an input device for macOS. It operates in two modes:

1. **Touchpad Mode**: The tablet acts as a trackpad - pen movements control the Mac cursor, pressure triggers clicks
2. **Screen Mirror Mode**: The Mac screen is streamed to the tablet, allowing direct pen interaction with the mirrored display

### Key Technologies
- **Android**: Kotlin, Coroutines, MediaCodec, Navigation Component, ViewBinding
- **macOS**: Swift, CGDisplayStream, VideoToolbox, CoreGraphics
- **Networking**: TCP sockets with custom binary protocol
- **Video**: H.264 encoding/decoding with hardware acceleration

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ANDROID TABLET                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────────────┐  │
│  │ HomeFragment│───▶│TouchpadFrag │    │         MirrorFragment          │  │
│  │             │    │             │    │  ┌─────────┐  ┌──────────────┐  │  │
│  │ Mode Select │───▶│ PenInputView│    │  │SurfaceVw│  │ Touch/Hover  │  │  │
│  └─────────────┘    │             │    │  │ (Video) │  │   Handler    │  │  │
│                     │ Touch Events│    │  └────┬────┘  └──────┬───────┘  │  │
│                     └──────┬──────┘    │       │              │          │  │
│                            │           │  ┌────▼────┐         │          │  │
│                            │           │  │VideoDec │         │          │  │
│                            │           │  │(H.264)  │         │          │  │
│                            │           │  └─────────┘         │          │  │
│                            │           └──────────────────────┼──────────┘  │
│                     ┌──────▼──────┐              ┌────────────▼───────┐     │
│                     │  PenClient  │              │    MirrorClient    │     │
│                     │ (TCP Send)  │              │ (TCP Send/Receive) │     │
│                     └──────┬──────┘              └─────────┬──────────┘     │
│                            │                               │                │
│                     ┌──────▼───────────────────────────────▼──────┐         │
│                     │           ProtocolCodec                     │         │
│                     │    Binary Message Encoding/Decoding         │         │
│                     └──────────────────┬──────────────────────────┘         │
└────────────────────────────────────────┼────────────────────────────────────┘
                                         │ TCP/IP
                                         │ Port 9876
┌────────────────────────────────────────┼────────────────────────────────────┐
│                                        │           MACOS                    │
├────────────────────────────────────────┼────────────────────────────────────┤
│                     ┌──────────────────▼──────────────────┐                 │
│                     │           ProtocolCodec             │                 │
│                     │    Binary Message Encoding/Decoding │                 │
│                     └──────────────────┬──────────────────┘                 │
│                                        │                                    │
│                     ┌──────────────────▼──────────────────┐                 │
│                     │            PenServer                │                 │
│                     │     TCP Server (Accept/Read/Write)  │                 │
│                     └───────┬─────────────────┬───────────┘                 │
│                             │                 │                             │
│              ┌──────────────▼───┐    ┌────────▼────────┐                    │
│              │ CursorController │    │  Mode Handler   │                    │
│              │                  │    │                 │                    │
│              │ - Move cursor    │    │ TOUCHPAD:       │                    │
│              │ - Click/drag     │    │   Just cursor   │                    │
│              │ - Smoothing      │    │                 │                    │
│              │ - Pressure thresh│    │ MIRROR:         │                    │
│              └──────────────────┘    │   Start capture │                    │
│                                      └────────┬────────┘                    │
│                                               │                             │
│                              ┌────────────────▼────────────────┐            │
│                              │        ScreenCapture            │            │
│                              │   CGDisplayStream (60 FPS)      │            │
│                              │   CVPixelBuffer output          │            │
│                              └────────────────┬────────────────┘            │
│                                               │                             │
│                              ┌────────────────▼────────────────┐            │
│                              │        VideoEncoder             │            │
│                              │   VTCompressionSession (H.264)  │            │
│                              │   Hardware accelerated          │            │
│                              │   Annex B NAL output            │            │
│                              └────────────────┬────────────────┘            │
│                                               │                             │
│                              ┌────────────────▼────────────────┐            │
│                              │     Send to PenServer           │            │
│                              │   VIDEO_FRAME messages          │            │
│                              └─────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Communication Protocol

### Message Format

All messages use a simple Type-Length-Value (TLV) format:

```
┌─────────┬─────────────────┬─────────────────────────┐
│  Type   │     Length      │        Payload          │
│ 1 byte  │  4 bytes (BE)   │    variable length      │
└─────────┴─────────────────┴─────────────────────────┘
```

- **Type**: Single byte identifying the message type
- **Length**: 4-byte big-endian unsigned integer specifying payload length
- **Payload**: Variable-length data specific to message type

### Message Types

| Type | Value | Direction | Description |
|------|-------|-----------|-------------|
| `PEN_DATA` | `0x01` | Android → Mac | Pen input data (CSV format) |
| `MODE_REQUEST` | `0x02` | Android → Mac | Request mode change |
| `MODE_ACK` | `0x03` | Mac → Android | Acknowledge mode change |
| `VIDEO_FRAME` | `0x10` | Mac → Android | H.264 encoded video frame |
| `VIDEO_CONFIG` | `0x11` | Mac → Android | Video stream configuration |
| `PING` | `0xF0` | Bidirectional | Keep-alive ping |
| `PONG` | `0xF1` | Bidirectional | Keep-alive response |

### Message Payloads

#### PEN_DATA (0x01)
CSV-encoded string with pen state:
```
x,y,pressure,isHovering,isDown,buttonPressed,tiltX,tiltY,timestamp
```

| Field | Type | Range | Description |
|-------|------|-------|-------------|
| x | float | 0.0-1.0 | Normalized X position |
| y | float | 0.0-1.0 | Normalized Y position |
| pressure | float | 0.0-1.0 | Pen pressure (0 = no contact) |
| isHovering | int | 0/1 | Pen is hovering above surface |
| isDown | int | 0/1 | Pen is touching surface |
| buttonPressed | int | 0/1 | Side button pressed |
| tiltX | float | -1.0-1.0 | Pen tilt on X axis |
| tiltY | float | -1.0-1.0 | Pen tilt on Y axis |
| timestamp | long | milliseconds | Event timestamp |

Example: `0.5,0.3,0.75,0,1,0,0.1,-0.05,1702483200000`

#### MODE_REQUEST (0x02)
Single byte indicating requested mode:
- `0x00`: Touchpad mode
- `0x01`: Screen mirror mode

#### MODE_ACK (0x03)
Single byte confirming active mode (same values as MODE_REQUEST)

#### VIDEO_CONFIG (0x11)
Video stream parameters:
```
┌────────────┬────────────┬─────────┬──────────────┐
│   Width    │   Height   │   FPS   │   Bitrate    │
│  2 bytes   │  2 bytes   │ 1 byte  │   4 bytes    │
│    (BE)    │    (BE)    │         │     (BE)     │
└────────────┴────────────┴─────────┴──────────────┘
```

#### VIDEO_FRAME (0x10)
H.264 encoded frame data:
```
┌────────────┬─────────────────┬──────────────┬─────────────────┐
│ Frame Type │    Timestamp    │ Frame Number │    NAL Data     │
│   1 byte   │    8 bytes      │   4 bytes    │    variable     │
│            │      (BE)       │     (BE)     │                 │
└────────────┴─────────────────┴──────────────┴─────────────────┘
```

Frame Type:
- `0x00`: Keyframe (I-frame) - includes SPS/PPS
- `0x01`: Delta frame (P-frame)

---

## Android Application

### Project Structure

```
Android/
├── app/
│   ├── build.gradle.kts          # Dependencies and build config
│   └── src/main/
│       ├── AndroidManifest.xml   # App manifest with INTERNET permission
│       ├── java/com/example/tabletpen/
│       │   ├── MainActivity.kt           # NavHost container
│       │   ├── PenClient.kt              # TCP client for touchpad mode
│       │   ├── PenData.kt                # Pen data model
│       │   ├── PenInputView.kt           # Custom touch input view
│       │   ├── mirror/
│       │   │   ├── MirrorClient.kt       # TCP client for mirror mode
│       │   │   └── VideoDecoder.kt       # H.264 MediaCodec decoder
│       │   ├── protocol/
│       │   │   ├── MessageType.kt        # Protocol enums
│       │   │   └── ProtocolCodec.kt      # Binary encoding/decoding
│       │   └── ui/
│       │       ├── HomeFragment.kt       # Mode selection screen
│       │       ├── TouchpadFragment.kt   # Touchpad mode UI
│       │       └── MirrorFragment.kt     # Mirror mode UI
│       └── res/
│           ├── layout/                   # XML layouts
│           ├── navigation/nav_graph.xml  # Navigation graph
│           └── values/                   # Colors, strings, themes
```

### Dependencies

```kotlin
// Navigation Component
implementation("androidx.navigation:navigation-fragment-ktx:2.7.6")
implementation("androidx.navigation:navigation-ui-ktx:2.7.6")

// Coroutines for async networking
implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

// Material Design
implementation("com.google.android.material:material:1.11.0")
```

### Key Classes

#### PenData.kt
Data class representing pen input state:

```kotlin
data class PenData(
    val x: Float,           // 0.0 to 1.0 (normalized)
    val y: Float,           // 0.0 to 1.0 (normalized)
    val pressure: Float,    // 0.0 to 1.0
    val isHovering: Boolean,
    val isDown: Boolean,
    val buttonPressed: Boolean,
    val tiltX: Float,
    val tiltY: Float,
    val timestamp: Long
) {
    fun serialize(): String = "$x,$y,$pressure,${if(isHovering) 1 else 0},..."
}
```

#### PenInputView.kt
Custom View that captures stylus input:

```kotlin
class PenInputView : View {
    var onPenData: ((PenData) -> Unit)? = null

    override fun onTouchEvent(event: MotionEvent): Boolean {
        // Normalize coordinates to 0.0-1.0
        val normalizedX = event.x / width
        val normalizedY = event.y / height

        // Extract pressure, button state, tilt
        val pressure = event.pressure.coerceIn(0f, 1f)
        val buttonPressed = (event.buttonState and BUTTON_STYLUS_PRIMARY) != 0

        // Determine state based on action
        val isHovering = event.action == ACTION_HOVER_MOVE
        val isDown = event.action == ACTION_DOWN || event.action == ACTION_MOVE

        onPenData?.invoke(PenData(...))
        return true
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        // Handle pen hovering (not touching)
        // ...
    }
}
```

#### MirrorClient.kt
TCP client with bidirectional communication:

```kotlin
class MirrorClient {
    private val sendChannel = Channel<OutgoingMessage>(Channel.CONFLATED)

    // Callbacks for received data
    var onVideoConfig: ((VideoConfig) -> Unit)? = null
    var onVideoFrame: ((VideoFrame) -> Unit)? = null

    suspend fun connect(host: String, port: Int): Boolean {
        socket = Socket()
        socket.tcpNoDelay = true  // Disable Nagle's algorithm for low latency
        socket.connect(InetSocketAddress(host, port), 5000)

        startReceiveLoop()  // Read incoming messages
        startSendLoop()     // Write outgoing messages
    }

    fun sendPenData(penData: PenData) {
        // CONFLATED channel keeps only latest - prevents backpressure
        sendChannel.trySend(OutgoingMessage.PenDataMsg(penData))
    }

    private fun startSendLoop() {
        scope.launch {
            for (message in sendChannel) {
                when (message) {
                    is PenDataMsg -> ProtocolCodec.writePenData(output, message.data)
                    is ModeRequestMsg -> ProtocolCodec.writeModeRequest(output, message.mode)
                }
            }
        }
    }

    private fun startReceiveLoop() {
        scope.launch {
            while (isActive) {
                val message = ProtocolCodec.readMessage(input)
                when (message.type) {
                    VIDEO_CONFIG -> onVideoConfig?.invoke(parseConfig(message))
                    VIDEO_FRAME -> onVideoFrame?.invoke(parseFrame(message))
                }
            }
        }
    }
}
```

#### VideoDecoder.kt
H.264 decoder using Android MediaCodec:

```kotlin
class VideoDecoder {
    private var codec: MediaCodec? = null

    fun initialize(surface: Surface, width: Int, height: Int): Boolean {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)

        codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, surface, null, 0)  // Decode directly to Surface
        codec.start()
    }

    fun decode(nalData: ByteArray, timestamp: Long, isKeyframe: Boolean) {
        // Get input buffer
        val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
        if (inputIndex >= 0) {
            val inputBuffer = codec.getInputBuffer(inputIndex)
            inputBuffer.put(nalData)

            val flags = if (isKeyframe) BUFFER_FLAG_KEY_FRAME else 0
            codec.queueInputBuffer(inputIndex, 0, nalData.size, timestamp, flags)
        }

        // Release output buffers to render to surface
        val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
        if (outputIndex >= 0) {
            codec.releaseOutputBuffer(outputIndex, true)  // true = render to surface
        }
    }
}
```

#### MirrorFragment.kt
UI and coordination for mirror mode:

```kotlin
class MirrorFragment : Fragment(), SurfaceHolder.Callback {
    private val mirrorClient = MirrorClient()
    private var videoDecoder: VideoDecoder? = null

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        setupVideoSurface()
        setupPenInput()

        mirrorClient.onVideoConfig = { config ->
            videoWidth = config.width
            videoHeight = config.height
            updateSurfaceSize()  // Maintain aspect ratio
            initializeDecoder(config)
        }

        mirrorClient.onVideoFrame = { frame ->
            videoDecoder?.decode(frame.nalData, frame.timestamp, frame.isKeyframe)
        }
    }

    private fun updateSurfaceSize() {
        // Calculate size that fits container while maintaining aspect ratio
        val videoAspect = videoWidth.toFloat() / videoHeight
        val containerAspect = containerWidth.toFloat() / containerHeight

        val (newWidth, newHeight) = if (videoAspect > containerAspect) {
            // Video is wider - fit to width, letterbox top/bottom
            containerWidth to (containerWidth / videoAspect).toInt()
        } else {
            // Video is taller - fit to height, letterbox left/right
            (containerHeight * videoAspect).toInt() to containerHeight
        }

        surfaceView.layoutParams = FrameLayout.LayoutParams(newWidth, newHeight, Gravity.CENTER)
    }

    private fun handlePenEvent(event: MotionEvent) {
        // Map touch coordinates to video surface coordinates
        val normalizedX = (event.x - offsetX) / surfaceWidth
        val normalizedY = (event.y - offsetY) / surfaceHeight

        // These normalized coords map directly to Mac screen position
        mirrorClient.sendPenData(PenData(normalizedX, normalizedY, ...))
    }
}
```

### Navigation Flow

```
┌─────────────┐     ┌──────────────────┐     ┌───────────────┐
│ HomeFragment│────▶│ TouchpadFragment │     │ MirrorFragment│
│             │     │                  │     │               │
│ - Touchpad  │     │ - PenInputView   │     │ - SurfaceView │
│ - Mirror    │────▶│ - PenClient      │     │ - MirrorClient│
│             │     │ - Connection UI  │     │ - VideoDecoder│
└─────────────┘     └──────────────────┘     └───────────────┘
```

---

## Mac Application

### Project Structure

```
Mac/
├── Package.swift              # Swift Package Manager manifest
└── TabletPenMac/
    ├── main.swift             # App entry point, menu bar, coordination
    ├── PenServer.swift        # TCP server for client connections
    ├── PenData.swift          # Pen data model (matches Android)
    ├── ProtocolMessage.swift  # Binary protocol codec
    ├── CursorController.swift # System cursor control
    ├── ScreenCapture.swift    # CGDisplayStream screen capture
    ├── VideoEncoder.swift     # H.264 VideoToolbox encoder
    └── DrawingWindow.swift    # Optional drawing canvas
```

### Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TabletPenMac",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "TabletPenMac",
            path: "TabletPenMac"
        )
    ]
)
```

### Key Classes

#### PenServer.swift
TCP server handling client connections:

```swift
class PenServer {
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let port: UInt16

    // Callbacks
    var onPenData: ((PenData) -> Void)?
    var onModeRequest: ((AppMode) -> Void)?
    var onClientConnected: ((String) -> Void)?
    var onClientDisconnected: (() -> Void)?

    func start() {
        // Create socket
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)

        // Set SO_REUSEADDR to allow quick restart
        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        bind(serverSocket, &addr, socklen_t(MemoryLayout<sockaddr_in>.size))

        // Listen
        listen(serverSocket, 1)

        // Accept connections in background
        acceptQueue.async { self.acceptLoop() }
    }

    private func acceptLoop() {
        while isRunning {
            clientSocket = accept(serverSocket, nil, nil)
            if clientSocket >= 0 {
                // Disable Nagle's algorithm
                var flag: Int32 = 1
                setsockopt(clientSocket, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))

                onClientConnected?(getClientAddress())
                receiveLoop()
            }
        }
    }

    private func receiveLoop() {
        var buffer = Data()
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)

        while clientSocket >= 0 {
            let bytesRead = read(clientSocket, readBuffer, 65536)
            if bytesRead <= 0 { break }

            buffer.append(readBuffer, count: bytesRead)

            // Parse complete messages from buffer
            while let (message, consumed) = ProtocolMessage.parse(from: buffer) {
                buffer.removeFirst(consumed)
                handleMessage(message)
            }
        }

        onClientDisconnected?()
    }

    func sendVideoFrame(frameType: FrameType, timestamp: UInt64, frameNumber: UInt32, nalData: Data) {
        guard clientSocket >= 0 else { return }

        let message = ProtocolCodec.encodeVideoFrame(
            frameType: frameType,
            timestamp: timestamp,
            frameNumber: frameNumber,
            nalData: nalData
        )

        sendQueue.async {
            _ = message.withUnsafeBytes { ptr in
                write(self.clientSocket, ptr.baseAddress, message.count)
            }
        }
    }
}
```

#### CursorController.swift
System cursor control with smoothing:

```swift
class CursorController {
    var sensitivity: Float = 1.5
    var movementDeadZone: Float = 0.002  // Ignore tiny movements
    var pressureThreshold: Float = 0.25   // Click threshold

    private var lastX: Float = 0.5
    private var lastY: Float = 0.5
    private var accumulatedDeltaX: Float = 0
    private var accumulatedDeltaY: Float = 0
    private var isDragging = false

    func processPenData(_ data: PenData) {
        // Calculate movement delta
        let deltaX = data.x - lastX
        let deltaY = data.y - lastY

        // Accumulate small movements
        accumulatedDeltaX += deltaX
        accumulatedDeltaY += deltaY

        // Only move if accumulated delta exceeds dead zone
        let accumulatedDistance = sqrt(accumulatedDeltaX * accumulatedDeltaX +
                                       accumulatedDeltaY * accumulatedDeltaY)

        if accumulatedDistance > movementDeadZone {
            moveCursor(deltaX: accumulatedDeltaX, deltaY: accumulatedDeltaY)
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
        }

        // Handle clicking based on pressure threshold
        let shouldClick = data.pressure >= pressureThreshold

        if shouldClick && !isDragging {
            // Mouse down
            postMouseEvent(.leftMouseDown, at: currentCursorPosition)
            isDragging = true
        } else if !shouldClick && isDragging {
            // Mouse up
            postMouseEvent(.leftMouseUp, at: currentCursorPosition)
            isDragging = false
        } else if isDragging {
            // Dragging
            postMouseEvent(.leftMouseDragged, at: currentCursorPosition)
        }

        lastX = data.x
        lastY = data.y
    }

    private func moveCursor(deltaX: Float, deltaY: Float) {
        let screen = NSScreen.main!.frame

        // Convert normalized delta to screen pixels
        let pixelDeltaX = CGFloat(deltaX * sensitivity) * screen.width
        let pixelDeltaY = CGFloat(deltaY * sensitivity) * screen.height

        // Get current position and apply delta
        var newPosition = currentCursorPosition
        newPosition.x += pixelDeltaX
        newPosition.y += pixelDeltaY

        // Clamp to screen bounds
        newPosition.x = max(0, min(screen.width, newPosition.x))
        newPosition.y = max(0, min(screen.height, newPosition.y))

        // Move cursor
        CGWarpMouseCursorPosition(newPosition)
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                           mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }
}
```

#### ScreenCapture.swift
Screen capture using CGDisplayStream:

```swift
class ScreenCapture {
    private var displayStream: CGDisplayStream?
    private let captureQueue = DispatchQueue(label: "ScreenCapture", qos: .userInteractive)

    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?

    var nativeScreenSize: CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 1920, height: 1080) }
        return screen.frame.size
    }

    static func hasScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    func start(targetWidth: Int, targetHeight: Int, fps: Int) -> Bool {
        let displayID = CGMainDisplayID()

        // Configure output pixel buffer format
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        // Create display stream
        displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: targetWidth,
            outputHeight: targetHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: [
                .minimumFrameInterval: 1.0 / Double(fps),
                .showCursor: true
            ] as CFDictionary,
            queue: captureQueue
        ) { [weak self] status, displayTime, ioSurface, updateRef in
            guard status == .frameComplete, let surface = ioSurface else { return }

            // Create CVPixelBuffer from IOSurface
            var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
            let result = CVPixelBufferCreateWithIOSurface(
                kCFAllocatorDefault,
                surface,
                pixelBufferAttributes as CFDictionary,
                &unmanagedPixelBuffer
            )

            guard result == kCVReturnSuccess, let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue() else {
                return
            }

            // Convert display time to nanoseconds
            let timestamp = UInt64(displayTime)

            self?.onFrame?(pixelBuffer, timestamp)
        }

        return displayStream?.start() == .success
    }

    func stop() {
        displayStream?.stop()
        displayStream = nil
    }
}
```

#### VideoEncoder.swift
H.264 encoding using VideoToolbox:

```swift
class VideoEncoder {
    private var compressionSession: VTCompressionSession?

    var width: Int = 0
    var height: Int = 0
    var fps: Int = 60
    var bitrate: Int = 15_000_000  // 15 Mbps

    var onEncodedFrame: ((Data, Bool, UInt64) -> Void)?

    func initialize(width: Int, height: Int, fps: Int, bitrate: Int) -> Bool {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate

        // Request hardware encoder
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else { return false }

        compressionSession = session
        configureSession(session)
        VTCompressionSessionPrepareToEncodeFrames(session)

        return true
    }

    private func configureSession(_ session: VTCompressionSession) {
        // Real-time encoding for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // H.264 Main profile for good quality/compression balance
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                           value: kVTProfileLevel_H264_Main_AutoLevel)

        // Bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                           value: bitrate as CFNumber)

        // Allow burst to 2x bitrate for 1 second
        let dataRateLimits = [bitrate * 2, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                           value: dataRateLimits)

        // Keyframe every 2 seconds
        let keyframeInterval = fps * 2
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                           value: keyframeInterval as CFNumber)

        // No B-frames (reduces latency - no frame reordering needed)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                           value: kCFBooleanFalse)

        // CAVLC entropy coding (faster than CABAC, lower latency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode,
                           value: kVTH264EntropyMode_CAVLC)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                           value: fps as CFNumber)
    }

    func encode(pixelBuffer: CVPixelBuffer, timestamp: UInt64) {
        guard let session = compressionSession else { return }

        let presentationTime = CMTime(value: Int64(timestamp), timescale: 1_000_000_000)
        let duration = CMTime(value: 1, timescale: Int32(fps))

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else { return }
            self?.processSampleBuffer(sampleBuffer)
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let notSync = CFDictionaryGetValue(dict, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self))
            isKeyframe = notSync == nil
        }

        // Extract timestamp
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)

        // Convert to Annex B format (start codes instead of length prefixes)
        guard let nalData = extractNALData(from: sampleBuffer, isKeyframe: isKeyframe) else { return }

        DispatchQueue.main.async {
            self.onEncodedFrame?(nalData, isKeyframe, timestamp)
        }
    }

    private func extractNALData(from sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var nalData = Data()

        // For keyframes, prepend SPS and PPS (needed for decoder initialization)
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // SPS (Sequence Parameter Set)
            var spsSize = 0, spsCount = 0
            var spsPointer: UnsafePointer<UInt8>?
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
            )
            if let sps = spsPointer {
                nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Annex B start code
                nalData.append(UnsafeBufferPointer(start: sps, count: spsSize))
            }

            // PPS (Picture Parameter Set)
            var ppsSize = 0
            var ppsPointer: UnsafePointer<UInt8>?
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if let pps = ppsPointer {
                nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                nalData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
            }
        }

        // Convert AVCC format (length-prefixed) to Annex B format (start-code-prefixed)
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                   totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else { return nil }

        var offset = 0
        while offset < totalLength {
            // Read 4-byte big-endian NAL unit length
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            if offset + Int(nalLength) > totalLength { break }

            // Replace with Annex B start code
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
            offset += Int(nalLength)
        }

        return nalData
    }
}
```

---

## Video Streaming Pipeline

### Encoding Pipeline (Mac)

```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│ CGDisplayStream│───▶│  CVPixelBuffer │───▶│ VTCompression  │───▶│   NAL Units    │
│   (60 FPS)     │    │   (BGRA)       │    │    Session     │    │  (Annex B)     │
└────────────────┘    └────────────────┘    └────────────────┘    └────────────────┘
                                                    │
                                           ┌────────▼────────┐
                                           │ H.264 Settings  │
                                           │ - Main Profile  │
                                           │ - 15 Mbps       │
                                           │ - No B-frames   │
                                           │ - CAVLC entropy │
                                           │ - Hardware accel│
                                           └─────────────────┘
```

### Transmission

```
┌─────────────────────────────────────────────────────────────────┐
│                     VIDEO_FRAME Message                         │
├────────┬──────────────┬──────────────┬─────────────────────────┤
│  0x10  │    Length    │   Metadata   │       NAL Data          │
│ 1 byte │   4 bytes    │   13 bytes   │       variable          │
│        │              │              │                         │
│        │              │  - Type 1B   │  [0x00 0x00 0x00 0x01]  │
│        │              │  - TS 8B     │  [SPS NAL unit]         │
│        │              │  - FN 4B     │  [0x00 0x00 0x00 0x01]  │
│        │              │              │  [PPS NAL unit]         │
│        │              │              │  [0x00 0x00 0x00 0x01]  │
│        │              │              │  [IDR/Slice NAL unit]   │
└────────┴──────────────┴──────────────┴─────────────────────────┘
```

### Decoding Pipeline (Android)

```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│  TCP Receive   │───▶│  Parse Frame   │───▶│   MediaCodec   │───▶│  SurfaceView   │
│                │    │  (NAL units)   │    │   (H.264 Dec)  │    │  (Display)     │
└────────────────┘    └────────────────┘    └────────────────┘    └────────────────┘
                                                    │
                                           ┌────────▼────────┐
                                           │ Zero-copy render│
                                           │ directly to     │
                                           │ Surface         │
                                           └─────────────────┘
```

### Video Quality Settings

| Setting | Value | Rationale |
|---------|-------|-----------|
| Resolution | Up to 1920px width | Balance of quality and bandwidth |
| Frame Rate | 60 FPS | Smooth pen movement |
| Bitrate | 15 Mbps | High quality for cable connection |
| Profile | H.264 Main | Better compression than Baseline |
| Entropy | CAVLC | Lower latency than CABAC |
| B-frames | Disabled | No decoding delay from frame reordering |
| Keyframe | Every 2 seconds | Balance of seek time and compression |

---

## Pen Input Processing

### Input Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            ANDROID                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    MotionEvent from System                          │   │
│   │  - event.x, event.y (pixels)                                        │   │
│   │  - event.pressure (0.0-1.0)                                         │   │
│   │  - event.buttonState (stylus buttons)                               │   │
│   │  - event.action (DOWN, MOVE, UP, HOVER_ENTER, HOVER_MOVE, etc.)     │   │
│   └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                      Coordinate Normalization                        │   │
│   │                                                                      │   │
│   │  Touchpad Mode:                Mirror Mode:                          │   │
│   │  normalizedX = event.x / viewWidth    normalizedX = (event.x - offsetX) / surfaceWidth  │
│   │  normalizedY = event.y / viewHeight   normalizedY = (event.y - offsetY) / surfaceHeight │
│   │                                                                      │   │
│   │  Both modes output: x, y in range [0.0, 1.0]                         │   │
│   └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         PenData Object                               │   │
│   │  x: 0.0-1.0, y: 0.0-1.0, pressure: 0.0-1.0                          │   │
│   │  isHovering: bool, isDown: bool, buttonPressed: bool                 │   │
│   └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Serialize to CSV String                           │   │
│   │  "0.523,0.341,0.82,0,1,0,0.0,0.0,1702483200000"                      │   │
│   └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                          │
└──────────────────────────────────┼──────────────────────────────────────────┘
                                   │ TCP
                                   │ PEN_DATA message
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              MAC                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                  │                                          │
│   ┌──────────────────────────────▼──────────────────────────────────────┐   │
│   │                      Parse CSV to PenData                            │   │
│   └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     CursorController                                 │   │
│   │                                                                      │   │
│   │  1. Calculate Delta:                                                 │   │
│   │     deltaX = currentX - lastX                                        │   │
│   │     deltaY = currentY - lastY                                        │   │
│   │                                                                      │   │
│   │  2. Movement Smoothing (Dead Zone):                                  │   │
│   │     accumulatedDeltaX += deltaX                                      │   │
│   │     accumulatedDeltaY += deltaY                                      │   │
│   │     distance = sqrt(accX² + accY²)                                   │   │
│   │     if distance > deadZone (0.002):                                  │   │
│   │         apply movement, reset accumulator                            │   │
│   │                                                                      │   │
│   │  3. Convert to Screen Pixels:                                        │   │
│   │     pixelDeltaX = deltaX * sensitivity * screenWidth                 │   │
│   │     pixelDeltaY = deltaY * sensitivity * screenHeight                │   │
│   │                                                                      │   │
│   │  4. Apply to Cursor:                                                 │   │
│   │     CGWarpMouseCursorPosition(newPosition)                           │   │
│   │                                                                      │   │
│   │  5. Pressure Threshold for Clicking:                                 │   │
│   │     if pressure >= 0.25 && !isDragging:                              │   │
│   │         post leftMouseDown event                                     │   │
│   │         isDragging = true                                            │   │
│   │     elif pressure < 0.25 && isDragging:                              │   │
│   │         post leftMouseUp event                                       │   │
│   │         isDragging = false                                           │   │
│   │     elif isDragging:                                                 │   │
│   │         post leftMouseDragged event                                  │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Coordinate Systems

#### Touchpad Mode
Pen position is relative, like a trackpad:
- Movement on tablet = cursor movement on Mac
- Sensitivity multiplier scales the movement
- Lifting pen and putting it down elsewhere doesn't teleport cursor

#### Mirror Mode
Pen position is absolute, mapping directly to screen:
- Touch at (0.5, 0.5) on tablet = cursor at center of Mac screen
- Normalized coordinates account for aspect ratio letterboxing
- 1:1 mapping between visible video area and Mac screen

### Smoothing Algorithm

```
Dead Zone: 0.002 (0.2% of screen)

                    Raw Input
                        │
            ┌───────────▼───────────┐
            │  Accumulate Deltas    │
            │  accX += deltaX       │
            │  accY += deltaY       │
            └───────────┬───────────┘
                        │
            ┌───────────▼───────────┐
            │ distance = √(accX²+accY²)│
            └───────────┬───────────┘
                        │
              ┌─────────▼─────────┐
              │ distance > 0.002? │
              └────┬─────────┬────┘
                   │         │
                  YES        NO
                   │         │
                   ▼         ▼
           ┌───────────┐  ┌─────────┐
           │Apply Move │  │  Wait   │
           │Reset Acc  │  │Accumlte │
           └───────────┘  └─────────┘
```

This eliminates jitter from hand tremor while maintaining responsiveness for intentional movements.

---

## Data Flow Diagrams

### Touchpad Mode Data Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              TOUCHPAD MODE                               │
└──────────────────────────────────────────────────────────────────────────┘

[Android Tablet]                                              [Mac]

┌─────────────────┐                                    ┌─────────────────┐
│  Pen touches    │                                    │   PenServer     │
│  PenInputView   │                                    │   listening     │
└────────┬────────┘                                    └────────┬────────┘
         │                                                      │
         │ onTouchEvent()                                       │
         ▼                                                      │
┌─────────────────┐                                             │
│ Create PenData  │                                             │
│ x=0.5, y=0.3    │                                             │
│ pressure=0.8    │                                             │
└────────┬────────┘                                             │
         │                                                      │
         │ serialize()                                          │
         ▼                                                      │
┌─────────────────┐      TCP Socket                   ┌─────────────────┐
│ PEN_DATA msg    │─────────────────────────────────▶│ Receive & Parse │
│ "0.5,0.3,0.8.." │      Port 9876                   │ PenData object  │
└─────────────────┘                                   └────────┬────────┘
                                                               │
                                                               │ processPenData()
                                                               ▼
                                                      ┌─────────────────┐
                                                      │CursorController │
                                                      │ - Move cursor   │
                                                      │ - Click if      │
                                                      │   pressure>0.25 │
                                                      └────────┬────────┘
                                                               │
                                                               │ CGWarpMouseCursorPosition
                                                               │ CGEvent.post()
                                                               ▼
                                                      ┌─────────────────┐
                                                      │  System Cursor  │
                                                      │  Moves/Clicks   │
                                                      └─────────────────┘
```

### Mirror Mode Data Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              MIRROR MODE                                 │
└──────────────────────────────────────────────────────────────────────────┘

[Mac]                                                    [Android Tablet]

┌─────────────────┐                                    ┌─────────────────┐
│ CGDisplayStream │                                    │  MirrorClient   │
│   (60 FPS)      │                                    │   connected     │
└────────┬────────┘                                    └────────┬────────┘
         │                                                      │
         │ CVPixelBuffer (BGRA)                                 │
         ▼                                                      │
┌─────────────────┐                                             │
│  VideoEncoder   │                                             │
│  VTCompression  │                                             │
│  H.264 @ 15Mbps │                                             │
└────────┬────────┘                                             │
         │                                                      │
         │ NAL Data (Annex B)                                   │
         ▼                                                      │
┌─────────────────┐      TCP Socket                   ┌─────────────────┐
│ VIDEO_FRAME msg │─────────────────────────────────▶│ Parse Frame     │
│ [type][ts][nal] │      Port 9876                   │ NAL Data        │
└─────────────────┘                                   └────────┬────────┘
                                                               │
                                                               │ decode()
                                                               ▼
                                                      ┌─────────────────┐
                                                      │  VideoDecoder   │
                                                      │  MediaCodec     │
                                                      │  H.264 → frames │
                                                      └────────┬────────┘
                                                               │
                                                               │ render to Surface
                                                               ▼
                                                      ┌─────────────────┐
                                                      │  SurfaceView    │
                                                      │  (Display)      │
                                                      └────────┬────────┘
                                                               │
         ┌─────────────────────────────────────────────────────┘
         │ User touches mirrored screen
         ▼
┌─────────────────┐
│ handlePenEvent  │
│ Map coords to   │
│ video surface   │
└────────┬────────┘
         │
         │ PenData (normalized to video bounds)
         ▼
┌─────────────────┐      TCP Socket                   ┌─────────────────┐
│ PEN_DATA msg    │─────────────────────────────────▶│ CursorController│
│ "0.5,0.3,0.8.." │      Port 9876                   │ (same as above) │
└─────────────────┘                                   └─────────────────┘
         │                                                      │
         │                                                      │
         │           Cursor moves on Mac screen                 │
         │           Which is captured by CGDisplayStream       │
         │           Creating visual feedback loop              │
         └──────────────────────────────────────────────────────┘
```

### Mode Switching Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           MODE SWITCHING                                 │
└──────────────────────────────────────────────────────────────────────────┘

[Android]                                                    [Mac]

User selects "Screen Mirror"
         │
         ▼
┌─────────────────┐
│Navigate to      │
│MirrorFragment   │
└────────┬────────┘
         │
         │ connect()
         ▼
┌─────────────────┐      TCP Connect                 ┌─────────────────┐
│ MirrorClient    │─────────────────────────────────▶│   PenServer     │
│ connects        │                                  │   accepts       │
└────────┬────────┘                                  └────────┬────────┘
         │                                                    │
         │ onConnectionChanged(true)                          │ onClientConnected
         ▼                                                    │
┌─────────────────┐                                           │
│requestMirrorMode│                                           │
└────────┬────────┘                                           │
         │                                                    │
         │ MODE_REQUEST                                       │
         │ payload: 0x01 (SCREEN_MIRROR)                      │
         ▼                                                    ▼
┌─────────────────┐                                  ┌─────────────────┐
│                 │◀─────────────────────────────────│handleModeRequest│
│                 │      MODE_ACK                    │(SCREEN_MIRROR)  │
│ onModeAck       │      payload: 0x01               └────────┬────────┘
│ (SCREEN_MIRROR) │                                           │
└────────┬────────┘                                           │ startMirroring()
         │                                                    ▼
         │                                           ┌─────────────────┐
         │                                           │ScreenCapture    │
         │                                           │   .start()      │
         │                                           │ VideoEncoder    │
         │                                           │   .initialize() │
         │                                           └────────┬────────┘
         │                                                    │
         │           VIDEO_CONFIG                             │
         │◀───────────────────────────────────────────────────┤
         │           (1920x1080, 60fps, 15Mbps)               │
         ▼                                                    │
┌─────────────────┐                                           │
│handleVideoConfig│                                           │
│ - updateSurface │                                           │
│ - initDecoder   │                                           │
└────────┬────────┘                                           │
         │                                                    │
         │           VIDEO_FRAME (continuous)                 │
         │◀───────────────────────────────────────────────────┤
         │           VIDEO_FRAME                              │
         │◀───────────────────────────────────────────────────┤
         │           VIDEO_FRAME                              │
         ▼           ...                                      │
┌─────────────────┐                                           │
│ Decode & Display│                                           │
│ Video frames    │                                           │
└─────────────────┘                                           │


User navigates back (or disconnects)
         │
         ▼
┌─────────────────┐
│requestTouchpad  │
│Mode             │
└────────┬────────┘
         │
         │ MODE_REQUEST
         │ payload: 0x00 (TOUCHPAD)
         ▼                                                    ▼
┌─────────────────┐                                  ┌─────────────────┐
│                 │◀─────────────────────────────────│handleModeRequest│
│ disconnect()    │      MODE_ACK                    │(TOUCHPAD)       │
│                 │      payload: 0x00               └────────┬────────┘
└─────────────────┘                                           │
                                                              │ stopMirroring()
                                                              ▼
                                                     ┌─────────────────┐
                                                     │ScreenCapture    │
                                                     │   .stop()       │
                                                     │ VideoEncoder    │
                                                     │   .stop()       │
                                                     └─────────────────┘
```

---

## Performance Considerations

### Latency Optimization

| Component | Optimization | Impact |
|-----------|------------|--------|
| TCP | `TCP_NODELAY` (disable Nagle) | Prevents buffering small packets |
| Encoder | Real-time mode | Prioritizes low latency over compression |
| Encoder | No B-frames | Eliminates decode reordering delay |
| Encoder | CAVLC entropy | Faster than CABAC |
| Decoder | Direct Surface render | Zero-copy from decoder to display |
| Pen Input | CONFLATED channel | Drops old data if backed up |

### Bandwidth Usage

At maximum settings (1920x1080 @ 60fps, 15 Mbps):
- **Video**: ~15 Mbps downstream (Mac → Android)
- **Pen Data**: ~50 Kbps upstream (Android → Mac)
  - ~100 pen events/second × 50 bytes/event = 5 KB/s

### Thread Model

**Android:**
- Main thread: UI updates
- IO Dispatcher: Network receive/send (Coroutines)
- MediaCodec thread: Video decoding (internal)

**Mac:**
- Main thread: UI, callbacks
- Accept queue: TCP accept loop
- Receive queue: TCP receive loop
- Send queue: TCP send (async)
- Capture queue: Screen capture callbacks
- Encoder queue: Video encoding (internal)

---

## Security Considerations

1. **No Authentication**: Anyone on the network can connect
2. **No Encryption**: Data transmitted in plaintext
3. **Local Network Only**: Designed for trusted networks

For production use, consider adding:
- TLS encryption
- Pre-shared key authentication
- Connection PIN verification

---

## Building and Running

### Mac Application

```bash
cd Mac
swift build
.build/debug/TabletPenMac
```

**Required Permissions:**
- Accessibility (for cursor control)
- Screen Recording (for mirror mode)

### Android Application

Open `Android/` folder in Android Studio and build normally.

**Required Permissions:**
- `INTERNET` (declared in manifest)

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Cursor doesn't move | Accessibility permission | Grant in System Preferences |
| Mirror mode black screen | Screen Recording permission | Grant in System Preferences |
| High latency | Network congestion | Use wired connection (USB tethering) |
| Video stuttering | CPU overload | Reduce resolution in code |
| Pen jittery | Dead zone too small | Increase `movementDeadZone` |
| Clicks too sensitive | Pressure threshold too low | Increase `pressureThreshold` |
