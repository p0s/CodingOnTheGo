import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Network)
import Network
#endif

public struct BonjourServiceResolution: Hashable, Sendable {
    public var name: String
    public var type: String
    public var domain: String
    public var hostName: String
    public var ipAddress: String?
    public var port: Int

    public init(
        name: String,
        type: String,
        domain: String,
        hostName: String,
        ipAddress: String? = nil,
        port: Int
    ) {
        self.name = name
        self.type = type
        self.domain = domain
        self.hostName = hostName
        self.ipAddress = ipAddress
        self.port = port
    }
}

public struct BonjourScanConfiguration: Hashable, Sendable {
    public var serviceTypes: [String]
    public var domain: String
    public var browseTimeout: Duration
    public var resolveTimeout: TimeInterval
    public var probeTimeout: Duration

    public init(
        serviceTypes: [String] = ["_ssh._tcp.", "_sftp-ssh._tcp."],
        domain: String = "local.",
        browseTimeout: Duration = .seconds(2),
        resolveTimeout: TimeInterval = 1.25,
        probeTimeout: Duration = .milliseconds(900)
    ) {
        self.serviceTypes = serviceTypes
        self.domain = domain
        self.browseTimeout = browseTimeout
        self.resolveTimeout = resolveTimeout
        self.probeTimeout = probeTimeout
    }
}

public protocol BonjourServiceBrowsing: Sendable {
    func scan(configuration: BonjourScanConfiguration) async -> [BonjourServiceResolution]
}

public protocol TCPRouteProbing: Sendable {
    func probe(host: String, port: Int, timeout: Duration) async -> Bool
}

public struct NetServiceBonjourBrowser: BonjourServiceBrowsing {
    public init() {}

    public func scan(configuration: BonjourScanConfiguration) async -> [BonjourServiceResolution] {
        let session = await MainActor.run {
            BonjourBrowseSession(configuration: configuration)
        }
        return await session.run()
    }
}

public struct NetworkTCPRouteProbe: TCPRouteProbing {
    public init() {}

    public func probe(host: String, port: Int, timeout: Duration) async -> Bool {
        #if canImport(Network)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let completion = TCPProbeCompletion(
                continuation: continuation,
                connection: connection
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue.global(qos: .utility))

            Task {
                try? await Task.sleep(for: timeout)
                completion.finish(false)
            }
        }
        #else
        _ = host
        _ = port
        _ = timeout
        return false
        #endif
    }
}

@MainActor
private final class BonjourBrowseSession: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let configuration: BonjourScanConfiguration
    private var browsers: [NetServiceBrowser] = []
    private var resolvingServices: [String: NetService] = [:]
    private var resolvedServices: [BonjourServiceResolution] = []
    private var started = false
    private var finished = false
    private var activeResolveKeys: Set<String> = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var continuation: CheckedContinuation<[BonjourServiceResolution], Never>?

    init(configuration: BonjourScanConfiguration) {
        self.configuration = configuration
    }

    func run() async -> [BonjourServiceResolution] {
        guard !started else {
            return []
        }
        started = true

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            startBrowsers()
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = serviceKey(for: service)
        guard !activeResolveKeys.contains(key) else {
            return
        }

        activeResolveKeys.insert(key)
        resolvingServices[key] = service
        service.delegate = self
        service.resolve(withTimeout: configuration.resolveTimeout)
        _ = browser
        _ = moreComing
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let key = serviceKey(for: sender)
        defer {
            activeResolveKeys.remove(key)
            resolvingServices.removeValue(forKey: key)
        }

        guard let hostName = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !hostName.isEmpty,
              sender.port > 0 else {
            return
        }

        let resolved = BonjourServiceResolution(
            name: sender.name,
            type: sender.type,
            domain: sender.domain,
            hostName: hostName,
            ipAddress: preferredIPAddress(from: sender.addresses),
            port: sender.port
        )

        if !resolvedServices.contains(resolved) {
            resolvedServices.append(resolved)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = errorDict
        let key = serviceKey(for: sender)
        activeResolveKeys.remove(key)
        resolvingServices.removeValue(forKey: key)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        _ = browser
        _ = errorDict
        finish()
    }

    private func startBrowsers() {
        browsers = configuration.serviceTypes.map { type in
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: configuration.domain)
            return browser
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.finish()
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configuration.browseTimeout.timeInterval,
            execute: workItem
        )
    }

    private func finish() {
        guard !finished else {
            return
        }
        finished = true

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolvingServices.removeAll()

        let deduped = Array(Set(resolvedServices)).sorted {
            if $0.hostName != $1.hostName {
                return $0.hostName < $1.hostName
            }
            if $0.port != $1.port {
                return $0.port < $1.port
            }
            return $0.type < $1.type
        }
        continuation?.resume(returning: deduped)
        continuation = nil
    }

    private func serviceKey(for service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func preferredIPAddress(from addresses: [Data]?) -> String? {
        guard let addresses else {
            return nil
        }

        let resolved = addresses.compactMap(ipAddress(from:))
        return resolved.first(where: { $0.contains(".") }) ?? resolved.first
    }

    private func ipAddress(from address: Data) -> String? {
        address.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                return nil
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                baseAddress,
                socklen_t(address.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                return nil
            }

            let length = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
            let bytes = hostBuffer[..<length].map(UInt8.init(bitPattern:))
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

private final class TCPProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Bool, Never>
    private let connection: NWConnection

    init(
        continuation: CheckedContinuation<Bool, Never>,
        connection: NWConnection
    ) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ result: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else {
            return
        }
        completed = true
        connection.cancel()
        continuation.resume(returning: result)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
