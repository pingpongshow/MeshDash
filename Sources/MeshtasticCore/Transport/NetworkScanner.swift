import Foundation
import Network
import Observation

/// Finds radios on the local network.
///
/// Firmware with WiFi or Ethernet enabled advertises `_meshtastic._tcp` over
/// mDNS, so a node joined to the same access point shows up here without the
/// user having to hunt for its IP address.
@MainActor
@Observable
public final class NetworkScanner {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var isScanning = false
    public private(set) var errorMessage: String?

    private var browser: NWBrowser?
    /// Resolvers keyed by service name, kept alive while they work out an address.
    private var resolvers: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        guard browser == nil else { return }
        errorMessage = nil

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_meshtastic._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isScanning = true
                    self.errorMessage = nil
                case .failed(let error):
                    self.isScanning = false
                    self.errorMessage = "Could not search the local network: \(error.localizedDescription)"
                case .cancelled:
                    self.isScanning = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services: [(name: String, endpoint: NWEndpoint)] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return (name, result.endpoint)
            }
            Task { @MainActor in
                self?.apply(services)
            }
        }

        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isScanning = false
        for connection in resolvers.values { connection.cancel() }
        resolvers.removeAll()
    }

    /// Adds a host the user typed in by hand.
    public func addManualHost(_ host: String, port: UInt16 = TCPTransport.defaultPort) -> DiscoveredDevice {
        let device = DiscoveredDevice(address: .tcp(host: host, port: port),
                                      name: host,
                                      detail: "Manually added · port \(port)")
        if !devices.contains(where: { $0.address == device.address }) {
            devices.append(device)
        }
        return device
    }

    private func apply(_ services: [(name: String, endpoint: NWEndpoint)]) {
        let liveNames = Set(services.map(\.name))
        devices.removeAll { device in
            guard case .tcp = device.address else { return false }
            // Keep manual entries; only prune vanished Bonjour services.
            return device.detail.hasPrefix("Bonjour") && !liveNames.contains(device.name)
        }
        for service in services where !resolvers.keys.contains(service.name) {
            resolve(name: service.name, endpoint: service.endpoint)
        }
    }

    /// Bonjour hands back a service endpoint; opening a connection to it is the
    /// supported way to learn the actual host and port behind that name.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let resolved = connection.currentPath?.remoteEndpoint
                connection.cancel()
                Task { @MainActor in
                    self?.record(name: name, resolved: resolved)
                }
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.resolvers[name] = nil
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func record(name: String, resolved: NWEndpoint?) {
        resolvers[name] = nil
        guard case .hostPort(let host, let port) = resolved else { return }
        let hostText: String
        switch host {
        case .ipv4(let address):
            hostText = "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            // Skip link-local v6; the v4 record for the same service is friendlier.
            let text = "\(address)"
            if text.hasPrefix("fe80") { return }
            hostText = text.components(separatedBy: "%").first ?? text
        case .name(let hostname, _):
            hostText = hostname
        @unknown default:
            return
        }

        let address = DeviceAddress.tcp(host: hostText, port: port.rawValue)
        let device = DiscoveredDevice(address: address,
                                      name: name,
                                      detail: "Bonjour · \(hostText):\(port.rawValue)")
        if let index = devices.firstIndex(where: { $0.address == address }) {
            devices[index] = device
        } else {
            devices.append(device)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
