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
        .frame(width: 380, height: 540)
        // The default MenuBarExtra background is translucent glass, which washes out
        // text when a bright window sits behind it. Use a solid, appearance-aware fill.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        Image(nsImage: MenuBarIcon.make(count: store.dueCount))
    }
}

/// Draws the status item as one template image (icon + due count). The menu bar only shows
/// the text part of a mixed Text/Image label, so we composite them ourselves.
enum MenuBarIcon {
    static func make(count: Int) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "GTasks")?
            .withSymbolConfiguration(config) ?? NSImage()
        let text: NSString? = count > 0 ? "\(count)" as NSString : nil
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let textSize = text?.size(withAttributes: attrs) ?? .zero
        let gap: CGFloat = text == nil ? 0 : 4
        let height: CGFloat = 18
        let size = NSSize(width: ceil(symbol.size.width + gap + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            text?.draw(at: NSPoint(x: symbol.size.width + gap, y: (height - textSize.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = true // lets macOS tint it for light/dark menu bars
        image.accessibilityDescription = count > 0 ? "GTasks, \(count) due" : "GTasks"
        return image
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
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            AddTaskField { title, due in await store.add(title: title, due: due) }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

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
                VStack(spacing: 10) {
                    Spacer()
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.seal").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                        Text("All clear").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.sections) { section in
                            Section {
                                ForEach(section.tasks) { task in
                                    TaskRow(task: task, section: section.bucket, store: store)
                                }
                            } header: {
                                SectionHeader(bucket: section.bucket, count: section.tasks.count)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }

            if store.undoable != nil {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    Text("Task completed").font(.system(size: 13))
                    Spacer()
                    Button("Undo") { Task { await store.undoComplete() } }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { Task { await store.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refresh() }
        }
    }

    private var summary: String {
        let all = store.tasks
        let overdue = all.filter { DueBucket($0.dueDate) == .overdue }.count
        let today = all.filter { DueBucket($0.dueDate) == .today }.count
        var parts = ["\(all.count) open"]
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if today > 0 { parts.append("\(today) due today") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(store.lists.first { $0.id == store.selectedListID }?.title ?? "Tasks")
                        .font(.system(size: 17, weight: .semibold))
                    if store.lists.count > 1 {
                        Menu {
                            ForEach(store.lists) { list in
                                Button {
                                    Task { await store.selectList(list.id) }
                                } label: {
                                    if list.id == store.selectedListID {
                                        Label(list.title, systemImage: "checkmark")
                                    } else {
                                        Text(list.title)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Switch list")
                    }
                }
                Text(store.tasks.isEmpty ? " " : summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                IconButton(systemName: "arrow.clockwise", help: "Refresh (⌘R)") {
                    Task { await store.refresh(force: true) }
                }
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
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
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

extension DueBucket {
    var color: Color {
        switch self {
        case .overdue: .red
        case .today: .accentColor
        case .tomorrow: .orange
        case .later, .noDate: .secondary
        }
    }
}

struct SectionHeader: View {
    let bucket: DueBucket
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(bucket.title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(bucket.color)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
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
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            TextField("Add a task", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(submit)

            Button { showDue.toggle() } label: {
                if let due {
                    DueChip(date: due)
                } else {
                    Image(systemName: "calendar")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
        )
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
    let section: DueBucket
    @ObservedObject var store: TaskStore
    @Local private var hovering = false
    @Local private var editing = false
    @Local private var draft = ""
    @Local private var showDue = false
    @FocusState private var editorFocused: Bool

    private var done: Bool { store.completing.contains(task.id) }

    /// The section header already says "Today"/"Tomorrow", so only show a chip when it adds information.
    private var showChip: Bool {
        guard let date = task.dueDate else { return false }
        let bucket = DueBucket(date)
        return !(bucket == section && (bucket == .today || bucket == .tomorrow))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            CheckCircle(done: done) { store.complete(task) }

            VStack(alignment: .leading, spacing: 6) {
                if editing {
                    TextField("Title", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($editorFocused)
                        .onSubmit(commitEdit)
                        .onExitCommand { editing = false }
                        .onChange(of: editorFocused) { _, focused in
                            if !focused && editing { commitEdit() }
                        }
                } else {
                    Text(linkified(task.title ?? ""))
                        .font(.system(size: 14))
                        .strikethrough(done)
                        .foregroundStyle(done ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: startEdit)
                }
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                if showChip, let date = task.dueDate {
                    Button { showDue = true } label: { DueChip(date: date) }
                        .buttonStyle(.plain)
                }
            }

        }
        // Hover actions float over the row so titles get the full width when they're hidden.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                IconButton(systemName: "calendar", help: "Due date") { showDue = true }
                IconButton(systemName: "trash", help: "Delete") { Task { await store.delete(task) } }
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.15), radius: 2, y: 1))
            .padding(.top, 4)
            .padding(.trailing, 6)
            .opacity(hovering && !editing ? 1 : 0)
            .allowsHitTesting(hovering && !editing)
            .popover(isPresented: $showDue, arrowEdge: .trailing) {
                DuePicker(current: task.dueDate) { picked in
                    showDue = false
                    Task { await store.setDue(task, picked) }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .padding(.leading, task.parent != nil ? 28 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
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

struct CheckCircle: View {
    let done: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : hovering ? "checkmark.circle" : "circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(done || hovering ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Mark complete")
        .onHover { hovering = $0 }
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
        HStack(spacing: 4) {
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
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
