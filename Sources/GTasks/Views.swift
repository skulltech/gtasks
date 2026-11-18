import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Root

struct RootView: View {
    @ObservedObject var auth: AuthManager
    @ObservedObject var store: TaskStore

    var body: some View {
        Group {
            if auth.config == nil {
                MissingConfigView()
            } else if !auth.isSignedIn {
                SignInView(auth: auth)
            } else {
                TasksView(store: store, auth: auth)
            }
        }
        .frame(width: 380, height: 520)
        // The default MenuBarExtra background is translucent glass, which washes out
        // text when a bright window sits behind it. Use a solid, appearance-aware fill.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        let n = store.dueCount
        if n > 0 {
            Text("\(Image(systemName: "checklist")) \(n)")
        } else {
            Image(systemName: "checklist")
        }
    }
}

// MARK: - Missing OAuth client (build problem, not a user flow)

struct MissingConfigView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
            Text("No Google OAuth client bundled").font(.headline)
            Text("Put the Desktop-app client JSON at Resources/client_secret.json and rebuild with scripts/build-app.sh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            QuitButton()
        }
        .padding(20)
    }
}

// MARK: - Sign in

struct SignInView: View {
    @ObservedObject var auth: AuthManager

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist").font(.system(size: 44)).foregroundStyle(.tint)
            Text("GTasks").font(.title2.bold())
            if auth.isAuthorizing {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                Button("Cancel") { auth.cancelSignIn() }
            } else {
                Button {
                    Task { await auth.signIn() }
                } label: {
                    Text("Sign in with Google").frame(minWidth: 160)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            if let err = auth.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer()
            HStack {
                Spacer()
                QuitButton()
            }
        }
        .padding(20)
    }
}

struct QuitButton: View {
    var body: some View {
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .font(.caption)
    }
}

// MARK: - Tasks

struct TasksView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var auth: AuthManager
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            AddTaskField { title, due in await store.add(title: title, due: due) }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Divider()

            if let err = store.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }

            if store.tasks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("All done").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.tasks) { task in
                            TaskRow(task: task, store: store)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if store.undoable != nil {
                Divider()
                HStack {
                    Text("Task completed").font(.callout)
                    Spacer()
                    Button("Undo") { Task { await store.undoComplete() } }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { Task { await store.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if store.lists.count > 1 {
                Picker("", selection: Binding(
                    get: { store.selectedListID ?? "" },
                    set: { id in Task { await store.selectList(id) } }
                )) {
                    ForEach(store.lists) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            } else {
                Text(store.lists.first?.title ?? "Tasks").font(.headline)
            }

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            } else {
                Button { Task { await store.refresh(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh (⌘R)")
                .keyboardShortcut("r")
            }

            Menu {
                Button("Open Google Tasks in Browser") {
                    NSWorkspace.shared.open(URL(string: "https://tasks.google.com")!)
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                Divider()
                Button("Sign Out") { auth.signOut() }
                Divider()
                Button("Quit GTasks") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Add field

struct AddTaskField: View {
    var onAdd: (String, Date?) async -> Void
    @Local private var text = ""
    @Local private var due: Date?
    @Local private var showDue = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            TextField("Add a task", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)

            Button { showDue.toggle() } label: {
                if let due {
                    DueChip(date: due)
                } else {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Due date")
            .popover(isPresented: $showDue, arrowEdge: .bottom) {
                DuePicker(current: due) { picked in
                    due = picked
                    showDue = false
                    focused = true
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .onAppear { focused = true }
    }

    private func submit() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        text = ""
        let d = due
        Task { await onAdd(title, d) }
    }
}

// MARK: - Row

struct TaskRow: View {
    let task: GTask
    @ObservedObject var store: TaskStore
    @Local private var hovering = false
    @Local private var editing = false
    @Local private var draft = ""
    @Local private var showDue = false
    @FocusState private var editorFocused: Bool

    private var done: Bool { store.completing.contains(task.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.complete(task) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark complete")

            VStack(alignment: .leading, spacing: 5) {
                if editing {
                    TextField("Title", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($editorFocused)
                        .onSubmit(commitEdit)
                        .onExitCommand { editing = false }
                        .onChange(of: editorFocused) { _, focused in
                            if !focused && editing { commitEdit() }
                        }
                } else {
                    Text(linkified(task.title ?? ""))
                        .strikethrough(done)
                        .foregroundStyle(done ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: startEdit)
                }
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let date = task.dueDate {
                    Button { showDue = true } label: { DueChip(date: date) }
                        .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Button { showDue = true } label: { Image(systemName: "calendar") }
                    .help("Due date")
                Button { Task { await store.delete(task) } } label: { Image(systemName: "trash") }
                    .help("Delete")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering && !editing ? 1 : 0)
            .popover(isPresented: $showDue, arrowEdge: .trailing) {
                DuePicker(current: task.dueDate) { picked in
                    showDue = false
                    Task { await store.setDue(task, picked) }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .padding(.leading, task.parent != nil ? 26 : 0)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit Title", action: startEdit)
            Divider()
            Button("Due Today") { Task { await store.setDue(task, DueFormat.today) } }
            Button("Due Tomorrow") { Task { await store.setDue(task, DueFormat.inDays(1)) } }
            if task.due != nil {
                Button("Remove Due Date") { Task { await store.setDue(task, nil) } }
            }
            if let link = task.webViewLink, let url = URL(string: link) {
                Divider()
                Button("Open in Google Tasks") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await store.delete(task) } }
        }
    }

    private func startEdit() {
        draft = task.title ?? ""
        editing = true
        editorFocused = true
    }

    private func commitEdit() {
        editing = false
        let newTitle = draft
        Task { await store.rename(task, to: newTitle) }
    }
}

/// Makes URLs inside a task title clickable.
private func linkified(_ string: String) -> AttributedString {
    var attributed = AttributedString(string)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return attributed
    }
    for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
        guard let url = match.url,
              let range = Range(match.range, in: string),
              let attrRange = Range(range, in: attributed) else { continue }
        attributed[attrRange].link = url
    }
    return attributed
}

// MARK: - Due UI

struct DueChip: View {
    let date: Date

    var body: some View {
        let (text, style) = DueFormat.describe(date)
        let color: Color = switch style {
        case .overdue: .red
        case .today: .accentColor
        case .future: .secondary
        }
        Label(text, systemImage: "clock")
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.45)))
    }
}

struct DuePicker: View {
    let current: Date?
    let onPick: (Date?) -> Void
    @Local private var date: Date

    init(current: Date?, onPick: @escaping (Date?) -> Void) {
        self.current = current
        self.onPick = onPick
        _date = Local(wrappedValue: current ?? DueFormat.today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Today") { onPick(DueFormat.today) }
                Button("Tomorrow") { onPick(DueFormat.inDays(1)) }
                Button("Next week") { onPick(DueFormat.inDays(7)) }
            }
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if current != nil {
                    Button("Clear", role: .destructive) { onPick(nil) }
                }
                Spacer()
                Button("Set") { onPick(date) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}
