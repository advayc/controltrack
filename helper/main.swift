import SwiftUI
import AppKit
import IOKit
import CryptoKit

struct Session: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var start: Date
    var plannedEnd: Date
    var actualEnd: Date?
    var estimatedStart: Bool = false
}
struct Archive: Codable {
    var sessions: [Session] = []
    var nextName: String = ""
    var groupNames: [String]? = nil
    var importedGroupFiles: [String]? = nil
    var groupColors: [String: Int]? = nil
    var customColors: [String: String]? = nil
}
struct BlockState { var running: Bool; var end: Date? }
struct TrackerCommand: Decodable { var type: String; var id: UUID?; var name: String; var oldName: String?; var response: Bool?; var colorIndex: Int? }
struct CommandResponse: Encodable { var ok: Bool; var error: String? }
func groupError(_ message: String) -> NSError {
    NSError(domain: "SelfControlTracker.Groups", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func sameGroup(_ first: String, _ second: String) -> Bool {
    first.compare(second, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
}
func validatedGroupName(_ input: String) throws -> String {
    let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw groupError("Enter a subject or group.") }
    guard name.count <= 120 && name.rangeOfCharacter(from: .controlCharacters) == nil else { throw groupError("Use a single line of at most 120 characters.") }
    guard !sameGroup(name, "Focus session") else { throw groupError("Choose a name other than the default Focus session.") }
    return name
}

func settingsPath() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let serial = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
    let digest = Insecure.SHA1.hash(data: Data(("SelfControlUserPreferences" + serial).utf8))
    return "/usr/local/etc/." + digest.map { String(format: "%02x", $0) }.joined() + ".plist"
}
func readState(path: String) throws -> BlockState? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let running = dict["BlockIsRunning"] as? Bool else { throw NSError(domain: "FocusLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "SelfControl's settings could not be read."]) }
    return BlockState(running: running, end: dict["BlockEndDate"] as? Date)
}
func durationText(_ seconds: TimeInterval) -> String {
    let mins = max(0, Int(seconds / 60)); let h = mins / 60; let m = mins % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
func countdownText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(ceil(seconds)))
    let hours = total / 3600, minutes = (total % 3600) / 60, remainder = total % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
}
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var nextName = ""
    @Published var storedGroups: [String] = []
    @Published var groupColors: [String: Int] = [:]
    @Published var customColors: [String: String] = [:]
    private var importedGroupFiles: Set<String> = []
    @Published var status = "Connecting to SelfControl…"
    @Published var running = false
    @Published var readError: String? = nil
    private var timer: Timer?
    private var archiveHealthy = true
    var onSessionStarted: ((UUID) -> Void)?
    let archiveURL: URL
    let statePath: String?
    init(path: String? = settingsPath(), archiveURL: URL? = nil, startTimer: Bool = true) {
        self.statePath = path
        self.archiveURL = archiveURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Focus Ledger/sessions.json")
        if FileManager.default.fileExists(atPath: self.archiveURL.path) {
            do {
                let data = try Data(contentsOf: self.archiveURL)
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                sessions = archive.sessions; nextName = archive.nextName
                storedGroups = archive.groupNames ?? []
                groupColors = archive.groupColors ?? [:]
                customColors = archive.customColors ?? [:]
                importedGroupFiles = Set(archive.importedGroupFiles ?? [])
            } catch {
                archiveHealthy = false
                status = "History unavailable"
                readError = "Could not read the existing session history. It has not been changed."
            }
        }
        if archiveHealthy { importLegacyGroups() }
        if startTimer { startMonitoring() }
    }
    func startMonitoring() {
        poll()
        let monitor = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(monitor, forMode: .common)
        timer = monitor
    }
    @discardableResult func save() -> Bool {
        guard archiveHealthy else { return false }
        do {
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(sessions: sessions, nextName: nextName, groupNames: storedGroups, importedGroupFiles: importedGroupFiles.sorted(), groupColors: groupColors, customColors: customColors))
            try data.write(to: archiveURL, options: .atomic)
            return true
        } catch { readError = "Could not save session history: \(error.localizedDescription)"; return false }
    }
    func poll(now: Date = Date()) {
        guard archiveHealthy else { return }
        importLegacyGroups()
        processCommands()
        guard let path = statePath else { status = "SelfControl unavailable"; readError = "Could not locate SelfControl's settings."; return }
        do {
            let block = try readState(path: path)
            if block == nil { status = "Ready for your next block"; running = false; return }
            apply(block!, now: now)
        } catch { status = "Connection unavailable"; readError = "Could not read SelfControl's state. History is preserved; tracking will retry." }
    }
    func apply(_ block: BlockState, now: Date) {
        guard archiveHealthy else { return }
        readError = nil
        if block.running {
            guard let end = block.end else { status = "Waiting for SelfControl…"; return }
            running = true; status = end > now ? "SelfControl block in progress" : "Waiting for SelfControl to finish"
            if let i = sessions.firstIndex(where: { $0.actualEnd == nil }) {
                if sessions[i].plannedEnd != end { sessions[i].plannedEnd = end; save() }
            } else {
                let chosen = nextName.trimmingCharacters(in: .whitespacesAndNewlines)
                let session = Session(name: chosen.isEmpty ? "Focus session" : chosen, start: now, plannedEnd: end, estimatedStart: false)
                sessions.insert(session, at: 0)
                nextName = ""; save()
                onSessionStarted?(session.id)
            }
        } else {
            running = false; status = "Ready for your next block"
            if let i = sessions.firstIndex(where: { $0.actualEnd == nil }) {
                sessions[i].actualEnd = max(sessions[i].start, min(now, sessions[i].plannedEnd)); save()
            }
        }
    }
    func rename(_ id: UUID, _ value: String) { if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].name = value; save() } }
    var groupDirectory: URL { archiveURL.deletingLastPathComponent().appendingPathComponent("groups", isDirectory: true) }
    func importLegacyGroups() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: groupDirectory, includingPropertiesForKeys: nil)) ?? []
        let oldGroups = storedGroups
        let oldImported = importedGroupFiles
        for url in urls where url.pathExtension == "json" && !importedGroupFiles.contains(url.lastPathComponent) {
            guard let data = try? Data(contentsOf: url), let name = try? JSONDecoder().decode(String.self, from: data) else { continue }
            importedGroupFiles.insert(url.lastPathComponent)
            if let valid = try? validatedGroupName(name), !storedGroups.contains(where: { sameGroup($0, valid) }) { storedGroups.append(valid) }
        }
        if oldImported != importedGroupFiles && !save() {
            storedGroups = oldGroups
            importedGroupFiles = oldImported
        }
    }
    func groups() -> [String] {
        var result: [String] = []
        for rawName in storedGroups + sessions.map({ $0.name }) {
            guard let name = try? validatedGroupName(rawName) else { continue }
            if !result.contains(where: { sameGroup($0, name) }) { result.append(name) }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func addGroup(_ input: String) throws {
        let name = try validatedGroupName(input)
        if groups().contains(where: { sameGroup($0, name) }) { return }
        let previous = storedGroups
        storedGroups.append(name)
        if !save() { storedGroups = previous; throw groupError("Could not save the group. Try again.") }
    }
    func renameGroup(_ oldInput: String, to newInput: String) throws {
        let oldName = try validatedGroupName(oldInput)
        let newName = try validatedGroupName(newInput)
        let existing = groups()
        guard existing.contains(where: { sameGroup($0, oldName) }) else { throw groupError("That group no longer exists.") }
        guard !existing.contains(where: { sameGroup($0, newName) && !sameGroup($0, oldName) }) else { throw groupError("A group with that name already exists.") }
        let previousGroups = storedGroups
        let previousSessions = sessions
        let previousNextName = nextName
        let previousColors = groupColors
        let previousCustomColors = customColors
        if let key = customColors.keys.first(where: { sameGroup($0, oldName) }), let color = customColors.removeValue(forKey: key) { customColors[newName] = color }
        if let key = groupColors.keys.first(where: { sameGroup($0, oldName) }), let color = groupColors.removeValue(forKey: key) { groupColors[newName] = color }
        storedGroups.removeAll { sameGroup($0, oldName) }
        storedGroups.append(newName)
        for index in sessions.indices where sameGroup(sessions[index].name, oldName) { sessions[index].name = newName }
        if sameGroup(nextName, oldName) { nextName = newName }
        if !save() {
            storedGroups = previousGroups; sessions = previousSessions; nextName = previousNextName; groupColors = previousColors; customColors = previousCustomColors
            throw groupError("Could not save the group. Try again.")
        }
    }
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
    func colorIndex(_ name: String) -> Int {
        if let key = groupColors.keys.first(where: { sameGroup($0, name) }), let index = groupColors[key], (0..<Self.palette.count).contains(index) { return index }
        return name.lowercased().utf8.reduce(0) { ($0 + Int($1)) % Self.palette.count }
    }
    func displayColor(_ name: String) -> Color {
        if let key = customColors.keys.first(where: { sameGroup($0, name) }), let hex = customColors[key], let value = UInt(hex, radix: 16) {
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
        return Self.palette[colorIndex(name)]
    }
    func setCustomColor(_ name: String, color: Color) throws {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { throw groupError("Could not use that color.") }
        let hex = String(format: "%02X%02X%02X", Int((value.redComponent * 255).rounded()), Int((value.greenComponent * 255).rounded()), Int((value.blueComponent * 255).rounded()))
        let previous = customColors
        if let key = customColors.keys.first(where: { sameGroup($0, name) }) { customColors.removeValue(forKey: key) }
        customColors[name] = hex
        if !save() { customColors = previous; throw groupError("Could not save the color.") }
    }
    func setColor(_ name: String, index: Int) throws {
        guard (0..<Self.palette.count).contains(index) else { throw groupError("Choose a color.") }
        let previous = groupColors
        let previousCustom = customColors
        if let key = customColors.keys.first(where: { sameGroup($0, name) }) { customColors.removeValue(forKey: key) }
        if let key = groupColors.keys.first(where: { sameGroup($0, name) }) { groupColors.removeValue(forKey: key) }
        groupColors[name] = index
        if !save() { groupColors = previous; customColors = previousCustom; throw groupError("Could not save the color.") }
    }
    func deleteGroup(_ input: String) throws {
        let name = try validatedGroupName(input)
        guard groups().contains(where: { sameGroup($0, name) }) else { throw groupError("That group no longer exists.") }
        let previousGroups = storedGroups, previousSessions = sessions, previousNextName = nextName
        storedGroups.removeAll { sameGroup($0, name) }
        for index in sessions.indices where sameGroup(sessions[index].name, name) { sessions[index].name = "Focus session" }
        if sameGroup(nextName, name) { nextName = "" }
        if !save() {
            storedGroups = previousGroups; sessions = previousSessions; nextName = previousNextName
            throw groupError("Could not delete the group. Try again.")
        }
    }
    var commandDirectory: URL { archiveURL.deletingLastPathComponent().appendingPathComponent("commands", isDirectory: true) }
    func processCommands() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: commandDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url), let command = try? JSONDecoder().decode(TrackerCommand.self, from: data) else { continue }
            var failure: String?
            do {
                switch command.type {
                case "renameSession":
                    guard let id = command.id, let i = sessions.firstIndex(where: { $0.id == id }) else { throw groupError("That session no longer exists.") }
                    let name = try validatedGroupName(command.name)
                    let canonical = groups().first { sameGroup($0, name) } ?? name
                    try addGroup(canonical)
                    let previous = sessions[i].name
                    sessions[i].name = canonical
                    if !save() { sessions[i].name = previous; throw groupError("Could not save the session. Try again.") }
                case "setGroupColor":
                    guard let color = command.colorIndex, groups().contains(where: { sameGroup($0, command.name) }) else { throw groupError("That group no longer exists.") }
                    try setColor(command.name, index: color)
                case "deleteGroup":
                    try deleteGroup(command.name)
                case "addGroup":
                    try addGroup(command.name)
                case "renameGroup":
                    guard let oldName = command.oldName else { throw groupError("Choose a group to rename.") }
                    try renameGroup(oldName, to: command.name)
                default:
                    throw groupError("The tracker could not understand this request.")
                }
            } catch { failure = error.localizedDescription }
            if command.response == true {
                let responseURL = url.deletingPathExtension().appendingPathExtension("result")
                let result = CommandResponse(ok: failure == nil, error: failure)
                guard let responseData = try? JSONEncoder().encode(result), (try? responseData.write(to: responseURL, options: .atomic)) != nil else { continue }
                try? FileManager.default.removeItem(at: url)
            } else if failure == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    func focus(group: String, in day: Date, now: Date = Date()) -> TimeInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return sessions.filter { sameGroup($0.name, group) }.reduce(0) { sum, session in
            let stop = session.actualEnd ?? min(now, session.plannedEnd)
            return sum + max(0, min(end, stop).timeIntervalSince(max(start, session.start)))
        }
    }
    func focus(in day: Date, now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current; let start = cal.startOfDay(for: day); let end = cal.date(byAdding: .day, value: 1, to: start)!
        return sessions.reduce(0) { total, session in
            let sessionEnd = session.actualEnd ?? min(now, session.plannedEnd)
            return total + max(0, min(end, sessionEnd).timeIntervalSince(max(start, session.start)))
        }
    }
}
func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
        NSColor.black.setStroke()
        let spade = NSBezierPath()
        spade.move(to: NSPoint(x: 12, y: 23))
        spade.curve(to: NSPoint(x: 2, y: 9), controlPoint1: NSPoint(x: 9, y: 19), controlPoint2: NSPoint(x: 2, y: 15))
        spade.curve(to: NSPoint(x: 10, y: 6), controlPoint1: NSPoint(x: 2, y: 4), controlPoint2: NSPoint(x: 7, y: 4))
        spade.line(to: NSPoint(x: 8, y: 1.5)); spade.line(to: NSPoint(x: 16, y: 1.5)); spade.line(to: NSPoint(x: 14, y: 6))
        spade.curve(to: NSPoint(x: 22, y: 9), controlPoint1: NSPoint(x: 17, y: 4), controlPoint2: NSPoint(x: 22, y: 4))
        spade.curve(to: NSPoint(x: 12, y: 23), controlPoint1: NSPoint(x: 22, y: 15), controlPoint2: NSPoint(x: 15, y: 19))
        spade.close(); spade.lineWidth = 1.5; spade.lineJoinStyle = .round; spade.stroke()
        let skull = NSBezierPath(roundedRect: NSRect(x: 7, y: 9, width: 10, height: 9), xRadius: 4, yRadius: 4)
        skull.lineWidth = 1.3; skull.stroke()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8.5, y: 12, width: 2.3, height: 2.8)).fill()
        NSBezierPath(ovalIn: NSRect(x: 13.2, y: 12, width: 2.3, height: 2.8)).fill()
        let jaw = NSBezierPath(); jaw.move(to: NSPoint(x: 9, y: 10)); jaw.line(to: NSPoint(x: 9, y: 7)); jaw.line(to: NSPoint(x: 15, y: 7)); jaw.line(to: NSPoint(x: 15, y: 10)); jaw.lineWidth = 1.3; jaw.stroke()
        return true
    }
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    return image
}
struct GroupIconButton: View {
    let symbol: String
    let label: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundColor(hovered ? (destructive ? .red : .accentColor) : .secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill((destructive ? Color.red : Color.accentColor).opacity(hovered ? 0.16 : 0)))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
        .animation(.easeOut(duration: 0.12), value: hovered).onHover { hovered = $0 }
    }
}
struct GroupActions: View {
    let name: String
    let duration: String?
    let color: Color
    let rename: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name)
            Spacer()
            if let duration { Text(duration).monospacedDigit().foregroundColor(.secondary) }
            GroupIconButton(symbol: "pencil", label: "Rename " + name, action: rename)
            GroupIconButton(symbol: "trash", label: "Delete " + name, destructive: true, action: remove)
        }.padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered ? 0.08 : 0)))
        .animation(.easeOut(duration: 0.15), value: hovered).onHover { hovered = $0 }
    }
}
struct ChartSegment: View {
    let day: Date
    let group: String
    let seconds: TimeInterval
    let maximum: TimeInterval
    let color: Color
    let sessionHovered: Bool
    @Binding var inspectedDay: Date?
    @Binding var inspectedGroup: String?
    var body: some View {
        Rectangle().fill(color)
            .brightness(sessionHovered ? -0.16 : 0)
            .opacity(inspectedDay == day && inspectedGroup == group ? 0.7 : 1)
            .frame(height: CGFloat(seconds / maximum) * 52)
            .contentShape(Rectangle())
            .onHover { over in
                if over { inspectedDay = day; inspectedGroup = group }
                else if inspectedDay == day && inspectedGroup == group { inspectedGroup = nil }
            }
            .onTapGesture { inspectedDay = day; inspectedGroup = group }
            .help(group + ": " + durationText(seconds))
    }
}
struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let original: String?
}
private let presetColorList: NSColorList = {
    let list = NSColorList(name: "SelfControl Presets")
    let colors: [(String, NSColor)] = [("Blue", .systemBlue), ("Green", .systemGreen), ("Orange", .systemOrange), ("Purple", .systemPurple), ("Pink", .systemPink), ("Teal", .systemTeal)]
    for (name, color) in colors { list.setColor(color, forKey: name) }
    return list
}()
struct GroupEditor: View {
    @ObservedObject var store: Store
    let original: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedColor: Color
    @State private var error: String?
    init(store: Store, original: String?) {
        self.store = store
        self.original = original
        _name = State(initialValue: original ?? "")
        _selectedColor = State(initialValue: original.map { store.displayColor($0) } ?? .blue)
    }
    private func save() {
        do {
            if let original { try store.renameGroup(original, to: name) }
            else { try store.addGroup(name) }
            try store.setCustomColor(name.trimmingCharacters(in: .whitespacesAndNewlines), color: selectedColor)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New Group" : "Rename Group").font(.headline)
            TextField("Subject or group", text: $name).onSubmit(save)
            ColorPicker("Color", selection: $selectedColor, supportsOpacity: false)
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360)
        .onAppear { NSColorPanel.shared.attachColorList(presetColorList) }
    }
}
struct Dashboard: View {
    @ObservedObject var store: Store
    let isDemo: Bool
    @State private var showHistory: Bool
    init(store: Store, isDemo: Bool = false, previewTimer: Bool = false) {
        self.store = store
        self.isDemo = isDemo
        _showHistory = State(initialValue: isDemo && !previewTimer)
    }
    @State private var now = Date()
    @State private var showGroups = false
    @State private var groupEditor: GroupEditorRequest?
    @State private var sessionsExpanded = false
    @State private var statisticsHovered = false
    @State private var inspectedDay: Date?
    @State private var inspectedGroup: String?
    @State private var hoveredSessionGroup: String?
    let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var remaining: TimeInterval? { store.sessions.first(where: { $0.actualEnd == nil }).map { max(0, $0.plannedEnd.timeIntervalSince(now)) } }
    var statusColor: Color {
        guard store.running, let seconds = remaining else { return .secondary }
        return seconds <= 60 ? .red : seconds <= 300 ? .orange : .green
    }
    var remainingText: String {
        guard let seconds = remaining else { return "" }
        return countdownText(seconds)
    }
    var days: [Date] { (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) } }
    var groupTotals: [(name: String, seconds: TimeInterval)] {
        var sums: [(name: String, seconds: TimeInterval)] = []
        for session in store.sessions {
            let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.isEmpty ? "Focus session" : name
            let seconds = max(0, (session.actualEnd ?? min(now, session.plannedEnd)).timeIntervalSince(session.start))
            if let index = sums.firstIndex(where: { sameGroup($0.name, key) }) { sums[index].seconds += seconds }
            else { sums.append((name: key, seconds: seconds)) }
        }
        return sums.sorted { $0.seconds > $1.seconds }
    }
    private func deleteGroup(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete this group?"
        alert.informativeText = "Its sessions will stay in your history without a subject."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try store.deleteGroup(name) }
            catch { let errorAlert = NSAlert(error: error); errorAlert.runModal() }
        }
    }
    var body: some View {
        VStack(spacing: 10) {
            if showGroups {
                HStack {
                    Button("Back") { showGroups = false }
                    Spacer()
                    Text("Groups").font(.headline)
                    Spacer()
                    Button("New") { groupEditor = GroupEditorRequest(original: nil) }
                }
                if store.groups().isEmpty {
                    Spacer(); Text("No groups yet").foregroundColor(.secondary); Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(store.groups(), id: \.self) { name in
                                GroupActions(name: name, duration: nil, color: store.displayColor(name), rename: { groupEditor = GroupEditorRequest(original: name) }, remove: { deleteGroup(name) })
                                Divider()
                            }
                        }
                    }
                }
            } else if showHistory {
                HStack {
                    Button("Done") { showHistory = false }
                    Spacer()
                    Text(isDemo ? "Statistics · Example data" : "Statistics").font(.headline)
                    Spacer()
                    Text("\(store.sessions.count) sessions").font(.caption).foregroundColor(.secondary)
                }
                let values = days.map { store.focus(in: $0, now: now) }
                let maximum = max(values.max() ?? 0, 3600)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        VStack(spacing: 3) {
                            Text(durationText(values[index])).font(.caption2).foregroundColor(.secondary)
                            VStack(spacing: 0) {
                                ForEach(store.groups() + ["Focus session"], id: \.self) { group in
                                    let seconds = store.focus(group: group, in: day, now: now)
                                    if seconds > 0 {
                                        ChartSegment(day: day, group: group, seconds: seconds, maximum: maximum, color: sameGroup(group, "Focus session") ? .secondary : store.displayColor(group), sessionHovered: hoveredSessionGroup.map { sameGroup($0, group) } ?? false, inspectedDay: $inspectedDay, inspectedGroup: $inspectedGroup)
                                    }
                                }
                            }.frame(height: max(3, CGFloat(values[index] / maximum) * 52), alignment: .bottom)
                             .background(Color.secondary.opacity(values[index] == 0 ? 0.15 : 0))
                             .clipShape(RoundedRectangle(cornerRadius: 2))
                            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(inspectedDay == day ? 0.08 : 0)))
                        .contentShape(Rectangle())
                        .onHover { over in if over { inspectedDay = day } else if inspectedDay == day { inspectedDay = nil; inspectedGroup = nil } }
                        .onTapGesture { inspectedDay = day }
                        .help(day.formatted(date: .abbreviated, time: .omitted) + ": " + durationText(values[index]))
                        .animation(.easeOut(duration: 0.15), value: inspectedDay)
                    }
                }.frame(height: 85, alignment: .bottom)
                if let day = inspectedDay, let group = inspectedGroup {
                    let seconds = store.focus(group: group, in: day, now: now)
                    Text(day.formatted(date: .abbreviated, time: .omitted) + " · " + group + ": " + durationText(seconds))
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                } else if let day = inspectedDay {
                    Text(day.formatted(date: .abbreviated, time: .omitted) + " · " + durationText(store.focus(in: day, now: now)))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Hover over a segment for details").font(.caption).foregroundColor(.secondary)
                }
                if store.sessions.isEmpty {
                    Spacer(); Text("No sessions yet").foregroundColor(.secondary); Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            HStack { Text("Subjects / Groups").fontWeight(.semibold); Spacer() }.padding(.vertical, 8)
                            ForEach(groupTotals, id: \.name) { group in
                                if !sameGroup(group.name, "Focus session") {
                                    GroupActions(name: group.name, duration: durationText(group.seconds), color: store.displayColor(group.name), rename: { groupEditor = GroupEditorRequest(original: group.name) }, remove: { deleteGroup(group.name) })
                                } else {
                                    HStack { Text(group.name); Spacer(); Text(durationText(group.seconds)).foregroundColor(.secondary) }.padding(.vertical, 5)
                                }
                            }
                            Divider().padding(.vertical, 8)
                            DisclosureGroup("Sessions (\(store.sessions.count))", isExpanded: $sessionsExpanded) {
                            ForEach(store.sessions) { s in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        TextField("Subject or group", text: Binding(get: { store.sessions.first(where: { $0.id == s.id })?.name ?? "" }, set: { store.rename(s.id, $0) })).textFieldStyle(.plain).fontWeight(.medium)
                                        Text(s.start.formatted(date: .abbreviated, time: .shortened) + (s.actualEnd == nil ? " · In progress" : "")).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(durationText((s.actualEnd ?? min(now, s.plannedEnd)).timeIntervalSince(s.start))).monospacedDigit().foregroundColor(.secondary)
                                }.padding(.vertical, 8)
                                .onHover { over in
                                    if over { hoveredSessionGroup = s.name }
                                    else if hoveredSessionGroup == s.name { hoveredSessionGroup = nil }
                                }
                                Divider()
                            }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(store.running ? "Block in progress" : "Ready for your next block")
                }
                if store.running && remaining != nil {
                    Text(remainingText)
                        .font(.system(size: 42, weight: .regular))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                if let error = store.readError { Text(error).font(.caption).foregroundColor(.red) }
                else if !store.running { Text("Start a block in SelfControl. You’ll be asked for a subject or group.").font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center) }
                HStack(spacing: 12) {
                    Button("Open SelfControl") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: NSHomeDirectory() + "/Applications/SelfControl.app"), configuration: NSWorkspace.OpenConfiguration()) }
                    Button("Groups") { showGroups = true }
                    Button("View Statistics") { showHistory = true }
                        .tint(statisticsHovered ? .accentColor : nil)
                        .scaleEffect(statisticsHovered ? 1.03 : 1)
                        .animation(.easeOut(duration: 0.15), value: statisticsHovered)
                        .onHover { statisticsHovered = $0 }
                }.padding(.top, 4)
                Spacer()
            }
        }.padding(22).frame(minWidth: 430, minHeight: 250).onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SelfControlTrackerSessionStarted"))) { _ in
            showHistory = false
            showGroups = false
        }
        .sheet(item: $groupEditor) { request in GroupEditor(store: store, original: request.original) }
    }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: Store
    let isDemo: Bool
    let previewTimer: Bool
    var window: NSWindow!
    var statusItem: NSStatusItem?
    override init() {
        let timerDemo = CommandLine.arguments.contains("--preview-timer") || CommandLine.arguments.contains("--export-timer")
        let demo = timerDemo || CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--export-demo")
        isDemo = demo
        previewTimer = timerDemo
        if demo {
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.json")
            let exampleStore = Store(path: nil, archiveURL: archive, startTimer: false)
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let minutes = [65, 120, 90, 0, 150, 110, 0]
            let subjects = ["Mathematics", "Biology", "Literature", "", "Mathematics", "Biology", ""]
            for index in minutes.indices where minutes[index] > 0 {
                let day = calendar.date(byAdding: .day, value: index - 6, to: startOfToday)!
                let start = calendar.date(byAdding: .hour, value: 9, to: day)!
                let end = start.addingTimeInterval(TimeInterval(minutes[index] * 60))
                exampleStore.sessions.insert(Session(name: subjects[index], start: start, plannedEnd: end, actualEnd: end), at: 0)
            }
            if timerDemo {
                let now = Date()
                exampleStore.sessions = [Session(name: "Example", start: now.addingTimeInterval(-45), plannedEnd: now.addingTimeInterval(15))]
                exampleStore.running = true
            }
            store = exampleStore
        } else {
            store = Store(startTimer: false)
        }
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: isDemo && !previewTimer ? 440 : 330), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SelfControl Tracker"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        if isDemo { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentView = NSHostingView(rootView: Dashboard(store: store, isDemo: isDemo, previewTimer: previewTimer))
        if !isDemo {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = NSStatusItem.AutosaveName("SelfControlTracker")
            item.isVisible = true
            item.button?.image = menuBarIcon()
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = "SelfControl Tracker"
            item.button?.setAccessibilityLabel("Open SelfControl Tracker")
            item.button?.target = self
            item.button?.action = #selector(toggleWindow)
            statusItem = item
            store.onSessionStarted = { [weak self] id in
                NotificationCenter.default.post(name: Notification.Name("SelfControlTrackerSessionStarted"), object: nil)
                self?.showWindow()
                self?.askForSubject(id)
                self?.showWindow()
            }
            store.startMonitoring()
            if store.running { showWindow() }
        }
        if CommandLine.arguments.contains("--preview-prompt") { DispatchQueue.main.async { self.askForSubject(UUID()) } }
        if !CommandLine.arguments.contains("--background") { showWindow() }
        if let argument = CommandLine.arguments.firstIndex(where: { $0 == "--export-demo" || $0 == "--export-timer" }), argument + 1 < CommandLine.arguments.count {
            let destination = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let view = self.window.contentView, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: representation)
                guard let composited = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: representation.pixelsWide, pixelsHigh: representation.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
                composited.size = view.bounds.size
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composited)
                    NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
                    view.bounds.fill()
                    let captured = NSImage(size: view.bounds.size)
                    captured.addRepresentation(representation)
                    captured.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
                guard let png = composited.representation(using: .png, properties: [:]) else { exit(1) }
                do { try png.write(to: destination, options: .atomic); NSApp.terminate(nil) }
                catch { NSLog("Could not export demo: %@", error.localizedDescription); exit(1) }
            }
        }
    }
    func askForSubject(_ id: UUID) {
        let alert = NSAlert(); alert.messageText = "What are you focusing on?"; alert.informativeText = "Enter a subject or group for this SelfControl block."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Skip")
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        box.placeholderString = "Subject or group"
        let names = store.groups()
        box.addItems(withObjectValues: names); alert.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = box.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let existing = names.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                let canonical = existing ?? name
                if existing == nil { try? store.addGroup(canonical) }
                store.rename(id, canonical)
            }
        }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggleWindow() { if window.isVisible && window.isKeyWindow { window.close() } else { showWindow() } }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}
