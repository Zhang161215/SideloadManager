import SwiftUI
import Combine
import AppKit
import Charts
import UniformTypeIdentifiers
import Foundation
import UserNotifications

// MARK: - Models

struct ManagedApp: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ipaPath: String
    var bundleIdentifier: String?
    var iconPath: String?
    var scheduleEnabled = true
    var intervalHours = 24
    var lastRun: Date?
    var nextRun: Date?
    var signatureExpiresAt: Date?
    var signatureExpirySource: String? = nil
    var lastBackgroundRun: Date?
    var backgroundRefreshResult: String?
    var status = "等待管理"
}

struct ManagerConfig: Codable {
    var apps: [ManagedApp] = []
    var refreshIntervalHours = 24
    var signatureLifetimeDays = 7
    var refreshLeadHours = 24
    var backgroundRefreshEnabled = false
    var launchAtLoginEnabled = false
    var autoOpenOnUSBEnabled = false
    var maxRetryCount = 3
    var retryDelaySeconds = 10

    private enum CodingKeys: String, CodingKey {
        case apps, refreshIntervalHours, signatureLifetimeDays, refreshLeadHours, backgroundRefreshEnabled, launchAtLoginEnabled, autoOpenOnUSBEnabled, maxRetryCount, retryDelaySeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([ManagedApp].self, forKey: .apps) ?? []
        refreshIntervalHours = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalHours) ?? 24
        signatureLifetimeDays = try container.decodeIfPresent(Int.self, forKey: .signatureLifetimeDays) ?? 7
        refreshLeadHours = try container.decodeIfPresent(Int.self, forKey: .refreshLeadHours) ?? 24
        backgroundRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundRefreshEnabled) ?? false
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
        autoOpenOnUSBEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoOpenOnUSBEnabled) ?? false
        maxRetryCount = try container.decodeIfPresent(Int.self, forKey: .maxRetryCount) ?? 3
        retryDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .retryDelaySeconds) ?? 10
    }
}

struct DeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let connection: String
    let lockState: String
    let modelName: String?
    let productType: String?
    let osVersion: String?

    var displayModelName: String {
        modelName ?? productType ?? "iPhone"
    }
}

struct DeviceMetadata: Sendable {
    let identifiers: Set<String>
    let preferredIdentifier: String
    let name: String
    let connection: String
    let modelName: String?
    let productType: String?
    let osVersion: String?
}

struct InstalledApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let version: String?
    let iconPath: String?
}

struct CommandResult {
    let status: Int32
    let output: String
}

struct BackgroundRefreshRecord {
    let appID: UUID
    let succeeded: Bool
    let date: Date
}

enum XToolIdentifier {
    static func originalBundleIdentifier(from identifier: String) -> String? {
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard let markerIndex = components.firstIndex(where: { $0.hasPrefix("XTL-") }),
              markerIndex <= 1,
              components.index(after: markerIndex) < components.endIndex else { return nil }
        return components[components.index(after: markerIndex)...].joined(separator: ".")
    }

    static func matches(_ identifier: String, originalBundleIdentifier: String) -> Bool {
        identifier == originalBundleIdentifier
            || self.originalBundleIdentifier(from: identifier) == originalBundleIdentifier
    }
}

