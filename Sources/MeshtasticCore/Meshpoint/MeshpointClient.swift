import Foundation

public enum MeshpointError: Error, LocalizedError, Sendable {
    case notReachable(String)
    case notAMeshpoint(String)
    case authenticationRequired
    case invalidCredentials(String)
    case forbidden(String)
    case serverError(Int, String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notReachable(let detail): detail
        case .notAMeshpoint(let detail): detail
        case .authenticationRequired: "Sign in to this Meshpoint to continue."
        case .invalidCredentials(let detail): detail
        case .forbidden(let detail): detail
        case .serverError(let code, let detail): "Meshpoint returned \(code): \(detail)"
        case .decodingFailed(let detail): "Could not read the Meshpoint response: \(detail)"
        }
    }
}

/// The role the dashboard granted this session. Viewers can read everything but
/// cannot transmit or change settings.
public enum MeshpointRole: String, Sendable {
    case admin, viewer, unknown

    public var canTransmit: Bool { self == .admin }
}

/// REST and WebSocket client for a Meshpoint gateway's dashboard API.
///
/// Authentication is the dashboard's own JWT: `POST /api/auth/login` returns it
/// in the `meshpoint_session` cookie, and every later request presents it as a
/// bearer token. The token is kept in the keychain, never on disk in the clear.
public actor MeshpointClient {
    public static let defaultPort: UInt16 = 8080
    private static let sessionCookieName = "meshpoint_session"

    public nonisolated let host: String
    public nonisolated let port: UInt16

    private let session: URLSession
    private var token: String?
    private(set) var role: MeshpointRole = .unknown

    /// Keychain account key, so two gateways do not share a token.
    private nonisolated var account: String { "\(host):\(port)" }

    public init(host: String, port: UInt16 = MeshpointClient.defaultPort) {
        self.host = host
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        // We manage the session token ourselves rather than relying on a cookie
        // jar, so the WebSocket and REST paths behave identically.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
        self.token = KeychainStore.load(account: "\(host):\(port)")
    }

    private nonisolated var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public var hasStoredToken: Bool { token != nil }

    // MARK: - Reachability

    /// Confirms something at this address really is a Meshpoint before we offer
    /// to sign in to it. An unauthenticated probe is enough: the dashboard
    /// answers 401 with a JSON body, which no plain web server would.
    public func probe() async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/device/status"))
        request.httpMethod = "GET"

        let data: Data
        let http: HTTPURLResponse
        do {
            let (body, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MeshpointError.notAMeshpoint("\(host) did not return an HTTP response.")
            }
            data = body
            http = httpResponse
        } catch let error as MeshpointError {
            throw error
        } catch {
            throw MeshpointError.notReachable("Could not reach \(host):\(port) — \(error.localizedDescription)")
        }

        // The status code alone is not enough: URLSession will happily report a
        // non-HTTP service (an SSH banner, say) as a 200 with the banner as the
        // body. Only a real JSON object from this endpoint proves what it is.
        guard http.statusCode == 200 || http.statusCode == 401 else {
            throw MeshpointError.notAMeshpoint(
                "\(host):\(port) answered with HTTP \(http.statusCode). That does not look like a Meshpoint dashboard.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeshpointError.notAMeshpoint(
                "Something is listening on \(host):\(port), but it is not a Meshpoint dashboard. Check the port — the dashboard normally runs on 8080.")
        }
        if http.statusCode == 401 {
            guard object["detail"] != nil else {
                throw MeshpointError.notAMeshpoint("\(host):\(port) is not a Meshpoint dashboard.")
            }
        } else {
            let expected = ["status", "device_id", "firmware_version", "uptime_seconds"]
            guard expected.contains(where: { object[$0] != nil }) else {
                throw MeshpointError.notAMeshpoint("\(host):\(port) is not a Meshpoint dashboard.")
            }
        }
    }

    // MARK: - Authentication

    /// Signs in and stores the session token in the keychain.
    ///
    /// The password is used for this one request and is never retained, logged,
    /// or written anywhere.
    public func logIn(username: String, password: String) async throws -> MeshpointRole {
        var request = URLRequest(url: baseURL.appending(path: "/api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MeshpointError.notReachable("No response from \(host).")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw MeshpointError.invalidCredentials("That username or password was not accepted.")
        }
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After") ?? "a moment"
            throw MeshpointError.invalidCredentials("Too many attempts. Try again in \(retry) seconds.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MeshpointError.serverError(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        guard let sessionToken = Self.extractSessionToken(from: http, url: baseURL) else {
            throw MeshpointError.decodingFailed("The sign-in succeeded but returned no session token.")
        }
        token = sessionToken
        KeychainStore.save(sessionToken, account: account)

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        role = MeshpointRole(rawValue: (body?["role"] as? String) ?? "") ?? .unknown
        return role
    }

    public func signOut() {
        token = nil
        role = .unknown
        KeychainStore.delete(account: account)
    }

    private static func extractSessionToken(from response: HTTPURLResponse, url: URL) -> String? {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String {
                result[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        return cookies.first { $0.name == sessionCookieName }?.value
    }

    // MARK: - Requests

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MeshpointError.notReachable("No response from \(host).")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            // The stored token has expired or been revoked.
            token = nil
            KeychainStore.delete(account: account)
            throw MeshpointError.authenticationRequired
        case 403:
            throw MeshpointError.forbidden(
                "This Meshpoint session is read-only. Sign in as an administrator to make changes or transmit.")
        default:
            let detail = String(decoding: data, as: UTF8.self).prefix(300)
            throw MeshpointError.serverError(http.statusCode, String(detail))
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(try makeRequest("GET", path, query: query))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MeshpointError.decodingFailed("\(path) — \(Self.describe(error))")
        }
    }

    /// Renders a decoding failure as something a person can act on: which field,
    /// and what was wrong with it.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map(\.stringValue)
            return parts.isEmpty ? "the response body" : parts.joined(separator: ".")
        }
        switch decoding {
        case .typeMismatch(let type, let context):
            return "field \(path(context)) was not the expected \(type)"
        case .valueNotFound(let type, let context):
            return "field \(path(context)) was null but a \(type) was required"
        case .keyNotFound(let key, let context):
            return "field \(path(context)).\(key.stringValue) was missing"
        case .dataCorrupted(let context):
            return "\(path(context)) could not be read (\(context.debugDescription))"
        @unknown default:
            return decoding.localizedDescription
        }
    }

    // MARK: - Endpoints

    public func deviceStatus() async throws -> MeshpointAPI.DeviceStatus {
        try await get(MeshpointAPI.DeviceStatus.self, "/api/device/status")
    }

    public func configuration() async throws -> MeshpointAPI.Configuration {
        try await get(MeshpointAPI.Configuration.self, "/api/config")
    }

    public func nodes(limit: Int = 500) async throws -> [MeshpointAPI.Node] {
        try await get([MeshpointAPI.Node].self, "/api/nodes",
                      query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    public func conversations() async throws -> [MeshpointAPI.Conversation] {
        try await get([MeshpointAPI.Conversation].self, "/api/messages/conversations")
    }

    public func messages(in conversation: String, limit: Int = 200) async throws -> [MeshpointAPI.Message] {
        // Conversation ids contain colons ("broadcast:meshtastic:0"), so the path
        // component has to be percent-encoded rather than interpolated raw.
        let encoded = conversation.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversation
        return try await get([MeshpointAPI.Message].self, "/api/messages/conversation/\(encoded)",
                             query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    public func channels() async throws -> [MeshpointAPI.ChannelEntry] {
        try await get([MeshpointAPI.ChannelEntry].self, "/api/messages/channels")
    }

    public func metricsHistory(for node: String, hours: Double = 168, limit: Int = 300) async throws -> MeshpointAPI.MetricsHistory {
        let encoded = node.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? node
        return try await get(MeshpointAPI.MetricsHistory.self, "/api/nodes/\(encoded)/metrics_history",
                             query: [URLQueryItem(name: "hours", value: String(hours)),
                                     URLQueryItem(name: "limit", value: String(limit))])
    }

    @discardableResult
    public func send(text: String, destination: String, channel: Int, wantAck: Bool) async throws -> MeshpointAPI.SendResult {
        let request = try makeRequest("POST", "/api/messages/send", body: [
            "text": text,
            "destination": destination,
            "protocol": "meshtastic",
            "channel": channel,
            "want_ack": wantAck,
        ])
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(MeshpointAPI.SendResult.self, from: data)
        } catch {
            throw MeshpointError.decodingFailed("send: \(error)")
        }
    }

    public func markRead(conversation: String) async throws {
        let encoded = conversation.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversation
        _ = try await perform(try makeRequest("POST", "/api/messages/conversation/\(encoded)/read"))
    }

    public func deleteConversation(_ conversation: String) async throws {
        let encoded = conversation.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversation
        _ = try await perform(try makeRequest("DELETE", "/api/messages/conversation/\(encoded)"))
    }

    public func updateIdentity(longName: String?, shortName: String?) async throws {
        var body: [String: Any] = [:]
        if let longName { body["long_name"] = longName }
        if let shortName { body["short_name"] = shortName }
        guard !body.isEmpty else { return }
        _ = try await perform(try makeRequest("PUT", "/api/config/identity", body: body))
    }

    public func updateRadio(region: String?, preset: String?) async throws {
        var body: [String: Any] = [:]
        if let region { body["region"] = region }
        if let preset { body["preset"] = preset }
        guard !body.isEmpty else { return }
        _ = try await perform(try makeRequest("PUT", "/api/config/radio", body: body))
    }

    public func updateTransmit(enabled: Bool?, txPowerDBm: Int?, hopLimit: Int?,
                               relayEnabled: Bool?, routerMode: Bool?) async throws {
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let txPowerDBm { body["tx_power_dbm"] = txPowerDBm }
        if let hopLimit { body["hop_limit"] = hopLimit }
        var relay: [String: Any] = [:]
        if let relayEnabled { relay["enabled"] = relayEnabled }
        if let routerMode { relay["router_mode"] = routerMode }
        if !relay.isEmpty { body["relay"] = relay }
        guard !body.isEmpty else { return }
        _ = try await perform(try makeRequest("PUT", "/api/config/transmit", body: body))
    }

    // MARK: - Live stream

    /// Opens the dashboard's WebSocket feed. The token travels in a cookie
    /// header rather than the `?token=` query the API also accepts, so it never
    /// ends up in a URL that could be logged.
    public nonisolated func socketRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://\(host):\(port)/ws")!)
        request.setValue("\(Self.sessionCookieName)=\(token)", forHTTPHeaderField: "Cookie")
        return request
    }

    public func currentToken() -> String? { token }
}
