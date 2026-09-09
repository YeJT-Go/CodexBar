import Foundation
import XCTest

final class InfoPlistTests: XCTestCase {
    func testInfoPlistMakesAppAgentOnly() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appending(path: "Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "CodexBar")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "local.codexbar.app")
        XCTAssertEqual(plist["CFBundleName"] as? String, "CodexBar")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.1.0")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "CodexBar.icns")

        let iconURL = projectRoot.appending(path: "Resources/CodexBar.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))
    }
}
