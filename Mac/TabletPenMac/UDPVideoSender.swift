import Foundation
import Network

/// UDP video sender for low-latency video streaming.
/// Fragments video frames into MTU-sized packets and sends via UDP.
///
/// Packet format (18-byte header + payload):
/// [0]      Packet type (0x20 = video fragment)
/// [1-4]    Frame number (4 bytes BE)
/// [5-6]    Fragment index (2 bytes BE)
/// [7-8]    Total fragments (2 bytes BE)
/// [9]      Flags (bit0 = keyframe)
/// [10-17]  Timestamp (8 bytes BE)
/// [18...]  NAL data fragment
class UDPVideoSender {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "UDPVideoSender", qos: .userInteractive)

    // MTU-safe payload size (1500 - IP header - UDP header - our header)
    // 1500 - 20 (IP) - 8 (UDP) - 18 (our header) = 1454
    // Use 1400 for safety margin with various network configs
    private let maxPayloadSize = 1400

    // Packet type identifier
    private let packetTypeVideo: UInt8 = 0x20

    // Stats
    private(set) var packetsSent: UInt64 = 0
    private(set) var bytesSent: UInt64 = 0

    var onError: ((String) -> Void)?

    /// Connect to the Android client's UDP video port.
    func connect(host: String, port: UInt16) {
        disconnect()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        // Configure for low latency
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo

        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("UDP video sender connected to \(host):\(port)")
            case .failed(let error):
                self?.onError?("UDP video connection failed: \(error)")
            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    /// Disconnect and release resources.
    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    /// Send a video frame, fragmenting if necessary.
    /// - Parameters:
    ///   - nalData: The encoded NAL data
    ///   - frameNumber: Frame sequence number
    ///   - isKeyframe: Whether this is a keyframe
    ///   - timestamp: Capture timestamp in nanoseconds
    func sendFrame(nalData: Data, frameNumber: UInt32, isKeyframe: Bool, timestamp: UInt64) {
        guard let conn = connection else { return }

        // Calculate number of fragments needed
        let totalFragments = (nalData.count + maxPayloadSize - 1) / maxPayloadSize

        // Send each fragment
        for fragmentIndex in 0..<totalFragments {
            let start = fragmentIndex * maxPayloadSize
            let end = min(start + maxPayloadSize, nalData.count)
            let fragmentData = nalData.subdata(in: start..<end)

            // Build packet
            var packet = Data(capacity: 18 + fragmentData.count)

            // [0] Packet type
            packet.append(packetTypeVideo)

            // [1-4] Frame number (BE)
            var fn = frameNumber.bigEndian
            packet.append(Data(bytes: &fn, count: 4))

            // [5-6] Fragment index (BE)
            var fi = UInt16(fragmentIndex).bigEndian
            packet.append(Data(bytes: &fi, count: 2))

            // [7-8] Total fragments (BE)
            var tf = UInt16(totalFragments).bigEndian
            packet.append(Data(bytes: &tf, count: 2))

            // [9] Flags
            var flags: UInt8 = 0
            if isKeyframe { flags |= 0x01 }
            packet.append(flags)

            // [10-17] Timestamp (BE)
            var ts = timestamp.bigEndian
            packet.append(Data(bytes: &ts, count: 8))

            // [18...] NAL data fragment
            packet.append(fragmentData)

            // Send packet (capture packet size before closure)
            let packetSize = packet.count
            conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    // Suppress ECANCELED errors (expected during disconnect)
                    let nsError = error as NSError
                    if nsError.domain == NSPOSIXErrorDomain && nsError.code == 89 {
                        // ECANCELED - connection was canceled, ignore
                        return
                    }
                    self?.onError?("UDP send error: \(error)")
                } else {
                    self?.packetsSent += 1
                    self?.bytesSent += UInt64(packetSize)
                }
            })
        }
    }

    /// Get stats string for debugging.
    func getStats() -> String {
        return "UDP Video: \(packetsSent) packets, \(bytesSent / 1024) KB sent"
    }
}
