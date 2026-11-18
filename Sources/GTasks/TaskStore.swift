import AppKit
import Combine
import SwiftUI

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var lists: [TaskList] = []
    @Published private(set) var selectedListID: String?
    @Published private(set) var tasks: [GTask] = []
    @Published private(set) var isLoading = false
    @Published private(set) var completing: Set<String> = []
    @Published private(set) var undoable: GTask?
    @Published var errorMessage: String?

    let auth: AuthManager
    private let api: TasksAPI
    private var lastRefresh = Date.distantPast
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    init(auth: AuthManager) {
        self.auth = auth
        self.api = TasksAPI(auth: auth)
        self.selectedListID = UserDefaults.standard.string(forKey: "selectedListID")

        auth.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard let self else { return }
                if signedIn {
                    Task { await self.refresh(force: true) }
                } else {
                    self.lists = []
                    self.tasks = []
                }
            }
            .store(in: &bag)
    }

    /// Tasks due today or earlier — shown as a badge in the menu bar.
    var dueCount: Int {
        tasks.filter { t in
            !completing.contains(t.id) && (t.dueDate.map { DueFormat.daysFromToday($0) <= 0 } ?? false)
        }.count
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { await self?.refresh(force: true) } }
            .store(in: &bag)
    }

    // MARK: Loading

    func refresh(force: Bool = false) async {
        guard auth.isSignedIn, !isLoading else { return }
        if !force && Date().timeIntervalSince(lastRefresh) < 15 { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.lists()
            lists = fetched
            if selectedListID == nil || !fetched.contains(where: { $0.id == selectedListID }) {
                setSelected(fetched.first?.id)
            }
            try await loadTasks()
            lastRefresh = Date()
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func selectList(_ id: String) async {
        guard id != selectedListID else { return }
        setSelected(id)
        tasks = []
        undoable = nil
        isLoading = true
        defer { isLoading = false }
        do { try await loadTasks() } catch { report(error) }
    }

    private func setSelected(_ id: String?) {
        selectedListID = id
        UserDefaults.standard.set(id, forKey: "selectedListID")
    }

    private func loadTasks() async throws {
        guard let listID = selectedListID else { tasks = []; return }
        let fetched = try await api.tasks(listID: listID)
        guard listID == selectedListID else { return } // user switched lists meanwhile
        tasks = Self.ordered(fetched.filter { !completing.contains($0.id) })
    }

    /// Sorted by due date (overdue first, undated last), ties broken by Google's "My order".
    /// Subtasks stay directly under their parent.
    static func ordered(_ items: [GTask]) -> [GTask] {
        let ids = Set(items.map(\.id))
        let isChild: (GTask) -> Bool = { $0.parent.map(ids.contains) ?? false }
        let byPosition: (GTask, GTask) -> Bool = { ($0.position ?? "") < ($1.position ?? "") }
        let byDue: (GTask, GTask) -> Bool = { a, b in
            let da = a.dueDate ?? .distantFuture, db = b.dueDate ?? .distantFuture
            return da != db ? da < db : byPosition(a, b)
        }
        let top = items.filter { !isChild($0) }.sorted(by: byDue)
        let children = Dictionary(grouping: items.filter(isChild), by: { $0.parent! })
        return top.flatMap { [$0] + (children[$0.id] ?? []).sorted(by: byPosition) }
    }

    /// Tasks grouped into Overdue / Today / Tomorrow / Later / No date.
    /// Subtasks are placed in their parent's section.
    var sections: [TaskSection] {
        var result: [TaskSection] = []
        var parentBucket: [String: DueBucket] = [:]
        for task in tasks {
            let bucket = task.parent.flatMap { parentBucket[$0] } ?? DueBucket(task.dueDate)
            parentBucket[task.id] = bucket
            if result.last?.bucket == bucket {
                result[result.count - 1].tasks.append(task)
            } else {
                result.append(TaskSection(bucket: bucket, tasks: [task]))
            }
        }
        return result
    }

    // MARK: Mutations

    func add(title: String, due: Date?) async {
        guard let listID = selectedListID else { return }
        do {
            let created = try await api.insert(listID: listID, title: title, due: due)
            guard listID == selectedListID else { return }
            withAnimation { tasks = Self.ordered(tasks + [created]) }
        } catch { report(error) }
    }

    func complete(_ task: GTask) {
        guard let listID = selectedListID, !completing.contains(task.id) else { return }
        completing.insert(task.id)
        Task {
            defer { completing.remove(task.id) }
            do {
                _ = try await api.patch(listID: listID, taskID: task.id, ["status": "completed"])
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation { tasks.removeAll { $0.id == task.id } }
                undoable = task
                try? await Task.sleep(for: .seconds(5))
                if undoable?.id == task.id { withAnimation { undoable = nil } }
            } catch { report(error) }
        }
    }

    func undoComplete() async {
        guard let task = undoable, let listID = selectedListID else { return }
        withAnimation { undoable = nil }
        do {
            let restored = try await api.patch(listID: listID, taskID: task.id, ["status": "needsAction"])
            withAnimation { tasks = Self.ordered(tasks.filter { $0.id != restored.id } + [restored]) }
        } catch { report(error) }
    }

    func rename(_ task: GTask, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let listID = selectedListID, !title.isEmpty, title != task.title else { return }
        replaceLocally(task.id) { $0.title = title }
        do {
            let updated = try await api.patch(listID: listID, taskID: task.id, ["title": title])
            replaceLocally(task.id) { $0 = updated }
        } catch { report(error) }
    }

    func setDue(_ task: GTask, _ date: Date?) async {
        guard let listID = selectedListID else { return }
        replaceLocally(task.id) { $0.due = date.map(DueFormat.rfc3339) }
        do {
            let updated = try await api.patch(
                listID: listID, taskID: task.id,
                ["due": date.map { DueFormat.rfc3339($0) as Any } ?? NSNull()]
            )
            replaceLocally(task.id) { $0 = updated }
        } catch { report(error) }
        withAnimation { tasks = Self.ordered(tasks) }
    }

    func delete(_ task: GTask) async {
        guard let listID = selectedListID else { return }
        let snapshot = tasks
        withAnimation { tasks.removeAll { $0.id == task.id || $0.parent == task.id } }
        do {
            try await api.delete(listID: listID, taskID: task.id)
        } catch {
            tasks = snapshot
            report(error)
        }
    }

    private func replaceLocally(_ id: String, _ change: (inout GTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
    }

    private func report(_ error: Error) {
        if case AuthError.notSignedIn = error { return }
        if (error as? URLError)?.code == .cancelled { return }
        errorMessage = error.localizedDescription
    }
}