if CommandLine.arguments.contains("--self-test") {
    precondition(countdownText(15) == "00:00:15")
    precondition(countdownText(61) == "00:01:01")
    precondition(countdownText(3601) == "01:00:01")
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.json")
    let s = Store(path: nil, archiveURL: path, startTimer: false)
    let start = Date(timeIntervalSince1970: 1800000000); let end = start.addingTimeInterval(3600)
    var prompts = 0; s.onSessionStarted = { _ in prompts += 1 }
    s.nextName = "Study"; s.apply(BlockState(running: true, end: end), now: start)
    precondition(s.sessions.count == 1 && s.sessions[0].name == "Study")
    s.apply(BlockState(running: true, end: end.addingTimeInterval(600)), now: start.addingTimeInterval(10))
    precondition(s.sessions.count == 1 && s.sessions[0].plannedEnd == end.addingTimeInterval(600) && prompts == 1)
    s.apply(BlockState(running: false, end: nil), now: end.addingTimeInterval(620))
    precondition(s.sessions[0].actualEnd == end.addingTimeInterval(600))
    let fixture = path.deletingLastPathComponent().appendingPathComponent("block.plist")
    let fixtureData = try! PropertyListSerialization.data(fromPropertyList: ["BlockIsRunning": true, "BlockEndDate": end], format: .binary, options: 0)
    try! fixtureData.write(to: fixture)
    let parsed = try! readState(path: fixture.path)
    precondition(parsed?.running == true && parsed?.end == end)
    precondition(settingsPath() != nil)
    try! s.addGroup("Calculus")
    let restored = Store(path: nil, archiveURL: path, startTimer: false)
    precondition(restored.sessions.count == 1 && restored.sessions[0].name == "Study")
    precondition(restored.groups().contains("Calculus") && restored.groups().contains("Study"))
    try! FileManager.default.createDirectory(at: restored.commandDirectory, withIntermediateDirectories: true)
    let commandPath = restored.commandDirectory.appendingPathComponent("test.json")
    let commandData = try! JSONSerialization.data(withJSONObject: ["type": "renameSession", "id": restored.sessions[0].id.uuidString, "name": "calculus"])
    try! commandData.write(to: commandPath)
    restored.processCommands()
    precondition(restored.sessions[0].name == "Calculus" && !FileManager.default.fileExists(atPath: commandPath.path))
    precondition(Store(path: nil, archiveURL: path, startTimer: false).sessions[0].name == "Calculus")
    let sessionID = restored.sessions[0].id
    let sessionEnd = restored.sessions[0].actualEnd
    try! restored.renameGroup("calculus", to: "Mathematics")
    precondition(restored.sessions[0].name == "Mathematics" && restored.sessions[0].id == sessionID && restored.sessions[0].actualEnd == sessionEnd)
    precondition(!restored.groups().contains(where: { sameGroup($0, "Calculus") }))
    try! restored.addGroup("Physics")
    try! restored.renameGroup("Physics", to: "Physics II")
    precondition(Store(path: nil, archiveURL: path, startTimer: false).groups().contains("Physics II"))
    let beforeConflict = try! Data(contentsOf: path)
    do { try restored.renameGroup("Mathematics", to: "Physics II"); preconditionFailure("Group collision must be rejected") }
    catch { precondition((try! Data(contentsOf: path)) == beforeConflict) }
    try! restored.renameGroup("Mathematics", to: "MATHEMATICS")
    precondition(restored.sessions[0].name == "MATHEMATICS")
    try! FileManager.default.createDirectory(at: restored.groupDirectory, withIntermediateDirectories: true)
    let legacy = restored.groupDirectory.appendingPathComponent("legacy.json")
    try! JSONEncoder().encode("Essay").write(to: legacy)
    restored.importLegacyGroups()
    precondition(restored.groups().contains("Essay"))
    try! restored.renameGroup("Essay", to: "Writing")
    let migrated = Store(path: nil, archiveURL: path, startTimer: false)
    precondition(migrated.groups().contains("Writing") && !migrated.groups().contains("Essay"))
    let renameRequest = migrated.commandDirectory.appendingPathComponent("group-test.json")
    let renameData = try! JSONSerialization.data(withJSONObject: ["type": "renameGroup", "oldName": "MATHEMATICS", "name": "Algebra", "response": true])
    try! renameData.write(to: renameRequest)
    migrated.processCommands()
    let responseURL = migrated.commandDirectory.appendingPathComponent("group-test.result")
    let response = try! JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as! [String: Any]
    precondition(response["ok"] as? Bool == true && migrated.sessions[0].name == "Algebra")
    precondition(!FileManager.default.fileExists(atPath: renameRequest.path))
    let conflictRequest = migrated.commandDirectory.appendingPathComponent("conflict-test.json")
    let conflictData = try! JSONSerialization.data(withJSONObject: ["type": "renameGroup", "oldName": "Algebra", "name": "Physics II", "response": true])
    try! conflictData.write(to: conflictRequest)
    migrated.processCommands()
    let conflictResponseURL = migrated.commandDirectory.appendingPathComponent("conflict-test.result")
    let conflictResponse = try! JSONSerialization.jsonObject(with: Data(contentsOf: conflictResponseURL)) as! [String: Any]
    precondition(conflictResponse["ok"] as? Bool == false && migrated.sessions[0].name == "Algebra")
    precondition(Store(path: nil, archiveURL: path, startTimer: false).sessions[0].name == "Algebra")
    let oldDirectory = path.deletingLastPathComponent().appendingPathComponent("old-format")
    try! FileManager.default.createDirectory(at: oldDirectory.appendingPathComponent("groups"), withIntermediateDirectories: true)
    let oldArchiveURL = oldDirectory.appendingPathComponent("sessions.json")
    let oldSession = Session(name: "Old subject", start: start, plannedEnd: end, actualEnd: end)
    try! JSONEncoder().encode(Archive(sessions: [oldSession], nextName: "")).write(to: oldArchiveURL)
    let oldGroupFile = oldDirectory.appendingPathComponent("groups/unassigned.json")
    try! JSONEncoder().encode("Unassigned").write(to: oldGroupFile)
    let oldStore = Store(path: nil, archiveURL: oldArchiveURL, startTimer: false)
    precondition(oldStore.sessions.count == 1 && oldStore.sessions[0].id == oldSession.id && oldStore.groups().contains("Unassigned"))
    precondition(FileManager.default.fileExists(atPath: oldGroupFile.path))
    try! oldStore.renameGroup("Unassigned", to: "New name")
    let oldReload = Store(path: nil, archiveURL: oldArchiveURL, startTimer: false)
    precondition(oldReload.groups().contains("New name") && !oldReload.groups().contains("Unassigned") && oldReload.sessions[0].id == oldSession.id)
    let countBeforeDelete = migrated.sessions.count
    let endBeforeDelete = migrated.sessions[0].actualEnd
    try! migrated.deleteGroup("Algebra")
    precondition(migrated.sessions.count == countBeforeDelete && migrated.sessions[0].actualEnd == endBeforeDelete)
    precondition(migrated.sessions[0].name == "Focus session" && !migrated.groups().contains("Algebra"))
    let splitStore = Store(path: nil, archiveURL: path.deletingLastPathComponent().appendingPathComponent("split.json"), startTimer: false)
    let splitStart = Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: start))!
    splitStore.sessions = [Session(name: "Study A", start: splitStart, plannedEnd: splitStart.addingTimeInterval(1200), actualEnd: splitStart.addingTimeInterval(1200)), Session(name: "Study B", start: splitStart, plannedEnd: splitStart.addingTimeInterval(1800), actualEnd: splitStart.addingTimeInterval(1800))]
    precondition(splitStore.focus(group: "Study A", in: splitStart) == 1200 && splitStore.focus(group: "Study B", in: splitStart) == 1800)
    let corruptPath = path.deletingLastPathComponent().appendingPathComponent("corrupt.json")
    try! Data("not a valid archive".utf8).write(to: corruptPath)
    let corruptStore = Store(path: nil, archiveURL: corruptPath, startTimer: false)
    corruptStore.apply(BlockState(running: true, end: end), now: start)
    precondition((try! Data(contentsOf: corruptPath)) == Data("not a valid archive".utf8))
    try? FileManager.default.removeItem(at: path.deletingLastPathComponent()); print("Self-test passed")
} else {
    let app = NSApplication.shared; let delegate = Delegate(); app.delegate = delegate; app.run()
}
