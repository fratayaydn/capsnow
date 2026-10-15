// CapsNow.app: settings window for the capsnowd helper.
// Runs only while the window is open. The helper is not a background process either: launchd runs it at login and
// when a keyboard appears, it sets the Caps Lock delay to 0 and quits.
import IOKit.hidsystem
import ServiceManagement
import SwiftUI

let agentPlistName = "io.github.fratayaydn.capsnow.agent.plist"
let agentJob = "gui/\(getuid())/io.github.fratayaydn.capsnow.agent"
let capsLockDelayKey = "CapsLockDelayOverride" as CFString
let registeredBuildKey = "RegisteredBuildID"
let currentBuildID = Bundle.main.object(forInfoDictionaryKey: "CNBuildID") as? String ?? ""

/// The Caps Lock delay override in the HID event system, in milliseconds; nil means none (macOS's own delay).
func capsLockDelay() -> Int? {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    guard let ms = IOHIDEventSystemClientCopyProperty(client, capsLockDelayKey) as? Int, ms >= 0 else { return nil }
    return ms
}

/// Removes the override, so macOS uses its own Caps Lock delay again (see capsnowd --off).
func restoreDefaultDelay() {
    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "capsnowd") else { return }
    let process = Process()
    process.executableURL = helper
    process.arguments = ["--off"]
    try? process.run()
    process.waitUntilExit()
}

final class Model: ObservableObject {
    @Published var agentStatus = SMAppService.Status.notRegistered
    @Published var delay: Int?

    private let defaults = UserDefaults.standard
    private let agent = SMAppService.agent(plistName: agentPlistName)

    init() {
        reregisterAfterUpdate()
        readState()
    }

    func readState() {
        agentStatus = agent.status
        delay = capsLockDelay()
    }

    var isEnabled: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setEnabled(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            NSLog("CapsNow: could not \(on ? "register" : "unregister") the helper: \(error)")
        }
        if on {
            startAgentOnce()
        } else {
            restoreDefaultDelay()
        }
        readState()
        // The helper needs a moment to run; show its result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.readState() }
    }

    /// launchd only starts the helper build that was registered when the app is signed locally (its code signature
    /// is part of the launch constraint), so after an update it is registered again, if it was enabled.
    private func reregisterAfterUpdate() {
        guard defaults.string(forKey: registeredBuildKey) != currentBuildID else { return }
        defaults.set(currentBuildID, forKey: registeredBuildKey)
        guard agent.status == .enabled else { return }
        DispatchQueue.global().async { [weak self] in
            reregisterAgent()
            DispatchQueue.main.async { self?.readState() }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        Form {
            Section {
                // Two texts in a Form row label: macOS shows the second one as the row's grey description.
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                    Text("Enable CapsNow")
                    Text("Caps Lock turns on the moment you press it, even with a quick tap. macOS normally ignores very short presses.")
                }
                statusRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.readState()
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch model.agentStatus {
        case .enabled where model.delay == 0:
            StatusRow(symbol: "checkmark.circle.fill", color: .green, title: "Caps Lock Has No Delay",
                      detail: "On every keyboard, including ones you connect later. Nothing runs in the background: CapsNow applies the setting at login and when a keyboard appears, then quits.")
        case .enabled:
            StatusRow(symbol: "clock.fill", color: .secondary, title: "Starting\u{2026}",
                      detail: "CapsNow is applying the setting.")
        case .requiresApproval:
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                      title: "Approval Required",
                      detail: "Allow CapsNow under \u{201C}Allow in the Background\u{201D} so it can apply the setting at login.",
                      action: ("Open Login Items\u{2026}", { SMAppService.openSystemSettingsLoginItems() }))
        default:
            StatusRow(symbol: "circle", color: .secondary, title: "CapsNow Is Off",
                      detail: "macOS ignores very short Caps Lock presses, as usual.")
        }
    }
}

/// A status line in the style of System Settings: symbol, title, explanation and an optional button.
struct StatusRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.label, action: action.run).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

@discardableResult
func launchctl(_ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Runs the helper once through launchd. After an update this also makes launchd accept the new build
/// (see scripts/install.sh).
func startAgentOnce() { launchctl(["kickstart", agentJob]) }

/// Unregister, wait until launchd has dropped the job, register and run once: the sequence that refreshes the
/// helper's launch constraint after an update (see scripts/install.sh).
func reregisterAgent() {
    let agent = SMAppService.agent(plistName: agentPlistName)
    try? agent.unregister()
    for _ in 0..<70 where !launchctl(["print", agentJob]).isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    Thread.sleep(forTimeInterval: 1)
    try? agent.register()
    startAgentOnce()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `CapsNow --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? SMAppService.agent(plistName: agentPlistName).unregister()
            restoreDefaultDelay()
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            do {
                try SMAppService.agent(plistName: agentPlistName).register()
                startAgentOnce()
                // This build is registered now; the window must not re-register it again (see reregisterAfterUpdate).
                UserDefaults.standard.set(currentBuildID, forKey: registeredBuildKey)
                UserDefaults.standard.synchronize()  // exit() would otherwise drop the unsaved value
                exit(0)
            } catch {
                FileHandle.standardError.write("CapsNow: could not register the helper: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CapsNowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("CapsNow", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
