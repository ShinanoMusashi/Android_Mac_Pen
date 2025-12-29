import Foundation
import Network

/// Get current time in nanoseconds using monotonic clock.
/// Uses continuous clock to avoid jumps from system time changes.
func getCurrentTimeNanos() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

/// TCP server that receives pen data from the Android tablet.
/// Supports both legacy text protocol and new binary protocol.
class PenServer {
    private var listener: NWListener?
    private var connection: NWConnection?
    private let port: UInt16
    private let queue = DispatchQueue(label: "PenServer")

    // Buffer for accumulating incoming data (for binary protocol parsing)
    private var receiveBuffer = Data()

    // Current mode
    private(set) var currentMode: AppMode = .touchpad

    // Protocol detection: true = binary, false = legacy text
    private var useBinaryProtocol = false

    // Callbacks
    var onPenData: ((PenData) -> Void)?
    var onClientConnected: ((String) -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onError: ((String) -> Void)?
    var onModeRequest: ((AppMode) -> Void)?
    var onQualityRequest: ((Int) -> Void)?  // Bitrate in Mbps
    var onROIUpdate: ((RegionOfInterest) -> Void)?  // Region of interest for zoomed streaming

    init(port: UInt16 = 9876) {
        self.port = port
    }

    /// Start listening for connections.
    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("Server listening on port \(self?.port ?? 0)")
                case .failed(let error):
                    self?.onError?("Server failed: \(error)")
                case .cancelled:
                    print("Server cancelled")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleNewConnection(newConnection)
            }

