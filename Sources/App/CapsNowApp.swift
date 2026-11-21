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
let reregistrationPendingKey = "ReregistrationPending"
let currentBuildID = Bundle.main.object(forInfoDictionaryKey: "CNBuildID") as? String ?? ""

enum ReregistrationAction {
    case none, storeBuildID, runSequence

    static func decide(storedBuildID: String?, currentBuildID: String, pending: Bool,
                       enabled: Bool) -> ReregistrationAction {
        if pending { return .runSequence }
        guard storedBuildID != currentBuildID else { return .none }
        return enabled ? .runSequence : .storeBuildID
    }
}

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
    @Published var errorMessage: String?
    @Published var availableVersion: String?
    @Published var updateMessage: String?
    @Published var updateInProgress = false

    let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private let defaults = UserDefaults.standard
    private let agent = SMAppService.agent(plistName: agentPlistName)

    init() {
        reregisterAfterUpdate()
        readState()
        readUpdateState()
    }

    private func readUpdateState() {
        let domain = "io.github.fratayaydn.capsnow" as CFString
        CFPreferencesAppSynchronize(domain)
        availableVersion = availableUpdate(stored: CFPreferencesCopyAppValue("LatestVersion" as CFString, domain),
                                           running: runningVersion)
    }

    func runUpdate(install: Bool) {
        guard !updateInProgress else { return }
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "capsnow-update") else {
            updateMessage = "The update tool is missing."
            return
        }
        updateInProgress = true
        updateMessage = install ? "Downloading and installing update..." : "Checking for updates..."
        let bundle = Bundle.main.bundleURL
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = tool
            process.arguments = [install ? "--install" : "--check"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let success: Bool
            do {
                try process.run()
                process.waitUntilExit()
                success = process.terminationReason == .exit && process.terminationStatus == 0
            } catch {
                success = false
            }
            DispatchQueue.main.async {
                guard success else {
                    self.updateInProgress = false
                    self.updateMessage = install ? "Could not install the update. Try again." : "Could not check for updates. Try again."
                    return
                }
                if install {
                    self.updateMessage = "Relaunching CapsNow..."
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
                        DispatchQueue.main.async {
                            if error == nil {
                                NSApplication.shared.terminate(nil)
                            } else {
                                self.updateInProgress = false
                                self.updateMessage = "Updated. Close and reopen CapsNow."
                            }
                        }
                    }
                } else {
                    self.readUpdateState()
                    self.updateMessage = self.availableVersion == nil ? "CapsNow is up to date" : nil
                    self.updateInProgress = false
                }
            }
        }
    }

    func readState() {
        agentStatus = agent.status
        delay = capsLockDelay()
    }

    var isEnabled: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setEnabled(_ on: Bool) {
        defaults.removeObject(forKey: reregistrationPendingKey)
        defaults.synchronize()
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            errorMessage = "Could not \(on ? "enable" : "disable") CapsNow: \(error.localizedDescription)"
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
        switch ReregistrationAction.decide(storedBuildID: defaults.string(forKey: registeredBuildKey),
                                          currentBuildID: currentBuildID,
                                          pending: defaults.bool(forKey: reregistrationPendingKey),
                                          enabled: agent.status == .enabled) {
        case .none: return
        case .storeBuildID:
            defaults.set(currentBuildID, forKey: registeredBuildKey)
            return
        case .runSequence: break
        }
        defaults.set(true, forKey: reregistrationPendingKey)
        defaults.synchronize()
        DispatchQueue.global().async { [weak self] in
            let success = reregisterAgent()
            if success {
                let defaults = UserDefaults.standard
                defaults.set(currentBuildID, forKey: registeredBuildKey)
                defaults.removeObject(forKey: reregistrationPendingKey)
                defaults.synchronize()
            }
            DispatchQueue.main.async {
                if !success {
                    self?.errorMessage = "Could not enable CapsNow after the update. Close and reopen CapsNow to try again."
                }
                self?.readState()
            }
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
            Section("Updates") {
                HStack {
                    Text("Version \(model.runningVersion)")
                    Spacer()
                    Button("Check for Updates") { model.runUpdate(install: false) }
                }
                if model.updateMessage != nil || model.availableVersion != nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            if let version = model.availableVersion {
                                Text("Version \(version) is available")
                            }
                            if let message = model.updateMessage {
                                Text(message).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if model.availableVersion != nil {
                            Button("Update") { model.runUpdate(install: true) }
                        }
                    }
                }
            }
            .disabled(model.updateInProgress)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .alert("CapsNow", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
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
func reregisterAgent() -> Bool {
    let agent = SMAppService.agent(plistName: agentPlistName)
    try? agent.unregister()
    for _ in 0..<70 {
        if launchctl(["print", agentJob]).isEmpty { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    Thread.sleep(forTimeInterval: 1)
    try? agent.register()
    let success = agent.status == .enabled || agent.status == .requiresApproval
    startAgentOnce()
    return success
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
                UserDefaults.standard.removeObject(forKey: reregistrationPendingKey)
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
