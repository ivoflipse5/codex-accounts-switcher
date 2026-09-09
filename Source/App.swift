import AppKit
import SwiftUI
import Combine

@MainActor final class AccountModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var active: Identity?
    @Published var usage: Usage?
    @Published var accountUsage: [String: Usage] = [:]
    @Published var usageErrors: [String: String] = [:]
    @Published var message = "Save your current account, then add your second account."
    @Published var busy = false
    @Published var loginCode: String?
    @Published var recoveryPending = false
    @Published var signingIn = false
    @Published var vaultReady = false
    private let vault = KeychainVault()
    private var state = VaultData()
    private let auth = AuthFile(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    private var loginProcess: Process?
    private var loginHome: URL?
    private var loginBuffer = Data()
    private var loginTimer: Timer?
    private var snapshotTimer: Timer?
    private var demo: Bool
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") }
    var cliURL: URL? { appURL?.appendingPathComponent("Contents/Resources/codex") }

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            func fixture(_ id: String, _ email: String) -> Data {
                let payload = try! JSONSerialization.data(withJSONObject: ["sub": id, "email": email, "https://api.openai.com/auth": ["chatgpt_account_id": id]])
                let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["id_token": "demo." + encoded + ".demo", "access_token": "demo-only", "refresh_token": "demo-only", "account_id": id]])
            }
            let first = fixture("demo-one", "primary@example.com")
            let second = fixture("demo-two", "second@example.com")
            let firstID = try! Identity.parse(first).key
            let secondID = try! Identity.parse(second).key
            active = try? Identity.parse(first)
            profiles = [Profile(id: firstID, label: "Primary", auth: first, savedAt: Date()), Profile(id: secondID, label: "Second account", auth: second, savedAt: Date())]
            accountUsage = [
                firstID: Usage(windows: [UsageWindow(id: "weekly", title: "Weekly", remaining: 24, resets: nil)], fetchedAt: Date()),
                secondID: Usage(windows: [UsageWindow(id: "weekly", title: "Weekly", remaining: 92, resets: nil)], fetchedAt: Date())
            ]
            message = "Demo mode · fictional accounts and usage."
            return
        }
        do {
            state = try vault.load()
            vaultReady = true
            profiles = state.profiles
            recoveryPending = state.recovery != nil
            active = try? Identity.parse(auth.read())
            if recoveryPending { message = "A previous switch was interrupted. Restore the previous login before switching again." }
            else if !profiles.isEmpty { message = "Ready. Finish active Codex tasks before switching." }
        } catch { message = error.localizedDescription }
        // Capture refreshed credentials only for a profile the user has already saved.
        // No token renewal or network polling is performed by this timer.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncCurrent() }
        }
    }
    func syncCurrent() {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        do {
            let bytes = try auth.read()
            let identity = try Identity.parse(bytes)
            if active?.key != identity.key { usage = nil }
            active = identity
            if let i = state.profiles.firstIndex(where: { $0.id == identity.key }), state.profiles[i].auth != bytes {
                var next = state
                next.profiles[i].auth = bytes
                next.profiles[i].savedAt = Date()
                try vault.save(next)
                state = next; profiles = next.profiles
            }
        } catch { message = "Cannot read or save the current login. " + error.localizedDescription }
    }
    private func save(_ bytes: Data, label: String? = nil) throws {
        guard vaultReady else { throw AppFailure("Keychain is unavailable. Reopen Codex Accounts after unlocking Keychain.") }
        let identity = try Identity.parse(bytes)
        var next = state
        if let index = next.profiles.firstIndex(where: { $0.id == identity.key }) {
            next.profiles[index].auth = bytes
            next.profiles[index].savedAt = Date()
            if let label { next.profiles[index].label = label }
        } else {
            guard next.profiles.count < 2 else { throw AppFailure("Two accounts are already saved. Remove one before adding another.") }
            next.profiles.append(Profile(id: identity.key, label: label ?? "Second account", auth: bytes, savedAt: Date()))
        }
        try vault.save(next)
        state = next; profiles = next.profiles
    }
    func saveCurrent() {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        do {
            try auth.preflight()
            let bytes = try auth.read()
            let identity = try Identity.parse(bytes)
            try save(bytes, label: state.profiles.first(where: { $0.id == identity.key })?.label ?? "Primary")
            active = identity
            message = "Current account saved in Keychain."
        } catch { message = error.localizedDescription }
    }
    func refreshUsage() {
        guard !demo, vaultReady, !busy else { return }
        syncCurrent()
        let saved = profiles
        busy = true
        Task {
            defer { busy = false }
            var failed = false
            for profile in saved {
                do {
                    let identity = try Identity.parse(profile.auth)
                    accountUsage[profile.id] = try await fetchUsage(identity)
                    usageErrors[profile.id] = nil
                } catch {
                    accountUsage[profile.id] = nil
                    usageErrors[profile.id] = "Usage unavailable"
                    failed = true
                }
            }
            message = failed ? "Some usage could not be checked. Sign in again to refresh that account." : "Usage checked for both accounts."
        }
    }

    func addAccount() {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        guard let cli = cliURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            message = "Install the official Codex app first."; return
        }
        do {
            // Preserve a valid current login before initiating a separate sign-in.
            if let bytes = try? auth.read() { try save(bytes, label: active.flatMap { a in state.profiles.first(where: { $0.id == a.key })?.label } ?? "Primary") }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Accounts", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let home = base.appendingPathComponent("login-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            loginHome = home
            loginBuffer = Data()
            loginCode = nil
            let p = Process()
            p.executableURL = cli
            p.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login", "--device-auth"]
            // Do not pass API keys, proxies, alternate endpoints or the active CODEX_HOME.
            p.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": home.path, "TERM": "dumb", "NO_COLOR": "1"]
            p.currentDirectoryURL = home
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor in self?.readLoginOutput(bytes) }
            }
            p.terminationHandler = { [weak self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in self?.finishLogin(status: process.terminationStatus) }
            }
            loginProcess = p
            signingIn = true
            busy = true
            message = "Starting official Codex sign-in…"
            try p.run()
            loginTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.cancelLogin() }
            }
        } catch {
            busy = false; signingIn = false; loginProcess = nil; cleanLoginHome(); message = error.localizedDescription
        }
    }
    private func readLoginOutput(_ bytes: Data) {
        guard loginProcess != nil else { return }
        if loginBuffer.count < 32_768 { loginBuffer.append(bytes) }
        let output = String(decoding: loginBuffer, as: UTF8.self)
        // Only expose a device code. Never display raw CLI output or tokens.
        if let code = deviceLoginCode(from: output) {
            loginCode = code
            message = "Open OpenAI sign-in, enter this code, and select your second account."
        }
    }
    private func finishLogin(status: Int32) {
        loginTimer?.invalidate(); loginTimer = nil
        defer { busy = false; signingIn = false; loginProcess = nil; loginCode = nil; loginBuffer = Data(); cleanLoginHome() }
        guard status == 0, let home = loginHome else { message = "Sign-in stopped or failed. Your current Codex login was not changed."; return }
        do {
            let bytes = try AuthFile(home: home).read()
            let identity = try Identity.parse(bytes)
            try save(bytes)
            if identity.key == active?.key {
                message = "You signed in to the current account. Add the other account to save a second login."
            } else { message = "Second account saved. Select Switch when you are ready." }
        } catch { message = error.localizedDescription }
    }
    private func cleanLoginHome() {
        guard let home = loginHome else { return }
        try? FileManager.default.removeItem(at: home)
        loginHome = nil
    }
    func cancelLogin() {
        loginTimer?.invalidate()
        if let p = loginProcess, p.isRunning { p.terminate() }
    }
    func openLogin() {
        guard loginCode != nil else { return }
        NSWorkspace.shared.open(URL(string: "https://auth.openai.com/codex/device")!)
    }
    func copyCode() {
        guard let code = loginCode else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
    }
    func rename(_ profile: Profile) {
        guard !demo, vaultReady, !busy else { return }
        let alert = NSAlert(); alert.messageText = "Name this account"
        let field = NSTextField(string: profile.label); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !label.isEmpty else { return }
        do { try save(profile.auth, label: label) } catch { message = error.localizedDescription }
    }
    func remove(_ profile: Profile) {
        guard !demo, vaultReady, !busy, !recoveryPending else { return }
        let alert = NSAlert(); alert.messageText = "Remove \(profile.label)?"
        alert.informativeText = "This removes the saved login from this app. It does not sign you out of Codex."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var next = state; next.profiles.removeAll { $0.id == profile.id }
            try vault.save(next); state = next; profiles = next.profiles; message = "Saved account removed."
        } catch { message = error.localizedDescription }
    }
    private func codexProcesses() throws -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AppFailure("Cannot check for running Codex processes.") }
        return String(decoding: output, as: UTF8.self).components(separatedBy: .newlines).contains {
            let name = URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)).lastPathComponent
            return name == "codex" || name == "codex-cli"
        }
    }
    private func stopCodex() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        for app in running { _ = app.terminate() }
        for _ in 0..<120 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty, try !codexProcesses() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AppFailure("Codex did not fully stop. Close its quit dialog and any Codex CLI or IDE sessions, then try again. No login was replaced.")
    }
    func openCodex() async throws {
        guard let url = appURL else { throw AppFailure("The official Codex app was not found.") }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
    func switchTo(_ profile: Profile) {
        guard !demo, vaultReady, !busy, !recoveryPending, profile.id != active?.key else { return }
        let alert = NSAlert(); alert.messageText = "Switch to \(profile.label)?"
        alert.informativeText = "Finish or stop all Codex tasks first, including scheduled work. This closes and reopens Codex. Local chats stay on this Mac; continuing one sends its context under the selected account. Cloud chats and connected services may differ."
        alert.addButton(withTitle: "Switch and reopen"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            var didReplace = false
            var before: Data?
            do {
                try auth.preflight()
                let target = try Identity.parse(profile.auth)
                message = "Checking the saved login with OpenAI…"
                var targetUsage: Usage?
                // Codex owns token renewal. An expired access token does not mean the
                // saved refresh token is invalid; let the official app renew it on launch.
                do { targetUsage = try await fetchUsage(target) }
                catch is LoginNeedsRenewal { targetUsage = nil }
                message = "Waiting for Codex to close…"
                try await stopCodex()
                try auth.preflight()
                let original = try auth.read(); before = original
                try save(original)
                // A durable Keychain journal survives a crash between file replacement and launch.
                var next = state
                next.recovery = Recovery(original: original, targetKey: profile.id, startedAt: Date())
                try vault.save(next); state = next; recoveryPending = true
                try auth.replace(with: profile.auth, expected: original); didReplace = true
                guard try Identity.parse(auth.read()).key == profile.id else { throw AppFailure("Login verification failed.") }
                try await openCodex()
                next = state; next.recovery = nil
                try vault.save(next); state = next; recoveryPending = false
                active = target; usage = targetUsage
                message = targetUsage == nil ? "\(profile.label) is selected. Codex will try to renew the saved login. Check the account shown there." : "\(profile.label) is selected. Check the account shown in Codex."
            } catch {
                if didReplace {
                    // Do not overwrite files if the relaunched app might have refreshed them.
                    message = "Switch interrupted. Use Restore previous login after closing Codex. " + error.localizedDescription
                } else {
                    if before != nil {
                        var next = state; next.recovery = nil
                        do { try vault.save(next); state = next; recoveryPending = false }
                        catch { recoveryPending = true }
                    }
                    message = error.localizedDescription
                }
            }
            busy = false
        }
    }
    func restore() {
        guard !demo, vaultReady, !busy, let recovery = state.recovery else { return }
        let alert = NSAlert(); alert.messageText = "Restore the previous login?"
        alert.informativeText = "Finish all Codex tasks first. Codex must close before its previous login can be restored."
        alert.addButton(withTitle: "Restore and reopen"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await stopCodex()
                let current = try auth.read()
                let identity = try Identity.parse(current)
                let old = try Identity.parse(recovery.original)
                guard identity.key == recovery.targetKey || identity.key == old.key else { throw AppFailure("Another account is now active. Recovery will not overwrite it.") }
                // Keep the latest token if the original account is already active.
                if identity.key != old.key {
                    try save(current)
                    try auth.replace(with: recovery.original, expected: current)
                }
                try await openCodex()
                var next = state; next.recovery = nil
                try vault.save(next); state = next; recoveryPending = false
                active = try Identity.parse(auth.read()); usage = nil
                message = "Previous login restored. If it expired, sign in again in Codex."
            } catch { message = error.localizedDescription }
        }
    }
}

