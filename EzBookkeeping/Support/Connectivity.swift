import Foundation
import Network

/// Whether the phone has a network at all; without one, saving goes straight to the phone.
/// Also tells the app when the network comes back, so changes saved meanwhile are sent.
final class Connectivity {
    static let shared = Connectivity()

    private let monitor = NWPathMonitor()
    /// Read on the main thread.
    private(set) var isOnline = true
    /// Called on the main thread when the network comes back.
    var onOnline: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                let wasOnline = self.isOnline
                self.isOnline = online

                if online && !wasOnline {
                    self.onOnline?()
                }
            }
        }

        monitor.start(queue: DispatchQueue(label: "connectivity", qos: .utility))
    }
}
