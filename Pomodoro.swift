import SwiftUI
import UserNotifications
import AppKit

enum Phase: String, CaseIterable, Identifiable, Codable {
    case focus = "Focus", short = "Short Break", long = "Long Break"
    var id: String { rawValue }
    var shortName: String { switch self { case .focus: "Focus"; case .short: "Short"; case .long: "Long" } }
    var defaultMinutes: Int { switch self { case .focus: 25; case .short: 5; case .long: 15 } }
    var tint: Color {
        switch self {
        case .focus: Color(red: 1.0, green: 0.38, blue: 0.33)
        case .short: Color(red: 0.25, green: 0.80, blue: 0.62)
        case .long: Color(red: 0.36, green: 0.55, blue: 1.0)
        }
    }
}

struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var minutes: [Phase: Int]
    var cycles: Int?  // optional so presets saved before cycles existed still decode

    var cycleCount: Int { cycles ?? PomodoroModel.defaultCycles }
    var summary: String {
        Phase.allCases.map { "\(minutes[$0] ?? $0.defaultMinutes)" }.joined(separator: " / ") + " · \(cycleCount)×"
    }
}

@MainActor
final class PomodoroModel: ObservableObject {
    nonisolated static let minuteRange = 1...180
    nonisolated static let cycleRange = 1...12
    nonisolated static let defaultCycles = 4

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isRunning = false
    @Published private(set) var completedFocus = 0
    @Published private(set) var minutes: [Phase: Int] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(minutes), forKey: "minutes")
            if !isRunning { remaining = total }
        }
    }
    @Published private(set) var cycles: Int {
        didSet { UserDefaults.standard.set(cycles, forKey: "cycles") }
    }
    @Published private(set) var presets: [Preset] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "presets") }
    }

    private var endDate: Date?
    private var ticker: Timer?

    var total: TimeInterval { TimeInterval(minutes(for: phase) * 60) }
    var progress: Double { min(1, max(0, 1 - remaining / total)) }
    var timeString: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    init() {
        let defaults = UserDefaults.standard
        minutes = defaults.data(forKey: "minutes").flatMap { try? JSONDecoder().decode([Phase: Int].self, from: $0) }
            ?? Dictionary(uniqueKeysWithValues: Phase.allCases.map { ($0, $0.defaultMinutes) })
        let savedCycles = defaults.integer(forKey: "cycles")
        cycles = Self.cycleRange.contains(savedCycles) ? savedCycles : Self.defaultCycles
        presets = (defaults.data(forKey: "presets").flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? [])
            .filter { !Self.isReservedName($0.name) }
        remaining = total
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func minutes(for p: Phase) -> Int { minutes[p] ?? p.defaultMinutes }

    func setMinutes(_ value: Int, for p: Phase) {
        minutes[p] = min(max(value, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
    }

    func setCycles(_ value: Int) {
        cycles = min(max(value, Self.cycleRange.lowerBound), Self.cycleRange.upperBound)
    }

    static let builtInPresets: [Preset] = [
        builtIn(1, "Default", Phase.focus.defaultMinutes, Phase.short.defaultMinutes, Phase.long.defaultMinutes, defaultCycles),
        builtIn(2, "Quick Sprint", 15, 3, 10, 4),
        builtIn(3, "Deep Work", 50, 10, 30, 3),
        builtIn(4, "Flow State", 90, 20, 30, 2),
    ]

    private static func builtIn(_ n: Int, _ name: String, _ focus: Int, _ short: Int, _ long: Int, _ cycles: Int) -> Preset {
        Preset(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
               name: name, minutes: [.focus: focus, .short: short, .long: long], cycles: cycles)
    }

    /// Built-in presets first, then the user's own.
    var allPresets: [Preset] { Self.builtInPresets + presets }

    func isBuiltIn(_ preset: Preset) -> Bool { Self.builtInPresets.contains { $0.id == preset.id } }

    static func isReservedName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return builtInPresets.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isReservedName(trimmed) else { return }
        if let i = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[i].minutes = minutes
            presets[i].cycles = cycles
        } else {
            presets.append(Preset(name: trimmed, minutes: minutes, cycles: cycles))
        }
    }

    func apply(_ preset: Preset) {
        minutes = preset.minutes
        setCycles(preset.cycleCount)
    }

    func delete(_ preset: Preset) { presets.removeAll { $0.id == preset.id } }

    func isActive(_ preset: Preset) -> Bool {
        preset.cycleCount == cycles
            && Phase.allCases.allSatisfy { (preset.minutes[$0] ?? $0.defaultMinutes) == minutes(for: $0) }
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        ticker?.invalidate(); ticker = nil
        isRunning = false
        endDate = nil
    }

    func reset() { pause(); remaining = total }

    func select(_ p: Phase) { pause(); phase = p; remaining = total }

    func resetCompleted() { completedFocus = 0 }

    func skip() { advance(notify: false) }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 { advance(notify: true) }
    }

    private func advance(notify: Bool) {
        let finished = phase
        if finished == .focus { completedFocus += 1 }
        let next: Phase = finished == .focus ? (completedFocus % cycles == 0 ? .long : .short) : .focus
        select(next)
        if notify {
            NSSound(named: "Glass")?.play()
            let content = UNMutableNotificationContent()
            content.title = finished == .focus ? "Focus complete" : "Break over"
            content.body = "Up next: \(next.rawValue) · \(minutes(for: next)) min"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

struct RingView: View {
    let progress: Double
    let tint: Color
    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.6), tint], center: .center),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
        }
    }
}

