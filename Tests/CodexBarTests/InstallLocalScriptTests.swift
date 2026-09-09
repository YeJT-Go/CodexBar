import Foundation
import XCTest

final class InstallLocalScriptTests: XCTestCase {
    func testCanonicalizesHomeContainingDotDotAndReplacesApp() throws {
        let fixture = try Fixture()
        let nested = fixture.home.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let result = try fixture.run(home: nested.appending(path: "..").path)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        let openedPath = try XCTUnwrap(fixture.openedPath())
        XCTAssertTrue(openedPath.hasPrefix("/"))
        XCTAssertTrue(openedPath.hasSuffix("/home/Applications/CodexBar.app"))
        XCTAssertFalse(openedPath.contains("/../"))
    }

    func testRejectsRelativeHomeWithoutOpeningApp() throws {
        let fixture = try Fixture()

        let result = try fixture.run(home: "relative/../home")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        XCTAssertNil(try fixture.openedPath())
    }

    func testDittoFailureKeepsOldAppAndDoesNotOpen() throws {
        let fixture = try Fixture()

        let result = try fixture.run(home: fixture.home.path, failing: "ditto")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        XCTAssertNil(try fixture.openedPath())
    }

    func testCodesignFailureKeepsOldAppAndDoesNotOpen() throws {
        let fixture = try Fixture()

        let result = try fixture.run(home: fixture.home.path, failing: "codesign")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        XCTAssertNil(try fixture.openedPath())
    }

    func testMoveFailureRestoresOldAppAndDoesNotOpen() throws {
        let fixture = try Fixture()

        let result = try fixture.run(home: fixture.home.path, failing: "activate-mv")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "new.txt").path))
        XCTAssertNil(try fixture.openedPath())
    }

    func testBackupCleanupFailureKeepsActivatedAppAndOpensOnce() throws {
        let fixture = try Fixture()

        let result = try fixture.run(home: fixture.home.path, failing: "backup-rm")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        XCTAssertEqual(try fixture.openedPaths().count, 1)
        XCTAssertTrue(try fixture.backupContainsOldApp())
    }

    func testInterruptAfterBackupMoveRestoresOldAppAndDoesNotOpen() throws {
        let fixture = try Fixture()

        let result = try fixture.run(home: fixture.home.path, interruptAfterBackupMove: true)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "new.txt").path))
        XCTAssertNil(try fixture.openedPath())
    }
}

private struct InstallerResult {
    let status: Int32
    let stderr: String
}

private final class Fixture {
    let root: URL
    let home: URL
    let destination: URL
    private let source: URL
    private let fakeBin: URL
    private let state: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "CodexBarInstallTests-\(UUID().uuidString)")
        home = root.appending(path: "home")
        destination = home.appending(path: "Applications/CodexBar.app")
        source = root.appending(path: "source/CodexBar.app")
        fakeBin = root.appending(path: "bin")
        state = root.appending(path: "state")

        try FileManager.default.createDirectory(
            at: destination.appending(path: "Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: destination.appending(path: "old.txt"))

        try FileManager.default.createDirectory(
            at: source.appending(path: "Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let executable = source.appending(path: "Contents/MacOS/CodexBar")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>CodexBar</string></dict></plist>
        """.utf8).write(to: source.appending(path: "Contents/Info.plist"))
        try Data("new".utf8).write(to: source.appending(path: "new.txt"))

        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try writeFakeCommands()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func run(home: String, failing: String = "", interruptAfterBackupMove: Bool = false) throws -> InstallerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.projectRoot.appending(path: "scripts/install-local.sh").path]
        process.environment = [
            "HOME": home,
            "PATH": "\(fakeBin.path):/usr/bin:/bin",
            "CODEXBAR_SOURCE_APP": source.path,
            "CODEXBAR_TEST_FAIL": failing,
            "CODEXBAR_TEST_STATE": state.path,
            "CODEXBAR_INSTALL_HOOK": interruptAfterBackupMove ? fakeBin.appending(path: "hook").path : "",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return InstallerResult(status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
    }

    func openedPath() throws -> String? {
        let log = state.appending(path: "opened")
        guard FileManager.default.fileExists(atPath: log.path) else { return nil }
        return try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openedPaths() throws -> [String] {
        guard let contents = try openedPath() else { return [] }
        return contents.split(separator: "\n").map(String.init)
    }

    func backupContainsOldApp() throws -> Bool {
        let applications = home.appending(path: "Applications")
        let entries = try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
        return entries.contains { entry in
            entry.lastPathComponent.hasPrefix(".CodexBar.backup.") &&
                FileManager.default.fileExists(atPath: entry.appending(path: "CodexBar.app/old.txt").path)
        }
    }

    private func writeFakeCommands() throws {
        try writeCommand(name: "ditto", body: """
        if [[ "$CODEXBAR_TEST_FAIL" == "ditto" ]]; then exit 41; fi
        exec /usr/bin/ditto "$@"
        """)
        try writeCommand(name: "codesign", body: """
        if [[ "$CODEXBAR_TEST_FAIL" == "codesign" ]]; then exit 42; fi
        exit 0
        """)
        try writeCommand(name: "mv", body: """
        count_file="$CODEXBAR_TEST_STATE/mv-count"
        count=0
        if [[ -f "$count_file" ]]; then read -r count < "$count_file"; fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$count_file"
        if [[ "$CODEXBAR_TEST_FAIL" == "activate-mv" && "$count" -eq 2 ]]; then exit 43; fi
        exec /bin/mv "$@"
        """)
        try writeCommand(name: "open", body: """
        printf '%s\n' "$1" >> "$CODEXBAR_TEST_STATE/opened"
        exit 0
        """)
        try writeCommand(name: "rm", body: """
        last=""
        for argument in "$@"; do last="$argument"; done
        if [[ "$CODEXBAR_TEST_FAIL" == "backup-rm" && "$last" == */.CodexBar.backup.* ]]; then exit 44; fi
        exec /bin/rm "$@"
        """)
        try writeCommand(name: "hook", body: """
        if [[ "$1" == "after-backup-move" ]]; then kill -TERM "$2"; fi
        exit 0
        """)
    }

    private func writeCommand(name: String, body: String) throws {
        let url = fakeBin.appending(path: name)
        try Data("#!/bin/bash\nset -euo pipefail\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
