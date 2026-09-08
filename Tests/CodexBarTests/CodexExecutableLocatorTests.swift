import Foundation
import XCTest
@testable import CodexBar

final class CodexExecutableLocatorTests: XCTestCase {
    func testPrefersKnownAppleSiliconHomebrewPath() throws {
        let locator = CodexExecutableLocator(
            path: "/custom/bin",
            isExecutable: { $0 == "/opt/homebrew/bin/codex" || $0 == "/custom/bin/codex" }
        )

        XCTAssertEqual(try locator.locate().path, "/opt/homebrew/bin/codex")
    }

    func testUsesFirstExecutableAbsoluteDirectoryFromPATH() throws {
        let locator = CodexExecutableLocator(
            path: "relative:/first/bin:/second/bin",
            isExecutable: { $0 == "/second/bin/codex" }
        )

        XCTAssertEqual(try locator.locate().path, "/second/bin/codex")
    }

    func testFallsBackToIntelHomebrewPath() throws {
        let locator = CodexExecutableLocator(
            path: "",
            isExecutable: { $0 == "/usr/local/bin/codex" }
        )

        XCTAssertEqual(try locator.locate().path, "/usr/local/bin/codex")
    }

    func testThrowsWhenNoExecutableCanBeFound() {
        let locator = CodexExecutableLocator(path: "", isExecutable: { _ in false })

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? CodexClientError, .executableNotFound)
        }
    }
}
