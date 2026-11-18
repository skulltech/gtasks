import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin client for the Google Tasks REST API v1.
@MainActor
final class TasksAPI {
    private let auth: AuthManager
    private let base = "https://tasks.googleapis.com/tasks/v1"

    init(auth: AuthManager) { self.auth = auth }

    func lists() async throws -> [TaskList] {
        var all: [TaskList] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let page: PagedResponse<TaskList> = try decode(await send("GET", "/users/@me/lists", query: query))
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    func tasks(listID: String) async throws -> [GTask] {
        var all: [GTask] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "maxResults", value: "100"),
                URLQueryItem(name: "showCompleted", value: "false"),
                URLQueryItem(name: "showHidden", value: "false"),
            ]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let page: PagedResponse<GTask> = try decode(await send("GET", "/lists/\(listID)/tasks", query: query))
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    func insert(listID: String, title: String, due: Date?) async throws -> GTask {
        var body: [String: Any] = ["title": title]
        if let due { body["due"] = DueFormat.rfc3339(due) }
        return try decode(await send("POST", "/lists/\(listID)/tasks", body: body))
    }

    /// Use `NSNull()` as a value to clear a field (e.g. `["due": NSNull()]`).
    func patch(listID: String, taskID: String, _ fields: [String: Any]) async throws -> GTask {
        try decode(await send("PATCH", "/lists/\(listID)/tasks/\(taskID)", body: fields))
    }

    func delete(listID: String, taskID: String) async throws {
        _ = try await send("DELETE", "/lists/\(listID)/tasks/\(taskID)")
    }

    // MARK: Plumbing

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        guard var comps = URLComponents(string: base + path) else { throw APIError(message: "Bad URL") }
        if !query.isEmpty { comps.queryItems = query }

        for attempt in 0..<2 {
            let token = try await auth.validAccessToken(forceRefresh: attempt > 0)
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            guard (200..<300).contains(status) else {
                struct Wrapper: Decodable { struct E: Decodable { let message: String? }; let error: E? }
                let msg = (try? JSONDecoder().decode(Wrapper.self, from: data))?.error?.message
                throw APIError(message: msg ?? "Google Tasks request failed (HTTP \(status)).")
            }
            return data
        }
        throw APIError(message: "Unauthorized.")
    }
}
