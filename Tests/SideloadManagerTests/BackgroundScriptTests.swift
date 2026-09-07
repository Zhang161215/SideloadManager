import Foundation
import XCTest
@testable import SideloadManager

@MainActor
final class BackgroundScriptTests: XCTestCase {
    func testGeneratedScriptHasValidZshSyntaxAndSafeSignalTraps() throws {
        var config = ManagerConfig()
        config.apps = [
            ManagedApp(
                name: "Reader's Test",
                ipaPath: "/tmp/Reader's Test.ipa",
                bundleIdentifier: "com.example.reader",
                iconPath: nil,
                nextRun: Date(timeIntervalSince1970: 2_000_000_000)
            )
        ]

        let script = LaunchAgentManager().makeScript(config: config)
        XCTAssertTrue(script.contains("trap 'rm -f \"$LOCK_FILE\"' EXIT"))
        XCTAssertTrue(script.contains("trap 'exit 130' INT"))
        XCTAssertTrue(script.contains("trap 'exit 143' TERM"))
        XCTAssertTrue(script.contains("[[ -f \"$ENABLED\" ]] || exit 0"))

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sideload-manager-refresh-\(UUID().uuidString).zsh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", scriptURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: data, as: UTF8.self)
        )
    }
}
