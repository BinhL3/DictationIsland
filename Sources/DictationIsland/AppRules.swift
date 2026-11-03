import AppKit

/// Which apps the dictation keys work in. Apps with dictation of their own (Lark, Feishu) are off
/// unless the user turns them on, so their own dictation can have the key; any other app can be
/// turned off in Settings. The key listener only listens, so in an app that's off the key still
/// reaches the app; we just don't start.
@MainActor
enum AppRules {
    /// Apps with built-in voice input, matched by name since their bundle IDs vary by region.
    nonisolated static let ownDictationNames: Set<String> = ["lark", "feishu", "飞书"]

    nonisolated static func hasOwnDictation(name: String?, bundleID: String?) -> Bool {
        if let name, ownDictationNames.contains(name.lowercased()) { return true }
        let id = bundleID?.lowercased() ?? ""
        return id.contains("larksuite") || id.contains("feishu")
    }

    static func isOn(bundleID: String, name: String?) -> Bool {
        if let rule = AppSettings.shared.appRules[bundleID] { return rule }
        return !hasOwnDictation(name: name, bundleID: bundleID)
    }

    /// Whether a dictation key pressed now should start dictating.
    static var isOnInFrontmostApp: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return true }
        return isOn(bundleID: id, name: app.localizedName)
    }

    /// An app as the Settings list shows it.
    struct Listed: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let url: URL?
        let hasOwnDictation: Bool
        var id: String { bundleID }

        var icon: NSImage {
            if let url { return NSWorkspace.shared.icon(forFile: url.path) }
            return NSWorkspace.shared.icon(for: .application)
        }

        init(bundleID: String, url: URL?) {
            self.bundleID = bundleID
            self.url = url
            let bundle = url.flatMap(Bundle.init(url:))
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url?.deletingPathExtension().lastPathComponent
                ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            self.name = name
            hasOwnDictation = AppRules.hasOwnDictation(name: name, bundleID: bundleID)
        }
    }

    /// Apps with a rule, plus installed apps that have their own dictation.
    static func listed() -> [Listed] {
        var ids = Set(AppSettings.shared.appRules.keys)
        for url in installedApps() {
            let name = url.deletingPathExtension().lastPathComponent
            if let id = Bundle(url: url)?.bundleIdentifier, hasOwnDictation(name: name, bundleID: id) { ids.insert(id) }
        }
        return ids.map { Listed(bundleID: $0, url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Running apps with a Dock icon that aren't listed yet, for the Add menu.
    static func addable(excluding listed: [Listed]) -> [Listed] {
        let taken = Set(listed.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> Listed? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      !taken.contains(id), seen.insert(id).inserted else { return nil }
                return Listed(bundleID: id, url: app.bundleURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func installedApps() -> [URL] {
        let folders = [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }
}
