import AppKit
import Security

/// Installs a release in place, no package needed: download the DMG, check the app inside is
/// signed with this app's own certificate, swap it into this app's spot and relaunch.
///
/// Same certificate means macOS keeps the permission grants. And a file this app downloads
/// itself isn't quarantined (no `LSFileQuarantineEnabled`), so there's no "Open Anyway" either.
/// Anything unexpected throws, and the caller falls back to opening the DMG in the browser.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case download
        case mount
        case noApp
        case signature
        case notNewer
        case copy

        var errorDescription: String? {
            switch self {
            case .download: return "The download didn't finish."
            case .mount: return "The downloaded disk image couldn't be opened."
            case .noApp: return "The disk image doesn't contain DictationIsland."
            case .signature: return "The new version isn't signed like this one, so it wasn't installed."
            case .notNewer: return "The download isn't newer than this version."
            case .copy: return "The new version couldn't be copied into place."
            }
        }
    }

    /// False when the app can't replace itself: running from the disk image, from a translocated
    /// (quarantined) copy, or from a folder the user can't write to.
    static var canInstallInPlace: Bool {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        guard !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") else { return false }
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: path)
            && designatedRequirement() != nil
    }

    /// Downloads, verifies and swaps in the new version. `installing` is called once the download
    /// is done. On return the new app is in place; call `relaunch()`.
    static func install(
        from dmg: URL,
        version: String,
        progress: @escaping @Sendable (Double) -> Void,
        installing: @escaping @Sendable () -> Void
    ) async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "DictationIsland-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let image = try await Downloader.download(dmg, to: work.appending(path: "update.dmg"), progress: progress)
        installing()

        let mount = work.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path]) else {
            throw Failure.mount
        }
        var failure: Error?
        do {
            try await swapIn(mount.appending(path: "DictationIsland.app"))
        } catch {
            failure = error
        }
        _ = await run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
        if let failure { throw failure }
    }

    /// Checks the mounted app and puts a copy of it where this app is.
    private static func swapIn(_ fresh: URL) async throws {
        guard FileManager.default.fileExists(atPath: fresh.path) else { throw Failure.noApp }
        guard isSignedLikeThisApp(fresh) else { throw Failure.signature }
        let freshVersion = Bundle(url: fresh)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard UpdateChecker.isNewer(freshVersion, than: UpdateChecker.currentVersion) else { throw Failure.notNewer }

        // Staged next to the app so the final swap is a rename on the same volume.
        let bundle = Bundle.main.bundleURL
        let staged = bundle.deletingLastPathComponent().appending(path: ".DictationIsland-\(freshVersion)-update.app")
        try? FileManager.default.removeItem(at: staged)
        guard await run("/usr/bin/ditto", [fresh.path, staged.path]) else { throw Failure.copy }
        _ = await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        guard isSignedLikeThisApp(staged) else {
            try? FileManager.default.removeItem(at: staged)
            throw Failure.signature
        }
        do {
            _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw Failure.copy
        }
    }

    /// Quits, and opens the app again (now the new version) once this process has exited.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let relauncher = Process()
        relauncher.executableURL = URL(filePath: "/bin/sh")
        relauncher.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? relauncher.run()
        NSApp.terminate(nil)
    }

    // MARK: - Signature

    /// This app's designated requirement: its bundle ID and signing certificate. Nil for an
    /// ad-hoc signed build, whose requirement is its own hash and no update could ever meet.
    private static func designatedRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement
        else { return nil }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        if let text = text as String?, text.hasPrefix("cdhash") { return nil }
        return requirement
    }

    /// The whole bundle is intact and signed with this app's identifier and certificate.
    static func isSignedLikeThisApp(_ app: URL) -> Bool {
        guard let requirement = designatedRequirement() else { return false }
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }

    // MARK: - Helpers

    private static func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    /// A download task with progress, moved to `destination` when it completes.
    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Double) -> Void
        private var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()

        private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            let downloader = Downloader(destination: destination, progress: progress)
            let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                session.downloadTask(with: request).resume()
            }
        }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                finish(.failure(Failure.download))
                return
            }
            // The temporary file is deleted when this returns, so move it now.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success(destination))
            } catch {
                finish(.failure(Failure.download))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil { finish(.failure(Failure.download)) }
        }
    }
}