enum RefreshTaskLock {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideloadManager/refresh.lock")
    }

    static func acquire() -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = shlockProcess(arguments: ["-f", url.path, "-p", String(getpid())])
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func activeOwner() -> Int32? {
        let process = shlockProcess(arguments: ["-f", url.path])
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let data = try? Data(contentsOf: url),
                  let owner = Int32(String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return owner
        } catch {
            return nil
        }
    }

    static func releaseIfOwnedByCurrentProcess() {
        guard let data = try? Data(contentsOf: url),
              String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func shlockProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shlock")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}

extension ManagedApp {
    var signatureStatusText: String {
        guard let expiry = signatureExpiresAt else { return "尚未读取签名有效期" }
        let seconds = Int(expiry.timeIntervalSinceNow)
        let prefix = signatureExpirySource == "profile" ? "Profile 剩余" : "预计剩余"
        if seconds <= 0 {
            return signatureExpirySource == "profile" ? "已过期，需要立即刷新" : "预计已过期，需要刷新"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(prefix) \(days) 天 \(hours) 小时" }
        return "\(prefix) \(max(hours, 1)) 小时"
    }

    var signatureNeedsRefresh: Bool {
        guard let expiry = signatureExpiresAt else { return false }
        return expiry <= Date()
    }

    func signatureIsNearExpiry(within hours: Int = 24) -> Bool {
        guard let expiry = signatureExpiresAt else { return false }
        return expiry > Date() && expiry.timeIntervalSinceNow <= Double(hours) * 3_600
    }
}

// MARK: - Persistence

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: ManagerConfig {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideloadManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.iso8601.decode(ManagerConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = ManagerConfig()
        }
    }

    func save() {
        guard let data = try? JSONEncoder.pretty.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - IPA inspection

struct IPAInspection {
    let displayName: String?
    let bundleIdentifier: String?
    let iconPath: String?
}

enum IPAInspector {
    static func inspect(url: URL, cacheID: UUID) -> IPAInspection {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sideload-manager-ipa-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", url.path, tempURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let appURL = FileManager.default.enumerator(at: tempURL, includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL })
                    .first(where: { $0.pathExtension == "app" }) else {
                return IPAInspection(displayName: nil, bundleIdentifier: nil, iconPath: nil)
            }

            let infoURL = appURL.appendingPathComponent("Info.plist")
            let plist = (try? Data(contentsOf: infoURL)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil)
            } as? [String: Any]
            let displayName = (plist?["CFBundleDisplayName"] as? String)
                ?? (plist?["CFBundleName"] as? String)
            let bundleIdentifier = plist?["CFBundleIdentifier"] as? String

            let pngs = (FileManager.default.enumerator(
                at: appURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { lhs, rhs in
                    let leftName = lhs.lastPathComponent.lowercased()
                    let rightName = rhs.lastPathComponent.lowercased()
                    let leftIcon = leftName.contains("appicon")
                    let rightIcon = rightName.contains("appicon")
                    if leftIcon != rightIcon { return leftIcon }
                    let leftSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let rightSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return leftSize > rightSize
                }

            var iconPath: String?
            if let icon = pngs.first {
                let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SideloadManager/icons", isDirectory: true)
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                let destination = cacheDirectory.appendingPathComponent("\(cacheID.uuidString).png")
                try? FileManager.default.removeItem(at: destination)
                if convertToStandardPNG(source: icon, destination: destination) {
                    iconPath = destination.path
                }
            }
            return IPAInspection(displayName: displayName, bundleIdentifier: bundleIdentifier, iconPath: iconPath)
        } catch {
            return IPAInspection(displayName: nil, bundleIdentifier: nil, iconPath: nil)
        }
    }

    @discardableResult
    private static func convertToStandardPNG(source: URL, destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-s", "format", "png", source.path, "--out", destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        } catch {}
        try? FileManager.default.copyItem(at: source, to: destination)
        return FileManager.default.fileExists(atPath: destination.path)
    }

    static func normalizeCachedIcon(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let normalized = url.deletingPathExtension().appendingPathExtension("normalized.png")
        guard convertToStandardPNG(source: url, destination: normalized) else { return nil }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: normalized, to: url)
        return NSImage(contentsOf: url) == nil ? nil : url.path
    }
}

enum IPAArchive {
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideloadManager/ipas", isDirectory: true)
    }

    static func archive(_ source: URL, appID: UUID) -> URL? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let safeName = source.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            let destination = directoryURL.appendingPathComponent("\(appID.uuidString)-\(safeName).ipa")
            if FileManager.default.fileExists(atPath: destination.path) {
                let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let destinationSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                if sourceSize == destinationSize && sourceSize > 0 { return destination }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func isArchived(_ path: String) -> Bool {
        let prefix = directoryURL.standardizedFileURL.path + "/"
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(prefix)
    }
}

struct ProvisioningProfile: Hashable {
    let applicationIdentifier: String?
    let expirationDate: Date?
    let state: String?
    let profileType: String?
}

// MARK: - Runtime tool discovery

/// Finds the xtool executable without depending on the original developer's home directory.
///
/// A user can set `SIDELOAD_XTOOL_PATH` to either the executable itself or an
/// xtool `.app` bundle. When no override is supplied, the manager checks a
/// bundled/sibling app, common install locations, and the current PATH.
enum XToolLocator {
    static let environmentVariable = "SIDELOAD_XTOOL_PATH"

    static var displayPath: String {
        resolve()?.path ?? "未找到（可设置 \(environmentVariable)）"
    }

    static func resolve() -> URL? {
        let fileManager = FileManager.default
        for candidate in candidateURLs() {
            let standardized = candidate.standardizedFileURL
            if fileManager.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }

    /// Returns a shell fragment used by launchd jobs. The job may run with a
    /// minimal PATH, so it must not rely on the interactive shell environment.
    static func shellResolution() -> String {
        let candidates = candidateURLs(includeEnvironment: false)
            .map { shellQuote($0.path) }
            .joined(separator: " ")
        return """
        TOOL="${\(environmentVariable):-}"
        if [[ -n "$TOOL" && -d "$TOOL" ]]; then
            if [[ -x "$TOOL/Contents/Resources/bin/xtool" ]]; then TOOL="$TOOL/Contents/Resources/bin/xtool";
            elif [[ -x "$TOOL/Contents/MacOS/xtool" ]]; then TOOL="$TOOL/Contents/MacOS/xtool";
            elif [[ -x "$TOOL/xtool" ]]; then TOOL="$TOOL/xtool"; fi
        fi
        if [[ -z "$TOOL" || ! -x "$TOOL" ]]; then
            for candidate in \(candidates); do
                if [[ -x "$candidate" ]]; then TOOL="$candidate"; break; fi
            done
        fi
        if [[ -z "$TOOL" || ! -x "$TOOL" ]]; then
            TOOL="$(command -v xtool 2>/dev/null || true)"
        fi
        if [[ -z "$TOOL" || ! -x "$TOOL" ]]; then
            print -u2 -- "未找到 xtool；请设置 \(environmentVariable)"
            exit 127
        fi
        export XTL_CLI=1
        """
    }

    private static func candidateURLs(includeEnvironment: Bool = true) -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard !path.isEmpty, path.contains("/") else { return }
            let expanded = NSString(string: path).expandingTildeInPath
            let base = URL(fileURLWithPath: expanded).standardizedFileURL
            let paths: [URL]
            if base.pathExtension.lowercased() == "app" {
                paths = [
                    base.appendingPathComponent("Contents/Resources/bin/xtool"),
                    base.appendingPathComponent("Contents/MacOS/xtool")
                ]
            } else {
                paths = [base]
            }
            for candidate in paths {
                if seen.insert(candidate.path).inserted {
                    candidates.append(candidate)
                }
            }
        }

        if includeEnvironment,
           let configured = ProcessInfo.processInfo.environment[environmentVariable] {
            append(configured)
        }

        if let bundled = Bundle.main.url(forResource: "xtool", withExtension: nil, subdirectory: "bin") {
            append(bundled.path)
        }
        let bundleURL = Bundle.main.bundleURL
        let bundleParent = bundleURL.deletingLastPathComponent()
        for appName in ["xtool-fixed.app", "xtool.app"] {
            append(bundleParent.appendingPathComponent(appName).path)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [
            home.appendingPathComponent("bin/xtool").path,
            home.appendingPathComponent(".local/bin/xtool").path,
            home.appendingPathComponent("Applications/xtool-fixed.app").path,
            home.appendingPathComponent("Applications/xtool.app").path,
            home.appendingPathComponent("Library/Application Support/SideloadManager/xtool").path,
            "/Applications/xtool-fixed.app",
            "/Applications/xtool.app",
            "/opt/homebrew/bin/xtool",
            "/usr/local/bin/xtool",
            "/usr/bin/xtool"
        ] {
            append(path)
        }

        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnvironment.split(separator: ":") {
                append(URL(fileURLWithPath: String(directory)).appendingPathComponent("xtool").path)
            }
        }
        return candidates
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - xtool bridge

final class XToolService: Sendable {
    static let shared = XToolService()

    var displayPath: String { XToolLocator.displayPath }

    func run(_ arguments: [String]) async -> CommandResult {
        guard let executable = XToolLocator.resolve() else {
            return CommandResult(
                status: -127,
                output: "未找到 xtool。请安装 xtool，或设置 \(XToolLocator.environmentVariable) 指向 xtool 可执行文件。"
            )
        }
        return await runExecutable(executable.path, arguments: arguments)
    }

    func lockState(deviceID: String) async -> String {
        let result = await runExecutable(
            "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "info", "lockState", "--device", deviceID, "--timeout", "15"]
        )
        let output = result.output
        if output.localizedCaseInsensitiveContains("unlockedSinceBoot: true") {
            return "已解锁"
        }
        if output.localizedCaseInsensitiveContains("unlockedSinceBoot: false") {
            return "需要解锁"
        }
        if output.localizedCaseInsensitiveContains("locked") {
            return "已锁定"
        }
        return "未知"
    }

    func deviceMetadata() async -> [DeviceMetadata] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sideload-manager-devices-\(UUID().uuidString).json")
        let result = await runExecutable(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl", "list", "devices",
                "--json-output", outputURL.path,
                "--timeout", "15"
            ]
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard result.status == 0,
              let data = try? Data(contentsOf: outputURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let resultObject = root["result"] as? [String: Any],
              let devices = resultObject["devices"] as? [[String: Any]] else { return [] }

        return devices.compactMap { device in
            guard let hardware = device["hardwareProperties"] as? [String: Any],
                  (hardware["deviceType"] as? String) == "iPhone",
                  let properties = device["deviceProperties"] as? [String: Any],
                  let name = properties["name"] as? String else { return nil }
            let coreIdentifier = device["identifier"] as? String
            let udid = hardware["udid"] as? String
            let identifiers = Set([coreIdentifier, udid].compactMap { $0 })
            guard let preferredIdentifier = udid ?? coreIdentifier else { return nil }
            let connectionProperties = device["connectionProperties"] as? [String: Any]
            let transport = (connectionProperties?["transportType"] as? String)?.lowercased() ?? ""
            let connection = transport.contains("usb") || transport.contains("wired") ? "usb" : "network"
            return DeviceMetadata(
                identifiers: identifiers,
                preferredIdentifier: preferredIdentifier,
                name: name,
                connection: connection,
                modelName: hardware["marketingName"] as? String,
                productType: hardware["productType"] as? String,
                osVersion: properties["osVersionNumber"] as? String
            )
        }
    }

    func provisioningProfiles() async -> (profiles: [ProvisioningProfile], message: String?) {
        let result = await run(["ds", "profiles", "list"])
        guard result.status == 0 else {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([], output.isEmpty ? "无法读取签名配置文件" : output)
        }
        let blocks = result.output.components(separatedBy: "- id:").dropFirst()
        let profiles = blocks.compactMap { block -> ProvisioningProfile? in
            let lines = block.split(separator: "\n")
            let applicationIdentifier = lines
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("entitlements:") })
                .flatMap { line -> String? in
                    let raw = String(line)
                    guard let start = raw.range(of: "application-identifier\":\"")?.upperBound else { return nil }
                    let remainder = raw[start...]
                    guard let end = remainder.firstIndex(of: "\"") else { return nil }
                    return String(remainder[..<end])
                }
            let expirationDate = lines
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("expiration date:") })
                .flatMap { line -> Date? in
                    let raw = String(line)
                    guard let colon = raw.firstIndex(of: ":") else { return nil }
                    let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    return parseProfileDate(value)
                }
            let state = lines
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("profile state:") })
                .flatMap { line -> String? in
                    let raw = String(line)
                    guard let colon = raw.firstIndex(of: ":") else { return nil }
                    return raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            let profileType = lines
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("profile type:") })
                .flatMap { line -> String? in
                    let raw = String(line)
                    guard let colon = raw.firstIndex(of: ":") else { return nil }
                    return raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            guard applicationIdentifier != nil || expirationDate != nil else { return nil }
            return ProvisioningProfile(
                applicationIdentifier: applicationIdentifier,
                expirationDate: expirationDate,
                state: state,
                profileType: profileType
            )
        }
        return (profiles, nil)
    }

    func uninstall(deviceID: String, bundleIdentifier: String) async -> CommandResult {
        await runExecutable(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "uninstall", "app",
                "--device", deviceID,
                bundleIdentifier,
                "--timeout", "30"
            ]
        )
    }

    func installedApps(deviceID: String) async -> (apps: [InstalledApp], message: String?) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sideload-manager-apps-\(UUID().uuidString).json")
        let result = await runExecutable(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "info", "apps",
                "--device", deviceID,
                "--no-include-default-apps",
                "--json-output", outputURL.path,
                "--timeout", "30"
            ]
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let data = try? Data(contentsOf: outputURL),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.localizedCaseInsensitiveContains("device is locked") || output.localizedCaseInsensitiveContains("locked") {
                return ([], "请先解锁 iPhone，再读取已安装应用")
            }
            return ([], output.isEmpty ? "读取手机应用失败" : output)
        }
        let apps = extractInstalledApps(from: object)
        if apps.isEmpty, let error = extractError(from: object) {
            return ([], error)
        }
        var appsWithIcons: [InstalledApp] = []
        for app in apps {
            let iconPath = await fetchIcon(deviceID: deviceID, bundleIdentifier: app.bundleIdentifier)
            appsWithIcons.append(InstalledApp(
                id: app.id,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                version: app.version,
                iconPath: iconPath
            ))
        }
        return (appsWithIcons, nil)
    }

    private func runExecutable(_ executable: String, arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output

            var environment = ProcessInfo.processInfo.environment
            for key in ["ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "all_proxy", "https_proxy", "http_proxy"] {
                environment.removeValue(forKey: key)
            }
            environment["XTL_CLI"] = "1"
            process.environment = environment

            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return CommandResult(
                    status: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)
                )
            } catch {
                return CommandResult(status: -1, output: error.localizedDescription)
            }
        }.value
    }

    private func extractInstalledApps(from object: Any) -> [InstalledApp] {
        var result: [InstalledApp] = []
        var seen = Set<String>()
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let bundle = (dictionary["bundleIdentifier"] as? String)
                    ?? (dictionary["bundleID"] as? String)
                    ?? (dictionary["identifier"] as? String)
                let name = (dictionary["name"] as? String)
                    ?? (dictionary["displayName"] as? String)
                    ?? (dictionary["CFBundleDisplayName"] as? String)
                    ?? (dictionary["CFBundleName"] as? String)
                if let bundle, let name, bundle.contains(".") {
                    let version = (dictionary["version"] as? String)
                        ?? (dictionary["shortVersionString"] as? String)
                        ?? (dictionary["CFBundleShortVersionString"] as? String)
                    if seen.insert(bundle).inserted {
                        result.append(InstalledApp(id: bundle, name: name, bundleIdentifier: bundle, version: version, iconPath: nil))
                    }
                }
                for child in dictionary.values { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(object)
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func parseProfileDate(_ value: String) -> Date? {
        let locales = [Locale.current, Locale(identifier: "en_US_POSIX")]
        for locale in locales {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = .current
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.isLenient = true
            if let date = formatter.date(from: value) { return date }
        }

        for format in ["yyyy/M/d, H:mm", "yyyy/M/d H:mm", "M/d/yyyy, h:mm a"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func fetchIcon(deviceID: String, bundleIdentifier: String) async -> String? {
        let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideloadManager/installed-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let safeName = bundleIdentifier.replacingOccurrences(of: ".", with: "_")
        let destination = cacheDirectory.appendingPathComponent("\(safeName).png")
        let result = await runExecutable(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "info", "appIcon",
                "--device", deviceID,
                "--app-bundle-id", bundleIdentifier,
                "--destination", destination.path,
                "--width", "120",
                "--height", "120",
                "--scale", "1",
                "--timeout", "30"
            ]
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return IPAInspector.normalizeCachedIcon(at: destination)
    }

    private func extractError(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let error = dictionary["error"] as? [String: Any],
           let userInfo = error["userInfo"] as? [String: Any],
           let description = (userInfo["NSLocalizedDescription"] as? [String: Any])?["string"] as? String {
            return description
        }
        if let error = dictionary["error"] as? [String: Any],
           let description = error["message"] as? String { return description }
        for value in dictionary.values {
            if let error = extractError(from: value) { return error }
        }
        return nil
    }
}

// MARK: - Background launch agent

@MainActor
final class LaunchAgentManager {
    private let label = "sh.serena.SideloadManager.refresh"

    private var launchAgentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL { launchAgentsURL.appendingPathComponent("\(label).plist") }
    private var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideloadManager/refresh.sh")
    }
    private var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideloadManager/background-refresh.state")
    }
    private var enabledURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("background-refresh.enabled")
    }
    private var checkMarkerURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("last-background-check")
    }

    func install(config: ManagerConfig, log: (String) -> Void) {
        do {
            try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let wasEnabled = FileManager.default.fileExists(atPath: enabledURL.path)
            let script = makeScript(config: config)
            try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            try Data("enabled\n".utf8).write(to: enabledURL, options: .atomic)
            if !wasEnabled { try? FileManager.default.removeItem(at: checkMarkerURL) }

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/bin/zsh", scriptURL.path],
                "StartInterval": 3_600,
                "RunAtLoad": false,
                "ProcessType": "Background",
                "StandardOutPath": scriptURL.deletingLastPathComponent().appendingPathComponent("refresh.log").path,
                "StandardErrorPath": scriptURL.deletingLastPathComponent().appendingPathComponent("refresh.log").path
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)

            let alreadyOwnsLock = RefreshTaskLock.activeOwner() == getpid()
            var acquiredControlLock = false
            if !alreadyOwnsLock {
                guard RefreshTaskLock.acquire() else {
                    log("后台刷新配置已更新，将在当前签名任务完成后重载")
                    return
                }
                acquiredControlLock = true
            }
            defer {
                if acquiredControlLock { RefreshTaskLock.releaseIfOwnedByCurrentProcess() }
            }
            if isLoaded {
                _ = commandStatus(["launchctl", "bootout", "gui/\(getuid())/\(label)"])
            }
            let status = commandStatus(["launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
            guard status == 0 || isLoaded else {
                throw NSError(
                    domain: "SideloadManager.LaunchAgent",
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap 失败（\(status)）"]
                )
            }
            log("已启用后台刷新：每 \(config.refreshIntervalHours) 小时检查一次")
        } catch {
            log("后台刷新启用失败：\(error.localizedDescription)")
        }
    }

    func uninstall(log: (String) -> Void) {
        let wasConfigured = isLoaded
            || FileManager.default.fileExists(atPath: enabledURL.path)
            || FileManager.default.fileExists(atPath: plistURL.path)
            || FileManager.default.fileExists(atPath: scriptURL.path)
        try? FileManager.default.removeItem(at: enabledURL)
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: scriptURL)

        let alreadyOwnsLock = RefreshTaskLock.activeOwner() == getpid()
        var acquiredControlLock = false
        if !alreadyOwnsLock {
            guard RefreshTaskLock.acquire() else {
                if wasConfigured { log("已关闭后台刷新；当前任务结束后完全停止") }
                return
            }
            acquiredControlLock = true
        }
        defer {
            if acquiredControlLock { RefreshTaskLock.releaseIfOwnedByCurrentProcess() }
        }
        if isLoaded {
            _ = commandStatus(["launchctl", "bootout", "gui/\(getuid())/\(label)"])
        }
        if wasConfigured { log("已关闭后台刷新") }
    }

    func consumeResults() -> [BackgroundRefreshRecord] {
        guard RefreshTaskLock.activeOwner() == nil, RefreshTaskLock.acquire() else { return [] }
        defer { RefreshTaskLock.releaseIfOwnedByCurrentProcess() }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [] }
        let snapshotURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent("background-refresh-\(UUID().uuidString).state")
        do {
            try FileManager.default.moveItem(at: stateURL, to: snapshotURL)
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        guard let content = try? String(contentsOf: snapshotURL, encoding: .utf8), !content.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        let records = content.split(separator: "\n").compactMap { line -> BackgroundRefreshRecord? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let appID = UUID(uuidString: String(fields[0])),
                  let date = formatter.date(from: String(fields[2])) else { return nil }
            return BackgroundRefreshRecord(appID: appID, succeeded: fields[1] == "success", date: date)
        }
        return records
    }

    func makeScript(config: ManagerConfig) -> String {
        let state = shellQuote(stateURL.path)
        let enabled = shellQuote(enabledURL.path)
        let checkMarker = shellQuote(checkMarkerURL.path)
        let checkInterval = max(3_600, config.refreshIntervalHours * 3_600)
        var lines = [
            "#!/bin/zsh",
            "set -u",
            "unset ALL_PROXY HTTPS_PROXY HTTP_PROXY all_proxy https_proxy http_proxy",
            XToolLocator.shellResolution(),
            "STATE=\(state)",
            "ENABLED=\(enabled)",
            "[[ -f \"$ENABLED\" ]] || exit 0",
            "RUN_DIR=\"${STATE:h}/refresh-runs\"",
            "mkdir -p \"${STATE:h}\" \"$RUN_DIR\"",
            "LOCK_FILE=\(shellQuote(RefreshTaskLock.url.path))",
            "/usr/bin/shlock -f \"$LOCK_FILE\" -p $$ || exit 0",
            "trap 'rm -f \"$LOCK_FILE\"' EXIT",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
            "trap 'exit 129' HUP",
            "[[ -f \"$ENABLED\" ]] || exit 0",
            "INSTALL_MODE=--usb",
            "DEVICE_UDID=\"$(\"$TOOL\" devices --usb --no-wait 2>/dev/null | /usr/bin/awk -F ': ' 'NF > 1 {print $NF; exit}')\"",
            "if [[ -z \"$DEVICE_UDID\" ]]; then INSTALL_MODE=--network; DEVICE_UDID=\"$(\"$TOOL\" devices --network --no-wait 2>/dev/null | /usr/bin/awk -F ': ' 'NF > 1 {print $NF; exit}')\"; fi",
            "[[ -z \"$DEVICE_UDID\" ]] && exit 0",
            "CHECK_MARKER=\(checkMarker)",
            "CHECK_INTERVAL=\(checkInterval)",
            "check_now=\"$(date +%s)\"",
            "if [[ -f \"$CHECK_MARKER\" ]]; then last_check=\"$(<\"$CHECK_MARKER\")\"; if [[ \"$last_check\" =~ '^[0-9]+$' ]] && (( check_now < last_check + CHECK_INTERVAL )); then exit 0; fi; fi",
            "print -r -- \"$check_now\" > \"$CHECK_MARKER\""
        ]
        for app in config.apps where app.scheduleEnabled && app.nextRun != nil {
            let path = shellQuote(app.ipaPath)
            let attempts = max(1, config.maxRetryCount)
            let delay = max(1, config.retryDelaySeconds)
            let appID = app.id.uuidString
            let initialDue = Int(app.nextRun!.timeIntervalSince1970)
            let configLastRun = Int((app.lastRun ?? .distantPast).timeIntervalSince1970)
            let interval = max(3_600, app.intervalHours * 3_600)
            lines.append("""
            [[ -f "$ENABLED" ]] || exit 0
            MARKER="$RUN_DIR/\(appID)"
            DUE=\(initialDue)
            if [[ -f "$MARKER" ]]; then
                last="$(<"$MARKER")"
                if [[ "$last" =~ '^[0-9]+$' ]] && (( last > \(configLastRun) )); then DUE=$((last + \(interval))); fi
            fi
            now="$(date +%s)"
            if (( now >= DUE )) && [[ -f \(path) ]]; then
                success=0
                for attempt in {1..\(attempts)}; do
                    "$TOOL" install "$INSTALL_MODE" --udid "$DEVICE_UDID" \(path) && success=1 && break
                    [[ $attempt -lt \(attempts) ]] && sleep \(delay)
                done
                stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                if [[ $success -eq 1 ]]; then
                    print -r -- "$now" > "$MARKER"
                    print -r -- "\(appID)\tsuccess\t$stamp" >> "$STATE"
                else
                    print -r -- "\(appID)\tfailure\t$stamp" >> "$STATE"
                    /usr/bin/osascript -e 'display notification "签名刷新失败，请打开管理器查看日志" with title "自签管理"' >/dev/null 2>&1 || true
                fi
            fi
            """)
        }
        lines.append("if [[ -f \"$STATE\" ]]; then tail -n 200 \"$STATE\" > \"$STATE.tmp\" && mv \"$STATE.tmp\" \"$STATE\"; fi")
        return lines.joined(separator: "\n") + "\n"
    }

    private var isLoaded: Bool {
        commandStatus(["launchctl", "print", "gui/\(getuid())/\(label)"]) == 0
    }

    private func commandStatus(_ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shell(_ args: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

@MainActor
final class StartupAgentManager {
    private let label = "sh.serena.SideloadManager.autostart"

    private var launchAgentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL { launchAgentsURL.appendingPathComponent("\(label).plist") }

    func sync(enabled: Bool, log: (String) -> Void) {
        do {
            if !enabled {
                _ = try? shell(["launchctl", "bootout", "gui/\(getuid())", plistURL.path])
                try? FileManager.default.removeItem(at: plistURL)
                log("已关闭登录自启")
                return
            }

            try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", Bundle.main.bundleURL.path],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            _ = try? shell(["launchctl", "bootout", "gui/\(getuid())", plistURL.path])
            _ = try shell(["launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
            log("已启用登录自启")
        } catch {
            log("登录自启设置失败：\(error.localizedDescription)")
        }
    }

    private func shell(_ args: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

@MainActor
final class USBMonitorAgentManager {
    private let label = "sh.serena.SideloadManager.usb-monitor"

    private var launchAgentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL { launchAgentsURL.appendingPathComponent("\(label).plist") }
    private var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideloadManager/usb-monitor.sh")
    }
    private var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SideloadManager/usb-monitor.state")
    }

    func sync(enabled: Bool, log: (String) -> Void) {
        do {
            if !enabled {
                _ = try? shell(["launchctl", "bootout", "gui/\(getuid())", plistURL.path])
                try? FileManager.default.removeItem(at: plistURL)
                try? FileManager.default.removeItem(at: scriptURL)
                try? FileManager.default.removeItem(at: stateURL)
                log("已关闭 USB 自动打开")
                return
            }

            try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = makeScript()
            try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/bin/zsh", scriptURL.path],
                "StartInterval": 5,
                "RunAtLoad": true,
                "ProcessType": "Background",
                "LimitLoadToSessionType": "Aqua",
                "StandardOutPath": scriptURL.deletingLastPathComponent().appendingPathComponent("usb-monitor.log").path,
                "StandardErrorPath": scriptURL.deletingLastPathComponent().appendingPathComponent("usb-monitor.log").path
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            try? "".data(using: .utf8)?.write(to: stateURL, options: .atomic)
            _ = try? shell(["launchctl", "bootout", "gui/\(getuid())", plistURL.path])
            _ = try shell(["launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
            log("已启用 USB 插入自动打开")
        } catch {
            log("USB 自动打开设置失败：\(error.localizedDescription)")
        }
    }

    private func makeScript() -> String {
        let state = shellQuote(stateURL.path)
        let application = shellQuote(Bundle.main.bundleURL.path)
        return """
        #!/bin/zsh
        set -u
        unset ALL_PROXY HTTPS_PROXY HTTP_PROXY all_proxy https_proxy http_proxy
        \(XToolLocator.shellResolution())
        STATE=\(state)
        mkdir -p "${STATE:h}"
        current="$($TOOL devices --all --no-wait 2>/dev/null | /usr/bin/awk '/\\[usb\\]/ {print "1"; exit}')"
        previous=""
        [[ -f "$STATE" ]] && previous="$(<\"$STATE\")"
        if [[ -n "$current" && -z "$previous" ]]; then
            /usr/bin/open -g \(application)
        fi
        print -r -- "$current" > "$STATE"
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shell(_ args: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

// MARK: - View model

@MainActor
final class ManagerViewModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var installedApps: [InstalledApp] = []
    @Published var installedAppsError: String?
    @Published var authStatus = "尚未检查"
    @Published var logs: [String] = []
    @Published var isBusy = false
    @Published var activityMessage = "就绪"
    @Published var selectedTab = 0
    @Published var lastStatusRefresh: Date?

    var store = ConfigStore()
    private let xtool = XToolService.shared
    private let launchAgent = LaunchAgentManager()
    private let startupAgent = StartupAgentManager()
    private let usbMonitorAgent = USBMonitorAgentManager()
    private let notifications = NotificationManager.shared
    private var schedulerTask: Task<Void, Never>?

    let freeProfileAppLimit = 3

    var freeProfileUsageText: String {
        installedAppsError == nil ? "\(installedApps.count)/\(freeProfileAppLimit)" : "需读取"
    }

    var freeProfileLimitReached: Bool {
        installedAppsError == nil && installedApps.count >= freeProfileAppLimit
    }

    init() {
        populateMissingIPAInfo()
        migratePendingApps()
        startupAgent.sync(enabled: store.config.launchAtLoginEnabled, log: log)
        usbMonitorAgent.sync(enabled: store.config.autoOpenOnUSBEnabled, log: log)
        notifications.requestAuthorization()
        syncBackgroundRefreshResults()
        syncBackgroundRefresh()
        Task { [weak self] in
            await self?.refreshStatus()
        }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.syncBackgroundRefreshResults()
            }
        }
    }

    deinit { schedulerTask?.cancel() }

    func log(_ message: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        logs.insert("[\(stamp)] \(message)", at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }

    func refreshStatus() async {
        isBusy = true
        activityMessage = "正在读取账号、设备和手机自签应用…"
        async let auth = xtool.run(["auth", "status"])
        async let deviceResult = xtool.run(["devices", "--all", "--no-wait"])
        async let metadataResult = xtool.deviceMetadata()
        let authResult = await auth
        let deviceOutput = await deviceResult
        let metadata = await metadataResult
        authStatus = authResult.status == 0 ? authResult.output.trimmingCharacters(in: .whitespacesAndNewlines) : "登录状态读取失败"
        var parsedDevices = parseDevices(deviceOutput.output)
        for details in metadata {
            let alreadyIncluded = parsedDevices.contains {
                details.identifiers.contains($0.id) || $0.name == details.name
            }
            if !alreadyIncluded {
                parsedDevices.append(DeviceInfo(
                    id: details.preferredIdentifier,
                    name: details.name,
                    connection: details.connection,
                    lockState: "未知",
                    modelName: details.modelName,
                    productType: details.productType,
                    osVersion: details.osVersion
                ))
            }
        }
        var enrichedDevices: [DeviceInfo] = []
        for device in parsedDevices {
            let details = metadata.first {
                $0.identifiers.contains(device.id) || $0.name == device.name
            }
            let lockState = await xtool.lockState(deviceID: device.id)
            enrichedDevices.append(DeviceInfo(
                id: device.id,
                name: device.name,
                connection: device.connection,
                lockState: lockState,
                modelName: details?.modelName,
                productType: details?.productType,
                osVersion: details?.osVersion
            ))
        }
        devices = enrichedDevices
        log("已刷新账号和设备状态")
        if let device = devices.first {
            await refreshInstalledApps(for: device)
        } else {
            installedApps = []
            installedAppsError = "没有检测到已连接设备"
        }
        await refreshSignatureExpiry()
        lastStatusRefresh = Date()
        activityMessage = devices.isEmpty ? "未检测到设备" : "状态已更新"
        isBusy = false
    }

    func refreshInstalledApps(for device: DeviceInfo? = nil) async {
        guard let target = device ?? devices.first else {
            installedApps = []
            installedAppsError = "没有检测到已连接设备"
            return
        }
        isBusy = true
        activityMessage = "正在读取手机自签应用…"
        let result = await xtool.installedApps(deviceID: target.id)
        installedApps = result.apps
        installedAppsError = result.message
        if let message = result.message {
            log("手机应用读取：\(message)")
        } else {
            log("已读取手机应用：\(result.apps.count) 个")
            await refreshSignatureExpiry()
        }
        activityMessage = result.message ?? "手机自签应用已更新"
        isBusy = false
    }

    func refreshSignatureExpiry() async {
        guard !store.config.apps.isEmpty else { return }
        let result = await xtool.provisioningProfiles()
        guard !result.profiles.isEmpty else {
            if let message = result.message { log("开发者 Profile 到期时间读取失败：\(message)") }
            return
        }
        var updated = 0
        for index in store.config.apps.indices {
            guard let bundle = store.config.apps[index].bundleIdentifier else { continue }
            let expiry = result.profiles.compactMap { profile -> Date? in
                guard profile.state?.caseInsensitiveCompare("ACTIVE") == .orderedSame,
                      profile.profileType?.caseInsensitiveCompare("IOS_APP_DEVELOPMENT") == .orderedSame,
                      let applicationIdentifier = profile.applicationIdentifier,
                      XToolIdentifier.matches(applicationIdentifier, originalBundleIdentifier: bundle) else { return nil }
                return profile.expirationDate
            }.max()
            guard let expiry else { continue }
            let now = Date()
            let intervalAnchor = store.config.apps[index].lastRun ?? now
            let intervalNext = Calendar.current.date(
                byAdding: .hour,
                value: store.config.apps[index].intervalHours,
                to: intervalAnchor
            )
            let expiryRefresh = Calendar.current.date(
                byAdding: .hour,
                value: -store.config.refreshLeadHours,
                to: expiry
            )
            store.config.apps[index].signatureExpiresAt = expiry
            store.config.apps[index].signatureExpirySource = "profile"
            store.config.apps[index].nextRun = [intervalNext, expiryRefresh].compactMap { $0 }.min()
            updated += 1
        }
        if updated > 0 {
            log("已匹配开发者 Profile 到期时间：\(updated) 个应用")
            store.save()
            syncBackgroundRefresh()
        }
    }

    func addIPA(_ url: URL) {
        activityMessage = "正在读取 IPA 图标和签名信息…"
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard !store.config.apps.contains(where: { $0.ipaPath == url.path }) else { return }
        let appID = UUID()
        let inspection = IPAInspector.inspect(url: url, cacheID: appID)
        if let bundleIdentifier = inspection.bundleIdentifier,
           store.config.apps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            activityMessage = "已跳过重复应用：\(inspection.displayName ?? name)"
            log("已跳过重复 IPA：\(bundleIdentifier)")
            return
        }
        let archivedURL = IPAArchive.archive(url, appID: appID)
        var app = ManagedApp(
            id: appID,
            name: name,
            ipaPath: archivedURL?.path ?? url.path,
            bundleIdentifier: nil,
            iconPath: nil,
            nextRun: nil
        )
        app.name = inspection.displayName ?? name
        app.status = "未安装"
        app.bundleIdentifier = inspection.bundleIdentifier
        app.iconPath = inspection.iconPath
        store.config.apps.append(app)
        if archivedURL != nil {
            log("已归档并添加 IPA：\(name)")
        } else {
            log("已添加 IPA（未能归档）：\(name)")
        }
        activityMessage = "已添加：\(app.name)"
        syncBackgroundRefresh()
    }

    func refreshInstalledApp(_ app: InstalledApp) async {
        guard let managed = managedApp(for: app) else {
            log("无法直接刷新 \(app.name)：请先在“应用管理”导入对应的原始 IPA")
            selectedTab = 1
            return
        }
        await install(managed)
    }

    func managedApp(for installedApp: InstalledApp) -> ManagedApp? {
        store.config.apps.first(where: {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return XToolIdentifier.matches(
                installedApp.bundleIdentifier,
                originalBundleIdentifier: bundleIdentifier
            )
        })
    }

    func removeInstalledApp(_ app: InstalledApp) async {
        guard let device = devices.first else {
            installedAppsError = "没有检测到已连接设备"
            return
        }
        guard acquireRefreshLock() else {
            activityMessage = "已有签名任务正在运行"
            log("未卸载 \(app.name)：另一个签名任务正在运行")
            return
        }
        defer { releaseRefreshLock() }
        isBusy = true
        activityMessage = "正在卸载：\(app.name)…"
        log("开始卸载：\(app.name)")
        let result = await xtool.uninstall(deviceID: device.id, bundleIdentifier: app.bundleIdentifier)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { log(output) }
        if result.status == 0 {
            activityMessage = "已卸载：\(app.name)"
            notifications.send(title: "已卸载应用", body: "已从 iPhone 移除：\(app.name)")
            await refreshInstalledApps(for: device)
        } else {
            activityMessage = "卸载失败：\(app.name)"
            notifications.send(title: "卸载失败", body: "\(app.name) 未能从 iPhone 移除，请查看运行日志")
        }
        isBusy = false
    }

    func remove(_ app: ManagedApp) {
        guard acquireRefreshLock() else {
            activityMessage = "已有签名任务正在运行"
            log("未移除 \(app.name)：另一个签名任务正在运行")
            return
        }
        defer { releaseRefreshLock() }
        store.config.apps.removeAll { $0.id == app.id }
        log("已移除：\(app.name)")
        syncBackgroundRefresh()
    }

    func install(_ app: ManagedApp) async {
        guard acquireRefreshLock() else {
            activityMessage = "已有签名任务正在运行"
            log("已跳过重复操作：另一个签名任务正在运行")
            return
        }
        defer { releaseRefreshLock() }
        await performInstall(app)
    }

    func refreshDueApps() async {
        let now = Date()
        let dueApps = store.config.apps.filter {
            $0.scheduleEnabled && ($0.nextRun.map { $0 <= now } ?? false)
        }
        guard !dueApps.isEmpty else {
            activityMessage = "当前没有到期应用"
            log("刷新检查完成：当前没有到期应用")
            return
        }
        guard acquireRefreshLock() else {
            activityMessage = "已有签名任务正在运行"
            log("未启动批量刷新：另一个签名任务正在运行")
            return
        }
        defer {
            releaseRefreshLock()
            isBusy = false
        }
        isBusy = true
        log("开始刷新 (dueApps.count) 个到期应用")
        for app in dueApps {
            await performInstall(app, keepBusy: true)
        }
        activityMessage = "到期应用刷新完成"
    }

    private func performInstall(_ app: ManagedApp, keepBusy: Bool = false) async {
        guard FileManager.default.fileExists(atPath: app.ipaPath) else {
            log("文件不存在：\(app.ipaPath)")
            activityMessage = "文件不存在：\(app.name)"
            if let index = store.config.apps.firstIndex(where: { $0.id == app.id }) {
                store.config.apps[index].status = "文件不存在"
            }
            return
        }
        isBusy = true
        activityMessage = "正在签名并安装：\(app.name)…"
        log("开始安装：\(app.name)")
        let connection = devices.first?.connection.lowercased()
        let mode = connection == "network" ? "--network" : (connection == "usb" ? "--usb" : "--all")
        let attempts = max(1, store.config.maxRetryCount)
        var result = CommandResult(status: -1, output: "")
        for attempt in 1...attempts {
            if attempt > 1 {
                activityMessage = "第 \(attempt)/\(attempts) 次重试：\(app.name)…"
                log("第 \(attempt)/\(attempts) 次重试：\(app.name)")
            }
            let deviceArguments = devices.first.map { ["--udid", $0.id] } ?? []
            result = await xtool.run(["install", mode] + deviceArguments + [app.ipaPath])
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty { log(output) }
            if result.status == 0 { break }
            if attempt < attempts {
                try? await Task.sleep(for: .seconds(store.config.retryDelaySeconds))
            }
        }
        if let index = store.config.apps.firstIndex(where: { $0.id == app.id }) {
            if result.status == 0 {
                let now = Date()
                let expiry = Calendar.current.date(
                    byAdding: .day,
                    value: store.config.signatureLifetimeDays,
                    to: now
                )
                let intervalNext = Calendar.current.date(
                    byAdding: .hour,
                    value: store.config.apps[index].intervalHours,
                    to: now
                )
                let expiryRefresh = expiry.flatMap {
                    Calendar.current.date(byAdding: .hour, value: -store.config.refreshLeadHours, to: $0)
                }
                store.config.apps[index].lastRun = now
                store.config.apps[index].signatureExpiresAt = expiry
                store.config.apps[index].signatureExpirySource = "estimated"
                store.config.apps[index].nextRun = [intervalNext, expiryRefresh].compactMap { $0 }.min()
                store.config.apps[index].status = "安装成功"
                activityMessage = "安装成功：\(app.name)（预计 \(store.config.signatureLifetimeDays) 天）"
                notifications.send(title: "签名安装成功", body: "已安装并签名：\(app.name)")
                syncBackgroundRefresh()
            } else {
                store.config.apps[index].status = "安装失败"
                activityMessage = "安装失败：\(app.name)，请查看日志"
                notifications.send(title: "签名安装失败", body: "\(app.name) 安装失败，请打开管理器查看日志")
            }
        }
        if !keepBusy { isBusy = false }
    }

    private func acquireRefreshLock() -> Bool {
        RefreshTaskLock.acquire()
    }

    private func releaseRefreshLock() {
        RefreshTaskLock.releaseIfOwnedByCurrentProcess()
    }

    func syncBackgroundRefreshResults() {
        let records = launchAgent.consumeResults()
        guard !records.isEmpty else { return }
        for record in records {
            guard let index = store.config.apps.firstIndex(where: { $0.id == record.appID }) else { continue }
            let appName = store.config.apps[index].name
            store.config.apps[index].lastBackgroundRun = record.date
            store.config.apps[index].backgroundRefreshResult = record.succeeded ? "成功" : "失败"
            if record.succeeded {
                store.config.apps[index].lastRun = record.date
                store.config.apps[index].signatureExpiresAt = Calendar.current.date(
                    byAdding: .day,
                    value: store.config.signatureLifetimeDays,
                    to: record.date
                )
                store.config.apps[index].signatureExpirySource = "estimated"
                store.config.apps[index].nextRun = Calendar.current.date(
                    byAdding: .hour,
                    value: store.config.apps[index].intervalHours,
                    to: record.date
                )
                store.config.apps[index].status = "后台刷新成功"
                log("后台刷新成功：\(appName)")
            } else {
                store.config.apps[index].status = "后台刷新失败"
                log("后台刷新失败：\(appName)")
                notifications.send(title: "后台签名刷新失败", body: "\(appName) 刷新失败，请检查手机连接和运行日志")
            }
        }
        store.save()
        syncBackgroundRefresh()
        Task { await refreshSignatureExpiry() }
    }

    func syncBackgroundRefresh() {
        if store.config.backgroundRefreshEnabled {
            launchAgent.install(config: store.config, log: log)
        } else {
            launchAgent.uninstall(log: log)
        }
    }

    func rescheduleManagedApps() {
        for index in store.config.apps.indices {
            let lastRun = store.config.apps[index].lastRun
            if store.config.apps[index].signatureExpirySource != "profile", let lastRun {
                store.config.apps[index].signatureExpiresAt = Calendar.current.date(
                    byAdding: .day,
                    value: store.config.signatureLifetimeDays,
                    to: lastRun
                )
            }
            let intervalNext = lastRun.flatMap {
                Calendar.current.date(byAdding: .hour, value: store.config.apps[index].intervalHours, to: $0)
            }
            let expiryRefresh = store.config.apps[index].signatureExpiresAt.flatMap {
                Calendar.current.date(byAdding: .hour, value: -store.config.refreshLeadHours, to: $0)
            }
            if intervalNext != nil || expiryRefresh != nil {
                store.config.apps[index].nextRun = [intervalNext, expiryRefresh].compactMap { $0 }.min()
            }
        }
        store.save()
        syncBackgroundRefresh()
    }

    func syncStartup() {
        startupAgent.sync(enabled: store.config.launchAtLoginEnabled, log: log)
    }

    func syncUSBMonitor() {
        usbMonitorAgent.sync(enabled: store.config.autoOpenOnUSBEnabled, log: log)
    }

    private func populateMissingIPAInfo() {
        for index in store.config.apps.indices {
            let initialApp = store.config.apps[index]
            if FileManager.default.fileExists(atPath: initialApp.ipaPath),
               !IPAArchive.isArchived(initialApp.ipaPath),
               let archivedURL = IPAArchive.archive(URL(fileURLWithPath: initialApp.ipaPath), appID: initialApp.id) {
                store.config.apps[index].ipaPath = archivedURL.path
            }

            let app = store.config.apps[index]
            if let iconPath = app.iconPath,
               let normalized = IPAInspector.normalizeCachedIcon(at: URL(fileURLWithPath: iconPath)) {
                store.config.apps[index].iconPath = normalized
            }

            guard FileManager.default.fileExists(atPath: app.ipaPath),
                  store.config.apps[index].bundleIdentifier == nil || store.config.apps[index].iconPath == nil else { continue }
            let inspection = IPAInspector.inspect(url: URL(fileURLWithPath: app.ipaPath), cacheID: app.id)
            if store.config.apps[index].bundleIdentifier == nil {
                store.config.apps[index].bundleIdentifier = inspection.bundleIdentifier
            }
            if store.config.apps[index].iconPath == nil {
                store.config.apps[index].iconPath = inspection.iconPath
            }
        }
        store.save()
    }

    private func migratePendingApps() {
        for index in store.config.apps.indices where store.config.apps[index].lastRun == nil {
            if store.config.apps[index].status == "等待管理" {
                store.config.apps[index].status = "未安装"
            }
            store.config.apps[index].nextRun = nil
        }
        store.save()
    }

    private func parseDevices(_ output: String) -> [DeviceInfo] {
        let parsed: [DeviceInfo] = output.split(separator: "\n").compactMap { line in
            let raw = String(line)
            guard let open = raw.firstIndex(of: "["),
                  let close = raw.firstIndex(of: "]"),
                  close > open else { return nil }
            let name = raw[..<open].trimmingCharacters(in: .whitespaces)
            let connection = String(raw[raw.index(after: open)..<close])
            let remainder = raw[raw.index(after: close)...]
            guard let colon = remainder.firstIndex(of: ":") else { return nil }
            let udid = remainder[remainder.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !udid.isEmpty else { return nil }
            return DeviceInfo(
                id: udid,
                name: name,
                connection: connection,
                lockState: "未知",
                modelName: nil,
                productType: nil,
                osVersion: nil
            )
        }
        var unique: [String: DeviceInfo] = [:]
        for device in parsed {
            if let existing = unique[device.id] {
                if existing.connection != "usb" && device.connection == "usb" {
                    unique[device.id] = device
                }
            } else {
                unique[device.id] = device
            }
        }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var model: ManagerViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedTab) {
                Label("概览", systemImage: "gauge.with.dots.needle.67percent").tag(0)
                Label("应用管理", systemImage: "square.stack.3d.up").tag(1)
                Label("设备", systemImage: "iphone").tag(2)
                Label("日志", systemImage: "doc.text.magnifyingglass").tag(3)
                Label("设置", systemImage: "gearshape").tag(4)
            }
            .navigationTitle("自签管理")
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(model.activityMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial)

                Group {
                    switch model.selectedTab {
                    case 1: AppsView()
                    case 2: DevicesView()
                    case 3: LogsView()
                    case 4: SettingsView()
                    default: DashboardView()
                    }
                }
            }
            .frame(minWidth: 980, minHeight: 680)
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: ManagerViewModel
    @State private var pendingUninstall: InstalledApp?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自签管理中心").font(.largeTitle.bold())
                        Text("统一管理 IPA、设备和定时刷新签名").foregroundStyle(.secondary)
                        if let refreshedAt = model.lastStatusRefresh {
                            Text("上次刷新：\(refreshedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("刷新状态") { Task { await model.refreshStatus() } }
                        .buttonStyle(.borderedProminent)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatusCard(title: "Apple 账号", value: model.authStatus.contains("Logged in") || model.authStatus.contains("登录") ? "已登录" : "需检查", icon: "person.crop.circle")
                    StatusCard(title: "设备", value: "\(model.devices.count) 台在线", icon: "iphone")
                    StatusCard(title: "托管 IPA", value: "\(model.store.config.apps.count) 个", icon: "square.stack.3d.up")
                    StatusCard(title: "手机应用", value: model.installedAppsError == nil ? "\(model.installedApps.count) 个" : "需解锁", icon: "apps.iphone")
                    StatusCard(title: "免费名额", value: model.freeProfileUsageText, icon: "person.2")
                    StatusCard(
                        title: "签名提醒",
                        value: "\(model.store.config.apps.filter { $0.signatureNeedsRefresh || $0.signatureIsNearExpiry(within: model.store.config.refreshLeadHours) }.count) 个",
                        icon: "clock.badge.exclamationmark"
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    DeviceOverviewPanel(
                        device: model.devices.first,
                        installedApps: model.installedApps
                    )
                    .frame(width: 310)

                    RefreshPlanPanel(
                        apps: model.store.config.apps,
                        refreshLeadHours: model.store.config.refreshLeadHours,
                        backgroundRefreshEnabled: model.store.config.backgroundRefreshEnabled
                    )
                    .frame(maxWidth: .infinity)
                }

                GroupBox("快捷操作") {
                    HStack(spacing: 10) {
                        Button("管理应用") { model.selectedTab = 1 }
                        Button("刷新全部到期应用") { Task { await model.refreshDueApps() } }
                        Button("查看设备") { model.selectedTab = 2 }
                        Button("读取手机应用") { Task { await model.refreshInstalledApps() } }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox("签名状态（预计有效期 \(model.store.config.signatureLifetimeDays) 天）") {
                    if model.store.config.apps.isEmpty {
                        Text("添加并成功安装 IPA 后，这里会显示签名到期时间。")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(model.store.config.apps) { app in
                            HStack(spacing: 10) {
                                AppIconView(path: app.iconPath).frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).fontWeight(.medium)
                                    if let expiry = app.signatureExpiresAt {
                                        Text("\(app.signatureExpirySource == "profile" ? "Profile 到期" : "预计到期")：\(expiry.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                SignatureBadge(app: app)
                                Button("刷新") { Task { await model.install(app) } }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                GroupBox("手机自签应用") {
                    if model.freeProfileLimitReached {
                        Label("免费开发者账号最多保留 3 个自签应用；可卸载应用来释放名额。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.bottom, 6)
                    }
                    if let error = model.installedAppsError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else if model.installedApps.isEmpty {
                        Text("没有读取到应用")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(model.installedApps.prefix(8)) { app in
                            HStack {
                                AppIconView(path: app.iconPath)
                                    .frame(width: 36, height: 36)
                                VStack(alignment: .leading) {
                                    Text(app.name).fontWeight(.medium)
                                    Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let version = app.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                                if model.managedApp(for: app) != nil {
                                    Button("刷新") { Task { await model.refreshInstalledApp(app) } }
                                        .buttonStyle(.bordered)
                                } else {
                                    Button("导入 IPA") { model.selectedTab = 1 }
                                        .buttonStyle(.bordered)
                                }
                                Button("卸载", role: .destructive) {
                                    pendingUninstall = app
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isBusy)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            "确认从 iPhone 卸载？",
            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }),
            presenting: pendingUninstall
        ) { app in
            Button("卸载 \(app.name)", role: .destructive) {
                pendingUninstall = nil
                Task { await model.removeInstalledApp(app) }
            }
            Button("取消", role: .cancel) { pendingUninstall = nil }
        } message: { app in
            Text("这会从已连接的 iPhone 删除 \(app.name)，应用数据也可能一并移除。管理器中的 IPA 归档不会删除。")
        }
    }
}

private struct DeviceOverviewPanel: View {
    let device: DeviceInfo?
    let installedApps: [InstalledApp]

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                PhoneModelView(device: device, installedApps: installedApps)
                    .frame(height: 274)

                if let device {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text([device.displayModelName, device.osVersion.map { "iOS \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Label(device.connection == "usb" ? "USB" : "网络", systemImage: device.connection == "usb" ? "cable.connector" : "wifi")
                        Label(device.lockState, systemImage: device.lockState == "已解锁" ? "lock.open" : "lock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("等待连接 iPhone").font(.headline)
                    Text("连接后自动识别型号和系统版本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 344, alignment: .top)
            .padding(.top, 4)
        } label: {
            Label("当前设备", systemImage: "iphone")
        }
    }
}

private struct PhoneModelView: View {
    let device: DeviceInfo?
    let installedApps: [InstalledApp]

    private var appearance: PhoneAppearance {
        PhoneAppearance.resolve(modelName: device?.modelName, productType: device?.productType)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
                .fill(device == nil ? Color.secondary.opacity(0.38) : Color(red: 0.72, green: 0.72, blue: 0.69))
                .overlay {
                    RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.42), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.18), radius: 7, y: 4)

            RoundedRectangle(cornerRadius: appearance.cornerRadius - 1.2, style: .continuous)
                .fill(.black)
                .padding(1.15)

            PhoneScreenContent(device: device, installedApps: installedApps, cutout: appearance.cutout)
                .frame(width: appearance.screenWidth, height: appearance.screenHeight)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: appearance.screenCornerRadius, style: .continuous))

            if appearance.cutout == .notch {
                PhoneNotchShape()
                    .fill(.black)
                    .frame(width: appearance.notchWidth, height: appearance.notchHeight)
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 4.5) {
                            Circle()
                                .fill(Color.gray.opacity(0.42))
                                .frame(width: 3, height: 3)
                            Capsule()
                                .fill(Color.gray.opacity(0.55))
                                .frame(width: 15, height: 1.7)
                            Circle()
                                .fill(Color(red: 0.12, green: 0.18, blue: 0.23))
                                .frame(width: 3.5, height: 3.5)
                        }
                        .padding(.bottom, 3.2)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, appearance.verticalScreenInset)
            } else if appearance.cutout == .dynamicIsland {
                Capsule()
                    .fill(.black)
                    .frame(width: 48, height: 13.5)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(Color(red: 0.10, green: 0.17, blue: 0.23))
                            .frame(width: 4.2, height: 4.2)
                            .padding(.trailing, 6)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, appearance.verticalScreenInset + 6)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.65), lineWidth: 1.2)
                    .frame(width: 19, height: 19)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }

            PhoneSideButton(height: 15)
                .offset(x: -(appearance.width / 2 + 0.8), y: -72)
            PhoneSideButton(height: 27)
                .offset(x: -(appearance.width / 2 + 0.8), y: -43)
            PhoneSideButton(height: 27)
                .offset(x: -(appearance.width / 2 + 0.8), y: -10)
            PhoneSideButton(height: 46)
                .offset(x: appearance.width / 2 + 0.8, y: -38)
        }
        .frame(width: appearance.width, height: appearance.height)
        .accessibilityLabel(device.map { "\($0.displayModelName)，\($0.lockState)" } ?? "未连接 iPhone")
    }
}

private struct PhoneScreenContent: View {
    let device: DeviceInfo?
    let installedApps: [InstalledApp]
    let cutout: PhoneAppearance.Cutout

    var body: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: cutout == .homeButton ? 7 : 22)
            if let device {
                Image(systemName: device.lockState == "已解锁" ? "lock.open.fill" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(device.lockState == "已解锁" ? .green : .orange)
                Text(device.displayModelName)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(device.osVersion.map { "iOS \($0)" } ?? "iOS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(Array(installedApps.prefix(3))) { app in
                        AppIconView(path: app.iconPath)
                            .frame(width: 29, height: 29)
                    }
                    if installedApps.isEmpty {
                        Image(systemName: "square.stack.3d.up")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(installedApps.count) 个自签应用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer().frame(height: cutout == .homeButton ? 7 : 10)
            } else {
                Spacer()
                Image(systemName: "iphone.slash")
                    .font(.system(size: 27))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct PhoneNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let curve = min(rect.height * 0.52, rect.width * 0.14)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.34))
        path.addCurve(
            to: CGPoint(x: rect.maxX - curve, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - curve * 0.28),
            control2: CGPoint(x: rect.maxX - curve * 0.34, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + curve, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.34),
            control1: CGPoint(x: rect.minX + curve * 0.34, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - curve * 0.28)
        )
        path.closeSubpath()
        return path
    }
}

private struct PhoneSideButton: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
            .fill(Color(red: 0.62, green: 0.62, blue: 0.60))
            .frame(width: 2.1, height: height)
    }
}

private struct PhoneAppearance {
    enum Cutout { case homeButton, notch, dynamicIsland }

    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let cutout: Cutout
    let horizontalScreenInset: CGFloat
    let verticalScreenInset: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var screenWidth: CGFloat { width - horizontalScreenInset * 2 }
    var screenHeight: CGFloat { height - verticalScreenInset * 2 }
    var screenCornerRadius: CGFloat { max(2, cornerRadius - horizontalScreenInset + 0.5) }

    static func resolve(modelName: String?, productType: String?) -> PhoneAppearance {
        let model = (modelName ?? "").lowercased()
        let product = productType ?? ""
        let productMajor = Int(product.dropFirst("iPhone".count).split(separator: ",").first ?? "") ?? 0
        let isHomeButton = model.contains("se")
            || ["iphone 6", "iphone 7", "iphone 8"].contains(where: model.contains)
        let isDynamicIsland = model.contains("iphone 14 pro")
            || model.range(of: #"iphone (1[5-9]|[2-9][0-9])"#, options: .regularExpression) != nil
            || (model.isEmpty && productMajor >= 15)
        let cutout: Cutout = isHomeButton ? .homeButton : (isDynamicIsland ? .dynamicIsland : .notch)
        let isLarge = model.contains("plus") || model.contains("max")
        let isMini = model.contains("mini")
        let hasCompactNotch = model.contains("iphone 13")
            || model.contains("iphone 14")
            || (model.isEmpty && productMajor >= 14)
        let width: CGFloat = isLarge ? 136 : (isMini ? 124 : 132)
        let height: CGFloat = isLarge ? 276 : (isMini ? 254 : (width * 146.7 / 71.5))
        let horizontalInset: CGFloat = cutout == .homeButton ? 5 : 4.5
        let verticalInset: CGFloat = cutout == .homeButton ? 24 : 4.5
        return PhoneAppearance(
            width: width,
            height: height,
            cornerRadius: cutout == .homeButton ? 21 : 24.5,
            cutout: cutout,
            horizontalScreenInset: horizontalInset,
            verticalScreenInset: verticalInset,
            notchWidth: hasCompactNotch ? (isMini ? 48 : 52) : 63,
            notchHeight: hasCompactNotch ? 13 : 15.5
        )
    }
}

private struct RefreshPlanPanel: View {
    let apps: [ManagedApp]
    let refreshLeadHours: Int
    let backgroundRefreshEnabled: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if apps.isEmpty {
                        ContentUnavailableView("添加 IPA 后显示签名时间轴", systemImage: "calendar.badge.clock")
                            .frame(maxWidth: .infinity, minHeight: 278)
                    } else {
                        Chart {
                            RuleMark(x: .value("当前时间", timeline.date))
                                .foregroundStyle(Color.primary.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .annotation(position: .top, alignment: .leading) {
                                    Text("现在").font(.caption2).foregroundStyle(.secondary)
                                }

                            ForEach(apps) { app in
                                if let expiry = app.signatureExpiresAt {
                                    BarMark(
                                        xStart: .value("当前", timeline.date),
                                        xEnd: .value("到期", max(expiry, timeline.date.addingTimeInterval(1_800))),
                                        y: .value("应用", app.name),
                                        height: .fixed(16)
                                    )
                                    .foregroundStyle(planColor(for: app, now: timeline.date))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                } else {
                                    PointMark(
                                        x: .value("未读取", timeline.date.addingTimeInterval(3_600)),
                                        y: .value("应用", app.name)
                                    )
                                    .foregroundStyle(.gray)
                                    .symbolSize(70)
                                }

                                if let nextRun = app.nextRun, app.scheduleEnabled {
                                    PointMark(
                                        x: .value("计划刷新", bounded(nextRun, from: timeline.date, to: chartEnd(now: timeline.date))),
                                        y: .value("应用", app.name)
                                    )
                                    .foregroundStyle(.blue)
                                    .symbolSize(95)
                                }
                            }
                        }
                        .chartXScale(domain: timeline.date...chartEnd(now: timeline.date))
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day)) { _ in
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.16))
                                AxisTick()
                                AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisValueLabel().font(.caption)
                            }
                        }
                        .chartPlotStyle { plot in
                            plot
                                .background(Color.secondary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(minHeight: 245)

                        HStack(spacing: 14) {
                            PlanLegend(color: .green, title: "有效")
                            PlanLegend(color: .orange, title: "临期")
                            PlanLegend(color: .red, title: "过期")
                            PlanLegend(color: .blue, title: "刷新点")
                            Spacer()
                            Label(
                                backgroundRefreshEnabled ? "后台刷新已开启" : "后台刷新未开启",
                                systemImage: backgroundRefreshEnabled ? "checkmark.circle.fill" : "pause.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(backgroundRefreshEnabled ? .green : .secondary)
                        }

                        if let next = apps.compactMap(\.nextRun).min() {
                            Text("最近计划：\(next.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 344, alignment: .topLeading)
                .padding(.top, 4)
            } label: {
                Label("签名刷新计划", systemImage: "calendar.badge.clock")
            }
        }
    }

    private func planColor(for app: ManagedApp, now: Date) -> Color {
        guard app.scheduleEnabled else { return .gray }
        guard let expiry = app.signatureExpiresAt else { return .gray }
        if expiry <= now { return .red }
        if expiry <= now.addingTimeInterval(Double(refreshLeadHours) * 3_600) { return .orange }
        return .green
    }

    private func chartEnd(now: Date) -> Date {
        let dates = apps.flatMap { [$0.signatureExpiresAt, $0.nextRun].compactMap { $0 } }
        let latest = dates.filter { $0 > now }.max() ?? now.addingTimeInterval(2 * 86_400)
        return max(latest.addingTimeInterval(12 * 3_600), now.addingTimeInterval(2 * 86_400))
    }

    private func bounded(_ date: Date, from start: Date, to end: Date) -> Date {
        min(max(date, start.addingTimeInterval(900)), end.addingTimeInterval(-900))
    }
}

private struct PlanLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case active = "正常"
    case expiring = "即将到期"
    case failed = "失败"
    case missing = "文件缺失"

    var id: String { rawValue }
}

struct AppsView: View {
    @EnvironmentObject private var model: ManagerViewModel
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var filter: AppFilter = .all
    @State private var pendingDelete: ManagedApp?

    private var filteredApps: [ManagedApp] {
        model.store.config.apps.filter { app in
            let matchesSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || app.name.localizedCaseInsensitiveContains(searchText)
                || (app.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .active: matchesFilter = ["安装成功", "后台刷新成功"].contains(app.status) && !app.signatureNeedsRefresh && !app.signatureIsNearExpiry(within: model.store.config.refreshLeadHours)
            case .expiring: matchesFilter = app.signatureNeedsRefresh || app.signatureIsNearExpiry(within: model.store.config.refreshLeadHours)
            case .failed: matchesFilter = ["安装失败", "后台刷新失败"].contains(app.status)
            case .missing: matchesFilter = app.status == "文件不存在" || !FileManager.default.fileExists(atPath: app.ipaPath)
            }
            return matchesSearch && matchesFilter
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("应用管理").font(.title.bold())
                Spacer()
                Picker("筛选", selection: $filter) {
                    ForEach(AppFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Button("添加 IPA") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            List {
                ForEach(filteredApps) { app in
                    AppRow(app: app)
                }
                .onDelete { indexSet in
                    for index in indexSet where filteredApps.indices.contains(index) {
                        pendingDelete = filteredApps[index]
                    }
                }
            }
            .overlay {
                if filteredApps.isEmpty {
                    ContentUnavailableView(searchText.isEmpty ? "没有匹配的应用" : "没有找到匹配应用", systemImage: "magnifyingglass")
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索名称或 Bundle ID")
        .confirmationDialog(
            "确认删除托管记录？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { app in
            Button("删除 \(app.name)", role: .destructive) {
                model.remove(app)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { app in
            Text("这会移除管理器中的托管记录，不会自动卸载手机上的应用。归档 IPA 文件会保留。")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls where url.pathExtension.lowercased() == "ipa" { model.addIPA(url) }
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject private var model: ManagerViewModel
    let app: ManagedApp

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: app.iconPath)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).fontWeight(.medium)
                if let bundleIdentifier = app.bundleIdentifier {
                    Text(bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                }
                Text(app.ipaPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(app.status).font(.caption2).foregroundStyle(app.status.hasSuffix("成功") ? .green : .secondary)
                if let backgroundRun = app.lastBackgroundRun, let result = app.backgroundRefreshResult {
                    Text("后台刷新：\(result) · \(backgroundRun.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(result == "成功" ? .green : .red)
                }
                SignatureBadge(app: app)
            }
            Spacer()
            Toggle("定时", isOn: Binding(
                get: { app.scheduleEnabled },
                set: { value in
                    guard let index = model.store.config.apps.firstIndex(where: { $0.id == app.id }) else { return }
                    model.store.config.apps[index].scheduleEnabled = value
                    model.syncBackgroundRefresh()
                }
            ))
            .toggleStyle(.switch)
            Button(model.isBusy ? "处理中…" : "立即安装") { Task { await model.install(app) } }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
        }
        .padding(.vertical, 6)
    }
}

struct AppIconView: View {
    let path: String?

    private var loadedImage: NSImage? {
        guard let path,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let image = NSImage(data: data)
        image?.isTemplate = false
        return image
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: "app.dashed")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SignatureBadge: View {
    let app: ManagedApp

    var body: some View {
        Text(app.signatureStatusText)
            .font(.caption)
            .foregroundStyle(app.signatureNeedsRefresh ? .red : (app.signatureIsNearExpiry() ? .orange : .secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (app.signatureNeedsRefresh ? Color.red : (app.signatureIsNearExpiry() ? Color.orange : Color.secondary))
                    .opacity(0.12),
                in: Capsule()
            )
    }
}

struct DevicesView: View {
    @EnvironmentObject private var model: ManagerViewModel
    @State private var pendingUninstall: InstalledApp?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("设备").font(.title.bold())
                Spacer()
                Button("重新扫描") { Task { await model.refreshStatus() } }
                Button("读取已安装应用") { Task { await model.refreshInstalledApps() } }
            }
            .padding()

            if model.devices.isEmpty {
                ContentUnavailableView("没有检测到 iPhone", systemImage: "iphone.slash")
            } else {
                List {
                    Section("已连接设备（按 UDID 去重）") {
                        ForEach(model.devices) { device in
                            HStack {
                                Image(systemName: device.connection == "usb" ? "cable.connector" : "wifi")
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text([device.displayModelName, device.osVersion.map { "iOS \($0)" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(device.id) · \(device.lockState)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(device.connection.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                                    Image(systemName: device.lockState == "已解锁" ? "lock.open" : "lock")
                                        .foregroundStyle(device.lockState == "已解锁" ? .green : .orange)
                                }
                            }
                        }
                    }

                    Section("手机自签应用（\(model.installedApps.count)）") {
                        if model.freeProfileLimitReached {
                            Text("免费开发者账号已达到 3 个应用上限；卸载应用可释放名额。")
                                .foregroundStyle(.orange)
                        }
                        if let error = model.installedAppsError {
                            Text(error).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.installedApps) { app in
                                HStack {
                                    AppIconView(path: app.iconPath)
                                        .frame(width: 36, height: 36)
                                    VStack(alignment: .leading) {
                                        Text(app.name)
                                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let version = app.version { Text(version).font(.caption).foregroundStyle(.secondary) }
                                    if model.managedApp(for: app) != nil {
                                        Button("刷新") { Task { await model.refreshInstalledApp(app) } }
                                            .buttonStyle(.borderedProminent)
                                    } else {
                                        Button("导入 IPA") { model.selectedTab = 1 }
                                            .buttonStyle(.bordered)
                                    }
                                    Button("卸载", role: .destructive) {
                                        pendingUninstall = app
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isBusy)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "确认从 iPhone 卸载？",
            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }),
            presenting: pendingUninstall
        ) { app in
            Button("卸载 \(app.name)", role: .destructive) {
                pendingUninstall = nil
                Task { await model.removeInstalledApp(app) }
            }
            Button("取消", role: .cancel) { pendingUninstall = nil }
        } message: { app in
            Text("这会从已连接的 iPhone 删除 \(app.name)，应用数据也可能一并移除。管理器中的 IPA 归档不会删除。")
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: ManagerViewModel
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("运行日志").font(.title.bold())
                Spacer()
                Button("清空") { model.logs.removeAll() }
            }
            .padding()
            ScrollView {
                Text(model.logs.joined(separator: "\n\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: ManagerViewModel
    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录 macOS 时自动启动", isOn: Binding(
                    get: { model.store.config.launchAtLoginEnabled },
                    set: { value in
                        model.store.config.launchAtLoginEnabled = value
                        model.syncStartup()
                    }
                ))
                Text("关闭后，应用不会在登录 macOS 时自动打开；后台刷新开关不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("插入 USB iPhone 时自动打开", isOn: Binding(
                    get: { model.store.config.autoOpenOnUSBEnabled },
                    set: { value in
                        model.store.config.autoOpenOnUSBEnabled = value
                        model.syncUSBMonitor()
                    }
                ))
                Text("开启后，macOS 会在检测到 USB 连接的 iPhone 时自动打开管理器；同一次连接只打开一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("定时刷新") {
                Stepper("检查间隔：\(model.store.config.refreshIntervalHours) 小时", value: $model.store.config.refreshIntervalHours, in: 1...168)
                    .onChange(of: model.store.config.refreshIntervalHours) { _, _ in model.syncBackgroundRefresh() }
                Stepper("预计签名有效期：\(model.store.config.signatureLifetimeDays) 天", value: $model.store.config.signatureLifetimeDays, in: 1...365)
                    .onChange(of: model.store.config.signatureLifetimeDays) { _, _ in model.rescheduleManagedApps() }
                Stepper("提前提醒：\(model.store.config.refreshLeadHours) 小时", value: $model.store.config.refreshLeadHours, in: 1...168)
                    .onChange(of: model.store.config.refreshLeadHours) { _, _ in model.rescheduleManagedApps() }
                Toggle("启用后台刷新", isOn: Binding(
                    get: { model.store.config.backgroundRefreshEnabled },
                    set: { value in
                        model.store.config.backgroundRefreshEnabled = value
                        model.syncBackgroundRefresh()
                    }
                ))
                Text("每次成功安装后，工具会记录预计到期时间，并在提前提醒窗口内标记为即将到期。启用后台刷新后，macOS 会按设定间隔检查计划，只重新签名已到执行时间的 IPA。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("匹配开发者 Profile 到期时间") {
                    Task { await model.refreshSignatureExpiry() }
                }
                .disabled(model.isBusy)
                Text("按 Bundle ID 匹配账号中最新到期的 Apple Developer profile。它不读取手机内的 embedded profile；匹配不到时保留预计时间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("失败重试") {
                Stepper("最多重试：\(model.store.config.maxRetryCount) 次", value: $model.store.config.maxRetryCount, in: 1...5)
                    .onChange(of: model.store.config.maxRetryCount) { _, _ in model.syncBackgroundRefresh() }
                Stepper("重试间隔：\(model.store.config.retryDelaySeconds) 秒", value: $model.store.config.retryDelaySeconds, in: 3...60, step: 1)
                    .onChange(of: model.store.config.retryDelaySeconds) { _, _ in model.syncBackgroundRefresh() }
                Text("安装或后台刷新失败时会自动重试；全部失败后会保留失败状态并写入运行日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("账号") {
                Text(model.authStatus).font(.system(.caption, design: .monospaced))
                Button("刷新登录状态") { Task { await model.refreshStatus() } }
            }
            Section("工具") {
                Text("底层工具：\(XToolLocator.displayPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("修复版 xtool 会隔离 GrandSlam 网络会话，并在安全的事务边界处理 HTML/5xx 临时响应。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - App entry point

@main
struct SideloadManagerApp: App {
    @StateObject private var model = ManagerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("自签管理", systemImage: model.devices.isEmpty ? "iphone.slash" : "iphone") {
            Text(model.devices.isEmpty ? "未检测到 iPhone" : "设备：\(model.devices.first?.name ?? "iPhone")")
            if let device = model.devices.first {
                Text("\(device.connection.uppercased()) · \(device.lockState)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("刷新设备和签名状态") {
                Task { await model.refreshStatus() }
            }
            .disabled(model.isBusy)
            Button("打开管理器") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新设备和账号") { Task { await model.refreshStatus() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
