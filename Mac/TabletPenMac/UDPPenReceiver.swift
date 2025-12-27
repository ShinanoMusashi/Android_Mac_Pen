import Foundation
import Network

/// UDP receiver for low-latency pen data.
/// Runs alongside TCP for video, providing faster pen input path.
class UDPPenReceiver {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "UDPPenReceiver", qos: .userInteractive)

    /// Callback for pen data - called directly on network queue for lowest latency
    var onPenData: ((PenData) -> Void)?

    /// Callback for errors
    var onError: ((String) -> Void)?

    init(port: UInt16 = 9877) {
        self.port = port
    }

    /// Start listening for UDP pen data.
    func start() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("UDP pen receiver listening on port \(self?.port ?? 0)")
                case .failed(let error):
                    self?.onError?("UDP listener failed: \(error)")
                case .cancelled:
                    print("UDP pen receiver cancelled")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: queue)
        } catch {
            onError?("Failed to start UDP receiver: \(error)")
        }
    }

    /// Stop the receiver.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveData(from: connection)
            case .failed, .cancelled:
                // UDP "connections" are transient, no need to track
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveData(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                // Don't report transient UDP errors
                if case .posix(let code) = error, code == .ECONNRESET {
                    return
                }
                return
            }

            if let data = data, !data.isEmpty {
                self.processPacket(data)
            }

            // Continue receiving
            self.receiveData(from: connection)
        }
    }

    private func processPacket(_ data: Data) {
        // UDP pen data format: same as TCP binary protocol
        // [Type: 1 byte][Length: 4 bytes BE][Payload: variable]
        guard data.count >= 5 else { return }

        let type = data[0]
        guard type == MessageType.penData.rawValue else { return }

        // Parse length (big-endian)
        let length = Int(data[1]) << 24 | Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
        guard data.count >= 5 + length else { return }

        let payload = data.subdata(in: 5..<(5 + length))

        // Decode and process immediately (no thread switch!)
        if let penData = ProtocolCodec.decodePenData(from: payload) {
            onPenData?(penData)
        }
    }
}
