import AppKit
import Foundation

struct AvailableUpdate: Identifiable {
    var id: String { tagName }

    let version: String
    let tagName: String
    let assetName: String
    let downloadURL: URL
}

enum UpdateError: LocalizedError {
    case notRunningFromAppBundle
    case runningFromDiskImage
    case installLocationNotWritable
    case missingDMGAsset
    case missingMountedApp
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            return "Updates are available after SolarLight is installed as an app."
        case .runningFromDiskImage:
            return "Drag SolarLight to Applications before updating."
        case .installLocationNotWritable:
            return "SolarLight cannot update this install location."
        case .missingDMGAsset:
            return "The latest GitHub release does not include a DMG."
        case .missingMountedApp:
            return "The downloaded DMG did not contain SolarLight.app."
        case .processFailed(let message):
            return message
        }
    }
}

struct UpdateManager {
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/hunkim/SolarLight/releases/latest")!

    func checkForAvailableUpdate() async throws -> AvailableUpdate? {
        guard currentAppBundleURL() != nil else {
            return nil
        }

        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SolarLight", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.processFailed("GitHub returned HTTP \(httpResponse.statusCode) while checking for updates.")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError.missingDMGAsset
        }

        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard isVersion(latestVersion, newerThan: currentVersion()) else {
            return nil
        }

        return AvailableUpdate(
            version: latestVersion,
            tagName: release.tagName,
            assetName: asset.name,
            downloadURL: asset.browserDownloadURL
        )
    }

    func install(_ update: AvailableUpdate) async throws {
        guard let currentAppURL = currentAppBundleURL() else {
            throw UpdateError.notRunningFromAppBundle
        }
        guard !currentAppURL.path.hasPrefix("/Volumes/") else {
            throw UpdateError.runningFromDiskImage
        }
        guard FileManager.default.isWritableFile(atPath: currentAppURL.deletingLastPathComponent().path) else {
            throw UpdateError.installLocationNotWritable
        }

        let dmgURL = try await download(update)
        let mountPoint = try mount(dmgURL)
        let mountedAppURL = try findMountedApp(in: mountPoint, matching: currentAppURL.lastPathComponent)
        try launchInstaller(currentAppURL: currentAppURL, mountedAppURL: mountedAppURL, mountPoint: mountPoint)
    }

    private func currentAppBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension == "app" else {
            return nil
        }
        return bundleURL
    }

    private func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func download(_ update: AvailableUpdate) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: update.downloadURL)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.processFailed("GitHub returned HTTP \(httpResponse.statusCode) while downloading \(update.assetName).")
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "SolarLight-\(update.version)-\(UUID().uuidString).dmg")
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func mount(_ dmgURL: URL) throws -> URL {
        let data = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        )
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard
            let dictionary = plist as? [String: Any],
            let entities = dictionary["system-entities"] as? [[String: Any]],
            let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError.processFailed("Could not mount the downloaded DMG.")
        }

        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    private func findMountedApp(in mountPoint: URL, matching appName: String) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        guard let appURL = contents.first(where: { $0.lastPathComponent == appName && $0.pathExtension == "app" }) else {
            throw UpdateError.missingMountedApp
        }

        return appURL
    }

    private func launchInstaller(currentAppURL: URL, mountedAppURL: URL, mountPoint: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appending(path: "solarlight-update-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        set -e

        APP_PATH=\(shellQuoted(currentAppURL.path))
        NEW_APP=\(shellQuoted(mountedAppURL.path))
        MOUNT_POINT=\(shellQuoted(mountPoint.path))
        APP_PID=\(getpid())

        while kill -0 "$APP_PID" 2>/dev/null; do
          sleep 0.2
        done

        rm -rf "$APP_PATH"
        /usr/bin/ditto "$NEW_APP" "$APP_PATH"
        /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
        /usr/bin/open "$APP_PATH"
        rm -f "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()

        Task { @MainActor in
            NSApp.terminate(nil)
        }
    }

    private func runProcess(executableURL: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "\(executableURL.lastPathComponent) failed."
            throw UpdateError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue {
                return leftValue > rightValue
            }
        }

        return false
    }

    private func versionComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}