struct AccountPanel: View {
    @ObservedObject var model: AccountModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "person.2.circle.fill").font(.system(size: 30)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Accounts Switcher").font(.system(size: 17, weight: .semibold))
                    Text("By Eric · Two accounts. One workspace.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            Divider()
            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Start with your current account").font(.headline)
                    Text(model.active?.email ?? "Sign in to the official Codex app first.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Save current account") { model.saveCurrent() }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.busy || model.active == nil || !model.vaultReady)
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(model.profiles) { profile in
                        HStack(spacing: 12) {
                            Image(systemName: profile.id == model.active?.key ? "checkmark.circle.fill" : "person.crop.circle")
                                .font(.system(size: 23)).foregroundStyle(profile.id == model.active?.key ? Color.teal : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.label).font(.system(size: 14, weight: .semibold))
                                Text((try? Identity.parse(profile.auth).email) ?? "Preview account").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            VStack(alignment: .trailing, spacing: 4) {
                                if let usage = model.accountUsage[profile.id] {
                                    ForEach(usage.windows) { window in
                                        Text("\(window.title) · \(window.remaining)% left")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(window.remaining < 15 ? Color.orange : Color.teal)
                                            .help(window.resets.map { "Resets " + $0.formatted() } ?? "")
                                    }
                                } else {
                                    Text(model.usageErrors[profile.id] ?? "Usage not checked").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if profile.id == model.active?.key { Text("Active").font(.system(size: 11, weight: .medium)).foregroundStyle(.teal) }
                            else { Button("Switch") { model.switchTo(profile) }.disabled(model.busy || model.recoveryPending || !model.vaultReady) }
                            Menu {
                                Button("Rename") { model.rename(profile) }
                                Button("Remove saved login") { model.remove(profile) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy || model.recoveryPending || !model.vaultReady)
                        }
                    }
                }
                if model.profiles.count < 2 {
                    Button { model.addAccount() } label: { Label("Add second account", systemImage: "plus") }.disabled(model.busy || model.recoveryPending || !model.vaultReady)
                } else {
                    Button("Sign in again to an account") { model.addAccount() }.font(.system(size: 11)).disabled(model.busy || model.recoveryPending || !model.vaultReady)
                }
            }
            if let code = model.loginCode {
                VStack(alignment: .leading, spacing: 10) {
                    Text(code).font(.system(size: 25, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copy code") { model.copyCode() }
                        Button("Open OpenAI sign-in") { model.openLogin() }.buttonStyle(.borderedProminent)
                    }

                }
            }
            if model.signingIn { Button("Cancel sign-in") { model.cancelLogin() }.font(.caption) }
            Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.recoveryPending { Button("Restore previous login") { model.restore() }.disabled(model.busy) }
            Divider()
            HStack {
                Button("Check usage") { model.refreshUsage() }.disabled(model.busy || model.active == nil || !model.vaultReady)
                Spacer()
                Button("Open Codex") { Task { try? await model.openCodex() } }.disabled(model.busy)
                Menu {
                    Text("Saved logins: macOS Keychain")
                    Text("Manual switching · no auto-updater")
                    Divider()
                    Button("Quit Codex Accounts") { NSApp.terminate(nil) }.disabled(model.busy)
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 11))
        }
        .padding(22)
        .frame(width: 460)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var sizingSubscription: AnyCancellable?
    private var popupController: NSHostingController<AnyView>?
    private var model: AccountModel!
    private var processLock: ProcessLock?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        if !preview {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Accounts", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                processLock = try ProcessLock(at: support.appendingPathComponent("app.lock"))
            } catch {
                let alert = NSAlert(); alert.messageText = error.localizedDescription
                alert.runModal(); NSApp.terminate(nil); return
            }
        }
        model = AccountModel(demo: preview)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: "Codex Accounts")
        status.button?.toolTip = "Codex Accounts"
        status.button?.target = self; status.button?.action = #selector(toggle)
        popover = NSPopover(); popover.behavior = .transient
        popover.animates = false
        popupController = NSHostingController(rootView: AnyView(EmptyView()))
        popupController?.sizingOptions = []
        popover.contentViewController = popupController
        sizingSubscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sizePopup() }
        }
        if (preview && !CommandLine.arguments.contains("--preview-popup")) || CommandLine.arguments.contains("--show-window") || model.profiles.isEmpty {
            let controller = NSHostingController(rootView: AccountPanel(model: model))
            let win = NSWindow(contentViewController: controller)
            win.title = preview ? "Codex Accounts · Preview" : "Codex Accounts"
            win.styleMask = [.titled, .closable]; win.center(); win.makeKeyAndOrderFront(nil)
            window = win; NSApp.activate(ignoringOtherApps: true)
        }
        if preview && CommandLine.arguments.contains("--preview-popup") {
            DispatchQueue.main.async { self.toggle() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window, !flag { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else if !flag { toggle() }
        return true
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            model.syncCurrent()
            sizePopup()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    private func sizePopup() {
        guard let button = status.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let maximum = max(CGFloat(200), (screen?.visibleFrame.height ?? 800) - 40)
        let measure = NSHostingView(rootView: AccountPanel(model: model).fixedSize(horizontal: false, vertical: true))
        let height = min(maximum, ceil(measure.fittingSize.height))
        popupController?.rootView = AnyView(
            ScrollView(.vertical) {
                AccountPanel(model: model).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 460, height: height, alignment: .top)
        )
        popupController?.view.frame = NSRect(x: 0, y: 0, width: 460, height: height)
        popover.contentSize = NSSize(width: 460, height: height)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true { return .terminateCancel }
        return .terminateNow
    }
}
