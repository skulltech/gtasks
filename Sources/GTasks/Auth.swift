import AppKit
import CryptoKit
import Foundation
import Network

struct OAuthConfig: Equatable {
    let clientID: String
    let clientSecret: String
}

enum AuthError: LocalizedError {
    case cancelled
    case notSignedIn
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in cancelled."
        case .notSignedIn: return "Not signed in."
        case .server(let msg): return msg
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int?
    let refresh_token: String?
}

private struct OAuthErrorResponse: Decodable {
    let error: String
    let error_description: String?
}

// MARK: - Loopback redirect server

/// One-shot HTTP server on 127.0.0.1:<random port> that captures Google's OAuth redirect.
final class LoopbackServer {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[URLQueryItem], Error>?
    private var pending: Result<[URLQueryItem], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: AuthError.cancelled)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .main)
        }
    }

    func waitForCallback() async throws -> [URLQueryItem] {
        if let pending { return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        finish(.failure(AuthError.cancelled))
        listener.cancel()
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        if let c = continuation {
            continuation = nil
            c.resume(with: result)
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let isCallback = items.contains { $0.name == "code" || $0.name == "error" }
            let failed = items.contains { $0.name == "error" }

            let message = !isCallback ? "Not found"
                : failed ? "Sign-in failed. You can close this tab and try again from the menu bar."
                : "Signed in to GTasks. You can close this tab."
            let body = """
            <!doctype html><html><head><meta charset="utf-8"><title>GTasks</title></head>
            <body style="font-family:-apple-system,sans-serif;display:flex;height:90vh;align-items:center;justify-content:center">
            <p style="font-size:18px">\(message)</p></body></html>
            """
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })

            if isCallback, let self {
                self.finish(.success(items))
                self.listener.cancel()
            }
        }
    }
}

// MARK: - Auth manager

@MainActor
final class AuthManager: ObservableObject {
    let config: OAuthConfig?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isAuthorizing = false
    @Published var errorMessage: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var server: LoopbackServer?
    private var refreshTask: Task<String, Error>?

    private static let scope = "https://www.googleapis.com/auth/tasks"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    init() {
        config = Self.loadBundledConfig()
        isSignedIn = config != nil && Keychain.get("refresh_token") != nil
    }

    // MARK: Client config

    /// Reads the Google Cloud "Desktop app" client JSON. `scripts/build-app.sh` copies
    /// `Resources/client_secret.json` into the app bundle; `swift run` reads it from the repo.
    private static func loadBundledConfig() -> OAuthConfig? {
        struct File: Decodable {
            struct Client: Decodable { let client_id: String; let client_secret: String }
            let installed: Client?
            let web: Client?
        }
        let repoCopy = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/client_secret.json")
        let candidates = [Bundle.main.url(forResource: "client_secret", withExtension: "json"), repoCopy]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data),
                  let c = file.installed ?? file.web else { continue }
            return OAuthConfig(clientID: c.client_id, clientSecret: c.client_secret)
        }
        return nil
    }

    // MARK: Sign in / out

    func signIn() async {
        guard let config, !isAuthorizing else { return }
        isAuthorizing = true
        errorMessage = nil
        defer { isAuthorizing = false; server = nil }

        do {
            let server = try LoopbackServer()
            self.server = server
            let port = try await server.start()
            let redirectURI = "http://127.0.0.1:\(port)"
            let verifier = Self.randomURLSafe(byteCount: 32)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let state = Self.randomURLSafe(byteCount: 16)

            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                .init(name: "client_id", value: config.clientID),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scope),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(comps.url!)

            let items = try await server.waitForCallback()
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            if let error = value("error") { throw AuthError.server("Google returned: \(error)") }
            guard value("state") == state, let code = value("code") else {
                throw AuthError.server("Invalid OAuth callback.")
            }

            let token = try await tokenRequest([
                "code": code,
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ])
            guard let refresh = token.refresh_token else {
                throw AuthError.server("Google didn't return a refresh token. Try signing in again.")
            }
            Keychain.set("refresh_token", refresh)
            store(token)
            isSignedIn = true
        } catch AuthError.cancelled {
            // user cancelled; nothing to show
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelSignIn() {
        server?.cancel()
    }

    func signOut() {
        if let token = Keychain.get("refresh_token") {
            // Best-effort revoke; ignore the result.
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formEncode(["token": token])
            URLSession.shared.dataTask(with: req).resume()
        }
        clearSession()
    }

    private func clearSession() {
        Keychain.set("refresh_token", nil)
        accessToken = nil
        expiry = .distantPast
        isSignedIn = false
    }

    // MARK: Tokens

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, Date() < expiry { return accessToken }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refreshAccessToken() async throws -> String {
        guard let config, let refresh = Keychain.get("refresh_token") else { throw AuthError.notSignedIn }
        do {
            let token = try await tokenRequest([
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            store(token)
            return token.access_token
        } catch AuthError.server(let msg) where msg.contains("invalid_grant") {
            clearSession()
            errorMessage = "Your Google session expired. Please sign in again."
            throw AuthError.notSignedIn
        }
    }

    private func store(_ token: TokenResponse) {
        accessToken = token.access_token
        expiry = Date().addingTimeInterval(Double(token.expires_in ?? 3600) - 60)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let e = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                throw AuthError.server([e.error, e.error_description].compactMap { $0 }.joined(separator: ": "))
            }
            throw AuthError.server("Token request failed (HTTP \(status)).")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Helpers

    private static func formEncode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
