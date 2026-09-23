import AppKit
import Foundation

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var server: PenServer!
    private var udpPenReceiver: UDPPenReceiver!  // Low-latency UDP for pen data
    private var udpVideoSender: UDPVideoSender!  // Low-latency UDP for video frames
    private var cursorController: CursorController!
    private let keyboardController = KeyboardController()
    private var drawingWindow: DrawingWindow?

    // Screen mirroring components
    private var screenCapture: ModernScreenCapture?
    private var videoEncoder: VideoEncoder?
    private var isMirroring = false
    private var frameNumber: UInt32 = 0
    private var clientHost: String?  // Connected client's IP for UDP video
    private var useTcpVideo = false  // True when UDP video is unreachable, fallback to TCP

    // Loopback test components (encode → decode on Mac to compare with Android)
    private var videoDecoder: VideoDecoder?
    private var previewWindow: PreviewWindow?
    private var loopbackEnabled = false

    private var isDrawingMode = false
    private var wasDown = false
    private var timingEnabled = false

    // Frame pacing - drop stale frames at the capture input, keep the pipeline
    // shallow so latency stays bounded. maxFramesInFlight > 1 lets one frame drain
    // while the next encodes, absorbing send-tunnel jitter (fewer motion stutters).
    private var isEncodingFrame = false
    private var pendingFrame: (CVPixelBuffer, UInt64)?
    private let frameLock = NSLock()
    private var framesSending = 0            // encoded frames handed to the socket, not yet drained
    private let maxFramesInFlight = 2        // pipeline depth (1 = strict, higher = smoother/more latency)

    /// Encode the most recently captured frame if the pipeline has spare depth.
    /// Only the latest captured frame is kept (stale frames are dropped before
    /// encoding), so the encoder's reference chain is never broken.
    private func encodeNextFrameIfReady() {
        frameLock.lock()
        guard !isEncodingFrame,
              framesSending < maxFramesInFlight,
              let (buffer, ts) = pendingFrame else {
            frameLock.unlock()
            return
        }
        pendingFrame = nil
        isEncodingFrame = true
        frameLock.unlock()

        PipelineTimer.shared.onCapture(frameNumber: frameNumber, displayTime: ts)
        videoEncoder?.encode(pixelBuffer: buffer, timestamp: ts)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable "game mode" - high performance settings
        enablePerformanceMode()

        // Request accessibility permissions for cursor control
        requestAccessibilityPermissions()

        // Setup components
        cursorController = CursorController()
        server = PenServer(port: 9876)
        udpPenReceiver = UDPPenReceiver(port: 9877)
        udpVideoSender = UDPVideoSender()

        // Setup server callbacks
        setupServerCallbacks()

        // Setup UDP receiver callback (low-latency pen data path)
        udpPenReceiver.onPenData = { [weak self] data in
            self?.handlePenData(data)
        }

        // Create status bar menu
        setupStatusBar()

        // Start servers
        server.start()
        udpPenReceiver.start()

        print("===========================================")
        print("  Tablet Pen Server")
        print("===========================================")
        print("TCP server on port 9876 (video/control)")
        print("UDP server on port 9877 (low-latency pen)")
        print("")
        print("Your Mac's IP addresses:")
        printIPAddresses()
        print("")
        print("Enter this IP in the Android app to connect.")
        print("===========================================")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMirroring()
        server.stop()
        udpPenReceiver.stop()
    }

    /// Enable high-performance mode similar to game streaming apps.
    /// - Disables App Nap to prevent throttling
    /// - Sets high process priority
    /// - Disables sudden termination
    private func enablePerformanceMode() {
        // Disable App Nap - prevents macOS from throttling the app when in background
        ProcessInfo.processInfo.disableAutomaticTermination("Screen mirroring active")
        ProcessInfo.processInfo.disableSuddenTermination()

        // Begin activity to prevent App Nap and system sleep during mirroring
        // .userInitiated is high priority, .latencyCritical prevents power management throttling
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Real-time screen mirroring"
        )

        // Set high process priority (nice value -10, needs root for lower)
        // This helps but isn't as aggressive as realtime threads
        setpriority(PRIO_PROCESS, 0, -10)

        print("🎮 Performance mode enabled (App Nap disabled, high priority)")
    }

    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !trusted {
            print("")
            print("⚠️  IMPORTANT: Accessibility Permission Required!")
            print("   Please grant accessibility access in:")
            print("   System Preferences → Security & Privacy → Privacy → Accessibility")
            print("   Then restart this app.")
            print("")
        }
    }

    private func setupServerCallbacks() {
        server.onClientConnected = { [weak self] address in
            print("✅ Client connected: \(address)")
            // Extract IP address from various formats:
            // - "192.168.1.100"
            // - "::ffff:192.168.1.100" (IPv4-mapped IPv6)
            // - "%en0.192.168.1.100" (interface-scoped)
            var ip = address

            // Remove interface prefix (e.g., "%en0.")
            if let dotIndex = ip.firstIndex(of: "."), let percentIndex = ip.firstIndex(of: "%") {
                if percentIndex < dotIndex {
                    ip = String(ip[ip.index(after: ip.firstIndex(of: ".")!)...])
                }
            }

            // Handle IPv4-mapped IPv6 (::ffff:x.x.x.x)
            if ip.hasPrefix("::ffff:") {
                ip = String(ip.dropFirst(7))
            }

            // Remove any remaining colons (IPv6 artifacts)
            if ip.contains(":") {
                // Try to extract IPv4 from the end
                let parts = ip.split(separator: ":")
                if let lastPart = parts.last, lastPart.contains(".") {
                    ip = String(lastPart)
                }
            }

            // Validate it looks like an IPv4 address
            let ipParts = ip.split(separator: ".")
            if ipParts.count == 4 {
                self?.clientHost = ip
                // A loopback client means the tablet is reaching us over adb reverse
                // (USB mode). adb reverse only tunnels TCP, and UDP to 127.x would just
                // loop back to this Mac, so force TCP video for loopback clients.
                if ip == "127.0.0.1" || ip.hasPrefix("127.") {
                    self?.useTcpVideo = true
                    print("🔌 Loopback client (\(ip)) — forcing TCP video (USB mode)")
                } else {
                    print("📡 Client IP for UDP video: \(ip)")
                }
            } else {
                print("⚠️  Could not parse client IP from: \(address)")
                self?.clientHost = nil
            }

            self?.updateStatusIcon(connected: true)
        }

        server.onClientDisconnected = { [weak self] in
            print("❌ Client disconnected")
            self?.clientHost = nil
            self?.useTcpVideo = false
            self?.udpVideoSender.disconnect()
            self?.updateStatusIcon(connected: false)
            self?.stopMirroring()
        }

        server.onError = { error in
            print("Error: \(error)")
        }

        server.onPenData = { [weak self] data in
            self?.handlePenData(data)
        }

        server.onModeRequest = { [weak self] mode in
            self?.handleModeRequest(mode)
        }

        server.onQualityRequest = { [weak self] bitrateMbps in
            self?.handleQualityRequest(bitrateMbps)
        }

        server.onROIUpdate = { [weak self] roi in
            self?.handleROIUpdate(roi)
        }

        server.onVideoFallback = { [weak self] in
            guard let self = self else { return }
            print("📡 Switching to TCP video (client reports UDP unreachable)")
            self.useTcpVideo = true
            self.udpVideoSender.disconnect()
        }

        // Keyboard / text / scroll injection (Accessibility permission required).
        server.onKeyEvent = { [weak self] key in
            self?.keyboardController.postKey(key)
        }
        server.onTextInput = { [weak self] text in
            self?.keyboardController.typeText(text)
        }
        server.onScroll = { [weak self] delta in
            self?.keyboardController.scroll(delta)
        }
    }

    private func handleROIUpdate(_ roi: RegionOfInterest) {
        screenCapture?.updateROI(roi)
    }

    // Default bitrate: 80 Mbps (industry standard for 1440p/4K streaming)
    // Parsec LAN: 100+ Mbps, Moonlight 4K: 80-100 Mbps, Steam 4K: 100+ Mbps
    private var requestedBitrate: Int = 80_000_000

    // USB (loopback/TCP) links can't sustain the same bitrate as UDP-over-WiFi:
    // the adb-reverse TCP tunnel bloats its send buffer above this, adding latency.
    // USB is USB 2.0 here (~258 Mbps real throughput measured), so there's ample
    // headroom above the video bitrate — the limiter is tunnel jitter, not bandwidth.
    // Cap generously for quality; the in-flight pipeline handles smoothness.
    private let usbBitrateCapMbps = 70

    private func handleQualityRequest(_ bitrateMbps: Int) {
        var effectiveMbps = bitrateMbps
        if useTcpVideo {
            effectiveMbps = min(bitrateMbps, usbBitrateCapMbps)
        }
        requestedBitrate = effectiveMbps * 1_000_000
        print("Quality request received: \(bitrateMbps) Mbps (using \(effectiveMbps) Mbps)")

        // If already mirroring, restart with new settings
        if isMirroring {
            stopMirroring()
            startMirroring()
        }
    }

    private func handleModeRequest(_ mode: AppMode) {
        print("Mode request: \(mode)")

        switch mode {
        case .touchpad:
            stopMirroring()
            cursorController.positioningMode = .relative
            print("Switched to Touchpad mode (relative positioning)")

        case .screenMirror:
            startMirroring()
            cursorController.positioningMode = .absolute
            print("Switched to Screen Mirror mode (absolute positioning)")
        }
    }

    private func startMirroring() {
        guard !isMirroring else { return }

        // Check screen recording permission
        guard ModernScreenCapture.hasScreenRecordingPermission() else {
            print("⚠️  Screen Recording permission required!")
            print("   Please grant access in:")
            print("   System Preferences → Security & Privacy → Privacy → Screen Recording")
            ModernScreenCapture.requestScreenRecordingPermission()
            return
        }

        // Get screen size and calculate output resolution
        let capture = ModernScreenCapture()
        let nativeSize = capture.nativeScreenSize

        // For USB connection, use higher resolution (up to 1440p)
        // Max 2560 width for 1440p support
        let maxWidth: CGFloat = 2560
        let scale = min(1.0, maxWidth / nativeSize.width)
        // HEVC/H.264 require even dimensions. Scaled display modes (e.g. the 16"
        // MBP's 1728x1117) can yield an odd height, which makes VideoToolbox fail
        // every frame with kVTPixelTransferNotSupportedErr (-12905). Round down to even.
        let outputWidth = Int(nativeSize.width * scale) & ~1
        let outputHeight = Int(nativeSize.height * scale) & ~1

        // Initialize encoder
        let encoder = VideoEncoder()
        let fps = 60  // Higher framerate for smoother experience
        // Use requested bitrate (set via quality request from Android)
        // USB: 50 Mbps, WiFi: 35 Mbps
        let bitrate = requestedBitrate

        guard encoder.initialize(width: outputWidth, height: outputHeight, fps: fps, bitrate: bitrate) else {
            print("Failed to initialize video encoder")
            return
        }

        // Encoded frame ready: account for the outstanding send, hand it to the
        // network, then try to encode the next captured frame. We never drop an
        // already-encoded frame (that breaks the delta chain), so ordering is intact.
        encoder.onEncodedFrame = { [weak self] nalData, isKeyframe, timestamp in
            guard let self = self else { return }
            self.frameLock.lock()
            self.isEncodingFrame = false
            self.framesSending += 1
            self.frameLock.unlock()

            self.sendVideoFrame(nalData: nalData, isKeyframe: isKeyframe, timestamp: timestamp)
            self.encodeNextFrameIfReady()
        }

        // A frame finished draining to the socket: free a pipeline slot and refill.
        // Allowing up to maxFramesInFlight outstanding frames absorbs adb-tunnel
        // jitter, so a slow-to-drain motion frame no longer skips the next one.
        server.onVideoFrameSent = { [weak self] in
            guard let self = self else { return }
            self.frameLock.lock()
            self.framesSending = max(0, self.framesSending - 1)
            self.frameLock.unlock()
            self.encodeNextFrameIfReady()
        }

        // Newest captured frame always replaces any waiting frame (coalesce/drop
        // stale at the input), then encode if the pipeline has room.
        capture.onFrame = { [weak self] pixelBuffer, timestamp in
            guard let self = self else { return }
            self.frameLock.lock()
            self.pendingFrame = (pixelBuffer, timestamp)
            self.frameLock.unlock()
            self.encodeNextFrameIfReady()
        }

        // Start capture
        guard capture.start(targetWidth: outputWidth, targetHeight: outputHeight, fps: fps) else {
            print("Failed to start screen capture")
            encoder.stop()
            return
        }

        // Send video config to client (via TCP)
        server.sendVideoConfig(width: outputWidth, height: outputHeight, fps: fps, bitrate: bitrate)

        // Connect UDP video sender to client
        if let host = clientHost {
            udpVideoSender.connect(host: host, port: 9878)
            print("📺 UDP video sender connected to \(host):9878")
        } else {
            print("⚠️  No client IP for UDP video, falling back to TCP")
        }

        // Setup loopback decoder if enabled
        if loopbackEnabled {
            let decoder = VideoDecoder()
            decoder.initialize(width: outputWidth, height: outputHeight, isHEVC: true)
            decoder.onDecodedFrame = { [weak self] pixelBuffer, timestamp in
                self?.previewWindow?.displayFrame(pixelBuffer, timestamp: timestamp)
            }
            videoDecoder = decoder
            print("🔄 Loopback decoder ready")
        }

        screenCapture = capture
        videoEncoder = encoder
        isMirroring = true
        frameNumber = 0

        print("Screen mirroring started: \(outputWidth)x\(outputHeight) @ \(fps)fps")
    }

    private func stopMirroring() {
        guard isMirroring else { return }

        screenCapture?.stop()
        videoEncoder?.stop()
        videoDecoder?.stop()
        udpVideoSender.disconnect()

        screenCapture = nil
        videoEncoder = nil
        videoDecoder = nil
        isMirroring = false

        // Reset frame pacing state
        frameLock.lock()
        isEncodingFrame = false
        pendingFrame = nil
        framesSending = 0
        frameLock.unlock()

        print("Screen mirroring stopped")
    }

    private func sendVideoFrame(nalData: Data, isKeyframe: Bool, timestamp: UInt64) {
        // Timing: send
        PipelineTimer.shared.onSend(frameNumber: frameNumber)

        // Send via UDP for lower latency, or TCP if UDP is unreachable
        if clientHost != nil && !useTcpVideo {
            // UDP: fragmented video packets
            udpVideoSender.sendFrame(
                nalData: nalData,
                frameNumber: frameNumber,
                isKeyframe: isKeyframe,
                timestamp: timestamp
            )
        } else {
            // TCP: reliable delivery (USB mode, or WiFi with UDP fallback)
            let frameType: FrameType = isKeyframe ? .keyframe : .deltaFrame
            server.sendVideoFrame(frameType: frameType, timestamp: timestamp, frameNumber: frameNumber, nalData: nalData)
        }

        // Loopback test: decode on Mac and display in preview window
        if loopbackEnabled {
            videoDecoder?.decode(nalData: nalData, timestamp: timestamp)
        }

        frameNumber += 1
    }

    private func handlePenData(_ data: PenData) {
        // In mirror mode, we still control the cursor
        // The mirrored screen shows the cursor movement

        if isDrawingMode && !isMirroring {
            // Drawing mode - send to canvas (only if not mirroring)
            if let window = drawingWindow {
                let isNewStroke = data.isDown && !wasDown
                if data.isDown {
                    window.addPoint(
                        CGPoint(x: CGFloat(data.x), y: CGFloat(1.0 - data.y)),
                        pressure: data.pressure,
                        isNewStroke: isNewStroke
                    )
                }
            }
        } else {
            // Cursor mode - control system cursor
            cursorController.processPenData(data)
        }

        wasDown = data.isDown
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "Tablet Pen")
        }

        let menu = NSMenu()

        // Status
        let statusMenuItem = NSMenuItem(title: "Status: Waiting for connection...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Mode toggle
        let cursorModeItem = NSMenuItem(title: "Cursor Mode", action: #selector(setCursorMode), keyEquivalent: "1")
        cursorModeItem.state = .on
        cursorModeItem.tag = 200
        menu.addItem(cursorModeItem)

        let drawingModeItem = NSMenuItem(title: "Drawing Mode", action: #selector(setDrawingMode), keyEquivalent: "2")
        drawingModeItem.tag = 201
        menu.addItem(drawingModeItem)

        menu.addItem(NSMenuItem.separator())

        // Sensitivity submenu
        let sensitivityMenu = NSMenu()
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = sensitivityMenu

        let sensitivityLevels: [(String, Float, String)] = [
            ("Very Low (0.5x)", 0.5, ""),
            ("Low (0.75x)", 0.75, ""),
            ("Medium (1.0x)", 1.0, ""),
            ("Default (1.5x)", 1.5, ""),
            ("High (2.0x)", 2.0, ""),
            ("Very High (3.0x)", 3.0, ""),
            ("Ultra (5.0x)", 5.0, "")
        ]

        for (index, (title, value, key)) in sensitivityLevels.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setSensitivity(_:)), keyEquivalent: key)
            item.tag = 300 + index
            item.representedObject = value
            if value == cursorController.sensitivity {
                item.state = .on
            }
            sensitivityMenu.addItem(item)
        }

        menu.addItem(sensitivityItem)

        menu.addItem(NSMenuItem.separator())

        // Drawing window
        menu.addItem(NSMenuItem(title: "Open Drawing Canvas", action: #selector(openDrawingWindow), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Clear Canvas", action: #selector(clearCanvas), keyEquivalent: "c"))

        menu.addItem(NSMenuItem.separator())

        // Screen recording permission check
        menu.addItem(NSMenuItem(title: "Check Screen Recording Permission", action: #selector(checkScreenPermission), keyEquivalent: ""))

        // Pipeline timing toggle
        let timingItem = NSMenuItem(title: "Enable Pipeline Timing", action: #selector(toggleTiming), keyEquivalent: "t")
        timingItem.tag = 400
        menu.addItem(timingItem)

        // Loopback test toggle
        let loopbackItem = NSMenuItem(title: "Enable Loopback Preview", action: #selector(toggleLoopback), keyEquivalent: "l")
        loopbackItem.tag = 401
        menu.addItem(loopbackItem)

        menu.addItem(NSMenuItem.separator())

        // Show IP
        menu.addItem(NSMenuItem(title: "Show IP Address", action: #selector(showIPAddress), keyEquivalent: "i"))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func checkScreenPermission() {
        if ScreenCapture.hasScreenRecordingPermission() {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission"
            alert.informativeText = "Screen recording is enabled. Screen mirroring will work when requested by the Android app."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Screen mirroring requires screen recording permission.\n\nClick OK to open System Preferences."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                ScreenCapture.requestScreenRecordingPermission()
            }
        }
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Float else { return }
        cursorController.sensitivity = value

        // Update checkmarks
        if let menu = statusItem.menu {
            for item in menu.items {
                if let submenu = item.submenu {
                    for subItem in submenu.items {
                        subItem.state = (subItem.representedObject as? Float) == value ? .on : .off
                    }
                }
            }
        }

        print("Sensitivity set to \(value)x")
    }

    private func updateStatusIcon(connected: Bool) {
        if let button = statusItem.button {
            let symbolName = connected ? "pencil.circle.fill" : "pencil.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Tablet Pen")
        }

        if let menu = statusItem.menu, let statusItem = menu.item(withTag: 100) {
            statusItem.title = connected ? "Status: Connected ✓" : "Status: Waiting for connection..."
        }
    }

    @objc private func setCursorMode() {
        isDrawingMode = false
        cursorController.reset()
        updateModeMenuItems()
        print("Switched to Cursor Mode")
    }

    @objc private func setDrawingMode() {
        isDrawingMode = true
        cursorController.reset()
        updateModeMenuItems()
        openDrawingWindow()
        print("Switched to Drawing Mode")
    }

    private func updateModeMenuItems() {
        if let menu = statusItem.menu {
            menu.item(withTag: 200)?.state = isDrawingMode ? .off : .on
            menu.item(withTag: 201)?.state = isDrawingMode ? .on : .off
        }
    }

    @objc private func openDrawingWindow() {
        if drawingWindow == nil {
            drawingWindow = DrawingWindow()
        }
        drawingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func clearCanvas() {
        drawingWindow?.clear()
    }

    @objc private func toggleTiming() {
        timingEnabled = !timingEnabled

        if timingEnabled {
            PipelineTimer.shared.start(logToFile: true)
        } else {
            PipelineTimer.shared.stop()
        }

        // Update menu item
        if let menu = statusItem.menu, let item = menu.item(withTag: 400) {
            item.title = timingEnabled ? "Disable Pipeline Timing" : "Enable Pipeline Timing"
            item.state = timingEnabled ? .on : .off
        }
    }

    @objc private func toggleLoopback() {
        loopbackEnabled = !loopbackEnabled

        if loopbackEnabled {
            // Create preview window if needed
            if previewWindow == nil {
                previewWindow = PreviewWindow()
            }
            previewWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            print("🔄 Loopback preview enabled - compare with Android playback")
        } else {
            previewWindow?.close()
            videoDecoder?.stop()
            videoDecoder = nil
            print("🔄 Loopback preview disabled")
        }

        // Update menu item
        if let menu = statusItem.menu, let item = menu.item(withTag: 401) {
            item.title = loopbackEnabled ? "Disable Loopback Preview" : "Enable Loopback Preview"
            item.state = loopbackEnabled ? .on : .off
        }
    }

    @objc private func showIPAddress() {
        let ips = getIPAddresses()
        let message = ips.isEmpty ? "No network connection found" : ips.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Your IP Address"
        alert.informativeText = "Enter one of these in the Android app:\n\n\(message)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func printIPAddresses() {
        for ip in getIPAddresses() {
            print("  → \(ip)")
        }
    }

    private func getIPAddresses() -> [String] {
        var addresses: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }

            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) { // IPv4
                let name = String(cString: interface.ifa_name)

                // Skip loopback
                if name == "lo0" { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                let address = String(cString: hostname)
                if !address.isEmpty && address != "127.0.0.1" {
                    addresses.append("\(address) (\(name))")
                }
            }
        }

        return addresses
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar app
app.run()