struct TimerView: View {
    @ObservedObject var model: PomodoroModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Menu {
                ForEach(model.allPresets) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        if model.isActive(preset) {
                            Label("\(preset.name)  (\(preset.summary))", systemImage: "checkmark")
                        } else {
                            Text("\(preset.name)  (\(preset.summary))")
                        }
                    }
                }
                Divider()
                Button("Manage presets…", action: openSettings)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                    Text(model.allPresets.first(where: model.isActive)?.name ?? "Custom")
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(Capsule().fill(.primary.opacity(0.06)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Presets")

            HStack(spacing: 4) {
                ForEach(Phase.allCases) { p in
                    Button { model.select(p) } label: {
                        Text(p.shortName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(model.phase == p ? p.tint.opacity(0.22) : .clear))
                            .foregroundStyle(model.phase == p ? p.tint : .secondary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(.primary.opacity(0.06)))

            ZStack {
                RingView(progress: model.progress, tint: model.phase.tint)
                VStack(spacing: 2) {
                    Text(model.timeString)
                        .font(.system(size: 40, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(model.isRunning ? model.phase.rawValue.uppercased() : "PAUSED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    if !model.isRunning {
                        let m = model.minutes(for: model.phase)
                        HStack(spacing: 10) {
                            MiniButton(name: "minus", help: "1 min less") { model.setMinutes(m - 1, for: model.phase) }
                                .disabled(m <= PomodoroModel.minuteRange.lowerBound)
                            MiniButton(name: "plus", help: "1 min more") { model.setMinutes(m + 1, for: model.phase) }
                                .disabled(m >= PomodoroModel.minuteRange.upperBound)
                        }
                        .padding(.top, 8)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.isRunning)
            }
            .frame(width: 170, height: 170)

            HStack(spacing: 22) {
                CircleIconButton(name: "arrow.counterclockwise", help: "Reset") { model.reset() }
                Button { model.toggle() } label: {
                    Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(model.phase.tint.gradient))
                        .shadow(color: model.phase.tint.opacity(0.45), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                CircleIconButton(name: "forward.end.fill", help: "Skip") { model.skip() }
            }

            HStack(spacing: 5) {
                ForEach(0..<model.cycles, id: \.self) { i in
                    Circle()
                        .fill(i < model.completedFocus % model.cycles ? Phase.focus.tint : .primary.opacity(0.15))
                        .frame(width: 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.cycles)

            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button { model.setCycles(model.cycles - 1) } label: {
                        Image(systemName: "minus").frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .disabled(model.cycles <= PomodoroModel.cycleRange.lowerBound)
                    .help("Fewer cycles")
                    Text("\(model.cycles)×")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 26)
                        .help("Cycles before long break")
                    Button { model.setCycles(model.cycles + 1) } label: {
                        Image(systemName: "plus").frame(width: 22, height: 20).contentShape(Rectangle())
                    }
                    .disabled(model.cycles >= PomodoroModel.cycleRange.upperBound)
                    .help("More cycles")
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .background(Capsule().fill(.primary.opacity(0.07)))
                Button { model.resetCompleted() } label: {
                    HStack(spacing: 3) {
                        Text("\(model.completedFocus) done")
                        if model.completedFocus > 0 {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(model.completedFocus == 0)
                .help("Reset done count")
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings")
                    .keyboardShortcut(",")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PomodoroModel
    let close: () -> Void
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: close) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 1)  // balances Back so the title stays centered
            }

            SectionCard(title: "DURATIONS") {
                ForEach(Phase.allCases) { p in
                    HStack {
                        Circle().fill(p.tint).frame(width: 7, height: 7)
                        Text(p.rawValue).font(.system(size: 12))
                        Spacer()
                        Text("\(model.minutes(for: p)) min")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: Binding(
                            get: { model.minutes(for: p) },
                            set: { model.setMinutes($0, for: p) }
                        ), in: PomodoroModel.minuteRange)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
                Divider()
                HStack {
                    Image(systemName: "repeat")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 7)
                    Text("Cycles before long break").font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(model.cycles)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { model.cycles }, set: { model.setCycles($0) }),
                            in: PomodoroModel.cycleRange)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }

            SectionCard(title: "PRESETS") {
                ForEach(model.allPresets) { preset in
                    HStack {
                        Button { model.apply(preset) } label: {
                            HStack {
                                Image(systemName: model.isActive(preset) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.isActive(preset) ? Phase.focus.tint : .secondary)
                                Text(preset.name).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text(preset.summary)
                                    .font(.system(size: 11, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { model.delete(preset) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Delete preset")
                        .opacity(model.isBuiltIn(preset) ? 0 : 1)
                        .disabled(model.isBuiltIn(preset))
                    }
                }
                HStack {
                    TextField("Preset name", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .controlSize(.small)
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || PomodoroModel.isReservedName(presetName))
                        .help(PomodoroModel.isReservedName(presetName) ? "That name is a built-in preset" : "Save current settings")
                }
            }
        }
    }

    private func save() {
        model.savePreset(named: presetName)
        presetName = ""
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
        }
    }
}

struct MiniButton: View {
    let name: String
    let help: String
    var size: CGFloat = 18
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(0.07)))
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct CircleIconButton: View {
    let name: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PanelView: View {
    @ObservedObject var model: PomodoroModel
    @State private var showingSettings = false

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(model: model) { showingSettings = false }
            } else {
                TimerView(model: model) { showingSettings = true }
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

@main
struct PomodoroApp: App {
    @StateObject private var model = PomodoroModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            if model.isRunning || model.remaining < model.total {
                Text(model.timeString).monospacedDigit()
            } else {
                Image(systemName: "timer")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