            listener?.start(queue: queue)
        } catch {
            onError?("Failed to start server: \(error)")
        }
    }

    /// Stop the server.
    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        // Close existing connection if any
        connection?.cancel()
        connection = newConnection

        // Reset state for new connection
        receiveBuffer = Data()
        useBinaryProtocol = false
        currentMode = .touchpad

        let endpoint = newConnection.endpoint
        if case .hostPort(let host, _) = endpoint {
            DispatchQueue.main.async {
                self.onClientConnected?("\(host)")
            }
        }

        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveData()
            case .failed(let error):
                DispatchQueue.main.async {
                    self?.onError?("Connection failed: \(error)")
                    self?.onClientDisconnected?()
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self?.onClientDisconnected?()
                }
            default:
                break
            }
        }

        newConnection.start(queue: queue)
    }

    private func receiveData() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.onError?("Receive error: \(error)")
                }
                return
            }

            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceivedData()
            }

            if isComplete {
                DispatchQueue.main.async {
                    self.onClientDisconnected?()
                }
            } else {
                // Continue receiving
                self.receiveData()
            }
        }
    }

    private func processReceivedData() {
        // Detect protocol type on first data
        if !useBinaryProtocol && receiveBuffer.count > 0 {
            // Check if first byte looks like a valid binary message type
            let firstByte = receiveBuffer[0]
            if let _ = MessageType(rawValue: firstByte) {
                useBinaryProtocol = true
                print("Using binary protocol")
            } else {
                // Assume legacy text protocol
                print("Using legacy text protocol")
            }
        }

        if useBinaryProtocol {
            processBinaryProtocol()
        } else {
            processLegacyTextProtocol()
        }
    }

    private func processBinaryProtocol() {
        // Keep parsing messages while we have enough data
        while receiveBuffer.count >= 5 {
            guard let (message, consumed) = ProtocolMessage.parse(from: receiveBuffer) else {
                // Not enough data yet or invalid message
                break
            }

            // Remove consumed bytes from buffer
            receiveBuffer.removeFirst(consumed)

            // Handle the message
            handleMessage(message)
        }
    }

    private func handleMessage(_ message: ProtocolMessage) {
        switch message.type {
        case .penData:
            if let penData = ProtocolCodec.decodePenData(from: message.payload) {
                // Process pen data immediately on network queue for lowest latency
                // CGWarpMouseCursorPosition is thread-safe
                self.onPenData?(penData)
            }

        case .modeRequest:
            if let mode = ProtocolCodec.decodeMode(from: message.payload) {
                currentMode = mode
                DispatchQueue.main.async {
                    self.onModeRequest?(mode)
                }
                // Send acknowledgment
                sendModeAck(mode)
            }

        case .qualityRequest:
            if let bitrateMbps = ProtocolCodec.decodeQualityRequest(from: message.payload) {
                print("Quality request: \(bitrateMbps) Mbps")
                DispatchQueue.main.async {
                    self.onQualityRequest?(bitrateMbps)
                }
            }

        case .ping:
            // Respond with pong
            sendPong()

        case .syncRequest:
            // Clock synchronization - respond with timing info
            let t2 = getCurrentTimeNanos()  // Receive time
            if let t1 = ProtocolCodec.decodeSyncRequest(from: message.payload) {
                let t3 = getCurrentTimeNanos()  // Send time
                sendSyncResponse(t1: t1, t2: t2, t3: t3)
            }

        case .roiUpdate:
            if let roi = ProtocolCodec.decodeROI(from: message.payload) {
                print("ROI update: x=\(roi.x), y=\(roi.y), w=\(roi.width), h=\(roi.height)")
                DispatchQueue.main.async {
                    self.onROIUpdate?(roi)
                }
            }

        case .logData:
            // Save received log data to file
            saveLogData(message.payload)

        default:
            // Ignore other message types from client
            break
        }
    }

    /// Save log data received from Android to a file.
    private func saveLogData(_ data: Data) {
        // Extract filename (first line) and content (rest)
        guard let string = String(data: data, encoding: .utf8) else {
            print("Failed to decode log data")
            return
        }

        let lines = string.components(separatedBy: "\n")
        guard lines.count >= 2 else {
            print("Invalid log data format")
            return
        }

        let filename = lines[0]
        let content = lines.dropFirst().joined(separator: "\n")

        // Save to Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filePath = documentsPath.appendingPathComponent("android_\(filename)")

        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            print("📱 Android log saved: \(filePath.path)")
        } catch {
            print("Failed to save log: \(error)")
        }
    }

    private func processLegacyTextProtocol() {
        // Handle legacy text protocol (CSV pen data)
        guard let string = String(data: receiveBuffer, encoding: .utf8) else { return }

        // Find complete lines
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)

        // Process all complete lines (all but the last if it doesn't end with newline)
        let hasTrailingNewline = string.hasSuffix("\n")
        let completeLineCount = hasTrailingNewline ? lines.count : lines.count - 1

        for i in 0..<completeLineCount {
            let line = String(lines[i])
            if !line.isEmpty, let penData = PenData.parse(from: line) {
                DispatchQueue.main.async {
                    self.onPenData?(penData)
                }
            }
        }

        // Keep incomplete line in buffer
        if hasTrailingNewline {
            receiveBuffer = Data()
        } else if completeLineCount > 0 {
            let remaining = String(lines[completeLineCount])
            receiveBuffer = remaining.data(using: .utf8) ?? Data()
        }
    }

    // MARK: - Send Methods

    /// Send mode acknowledgment.
    func sendModeAck(_ mode: AppMode) {
        let data = ProtocolCodec.encodeModeAck(mode)
        send(data)
    }

    /// Send pong response.
    func sendPong() {
        let data = ProtocolCodec.encodePong()
        send(data)
    }

    /// Send sync response for clock synchronization.
    /// t1: Android's original timestamp (echoed back)
    /// t2: Mac's receive timestamp
    /// t3: Mac's send timestamp
    func sendSyncResponse(t1: UInt64, t2: UInt64, t3: UInt64) {
        let data = ProtocolCodec.encodeSyncResponse(t1: t1, t2: t2, t3: t3)
        send(data)
    }

    /// Send video configuration.
    func sendVideoConfig(width: Int, height: Int, fps: Int, bitrate: Int) {
        let data = ProtocolCodec.encodeVideoConfig(width: width, height: height, fps: fps, bitrate: bitrate)
        send(data)
    }

    /// Send video frame.
    func sendVideoFrame(frameType: FrameType, timestamp: UInt64, frameNumber: UInt32, nalData: Data) {
        let data = ProtocolCodec.encodeVideoFrame(frameType: frameType, timestamp: timestamp, frameNumber: frameNumber, nalData: nalData)
        send(data)
    }

    /// Send raw data to client.
    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.onError?("Send error: \(error)")
                }
            }
        })
    }
}
