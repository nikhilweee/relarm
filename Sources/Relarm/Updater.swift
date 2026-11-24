import AppKit
import RelarmCore

// Checks GitHub Releases and swaps in the new Relarm.zip. Sparkle would need an
// appcast, signing keys and an embedded framework, which an ad-hoc signed SPM
// build has no place for. Lives as long as the app, so closures hold it strongly.
final class Updater {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        var version: String { AppVersion.components(tagName).map(String.init).joined(separator: ".") }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/nikhilweee/relarm/releases/latest")!
    private static let assetName = "Relarm.zip"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var pollTimer: Timer?
    private var isBusy = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // Polls hourly against a daily due date, so a Mac that slept past it checks soon after waking.
    func startAutomaticChecks() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        // Give launch a moment so a prompt doesn't race the first window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Prefs.checksForUpdates,
              Date().timeIntervalSince(Prefs.lastUpdateCheck ?? .distantPast) >= Self.checkInterval else { return }
        check(userInitiated: false)
    }

    @objc func checkForUpdates() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                self.isBusy = false
                guard let release else {
                    // Automatic checks fail quietly and retry on the next poll.
                    if userInitiated {
                        self.showMessage("Couldn't check for updates",
                                         error?.localizedDescription ?? "GitHub didn't return a release.")
                    }
                    return
                }
                Prefs.lastUpdateCheck = Date()
                self.handle(release, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        guard AppVersion.isNewer(release.version, than: currentVersion) else {
            if userInitiated {
                showMessage("You're up to date", "Relarm \(currentVersion) is the latest version.")
            }
            return
        }
        // Skipping only silences automatic checks; asking by hand still offers it.
        if !userInitiated && Prefs.skippedVersion == release.version { return }
        prompt(for: release)
    }

    private func prompt(for release: Release) {
        let alert = NSAlert()
        alert.messageText = "A new version of Relarm is available"
        alert.informativeText = "Relarm \(release.version) is available. You have \(currentVersion)."
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Remind Me Later")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Check for updates automatically"
        alert.suppressionButton?.state = Prefs.checksForUpdates ? .on : .off
        activateApp()
        let response = alert.runModal()
        Prefs.checksForUpdates = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: Prefs.skippedVersion = release.version
        default: break
        }
    }

    private func install(_ release: Release) {
        let appURL = Bundle.main.bundleURL
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
            return showInstallFailure("This release has no \(Self.assetName).", release: release)
        }
        // Gatekeeper runs a quarantined app from a read-only translocated copy.
        guard !appURL.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            return showInstallFailure("Move Relarm to your Applications folder, then try again.", release: release)
        }
        isBusy = true
        URLSession.shared.downloadTask(with: asset.browserDownloadURL) { location, response, error in
            // The download is deleted when this handler returns, so unpack it here.
            let result = Result {
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw error ?? UpdateError("The download failed.")
                }
                return try Self.unpack(location, expecting: release.version, replacing: appURL)
            }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let newApp):
                    self.replaceAndRelaunch(appURL, with: newApp, release: release)
                case .failure(let error):
                    self.showInstallFailure(error.localizedDescription, release: release)
                }
            }
        }.resume()
    }

    // Unpacks next to the installed app so the final swap stays on one volume.
    private static func unpack(_ zip: URL, expecting version: String, replacing appURL: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: appURL, create: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        let newApp = folder.appendingPathComponent("Relarm.app")
        guard ditto.terminationStatus == 0, let info = Bundle(url: newApp)?.infoDictionary else {
            throw UpdateError("The downloaded update couldn't be opened.")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The downloaded update doesn't match Relarm \(version).")
        }
        return newApp
    }

    private func replaceAndRelaunch(_ appURL: URL, with newApp: URL, release: Release) {
        do {
            // Replacing a running bundle is safe: the old binary stays mapped until exit.
            _ = try FileManager.default.replaceItemAt(appURL, withItemAt: newApp)
        } catch {
            return showInstallFailure(error.localizedDescription, release: release)
        }
        // Waits for this process to exit, or `open` would just focus the old copy.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              appURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private func showInstallFailure(_ reason: String, release: Release) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the update"
        alert.informativeText = reason
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        activateApp()
        alert.runModal()
    }
}
