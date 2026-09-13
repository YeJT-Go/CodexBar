import AppKit
import Foundation
import XCTest

final class AppIconTests: XCTestCase {
    func testSourceArtworkFillsEveryCanvasCorner() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconData = try Data(
            contentsOf: projectRoot.appending(path: "Resources/CodexBarIcon-1024.png")
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: iconData))

        XCTAssertEqual(bitmap.pixelsWide, 1_024)
        XCTAssertEqual(bitmap.pixelsHigh, 1_024)

        let corners = [
            (0, 0),
            (bitmap.pixelsWide - 1, 0),
            (0, bitmap.pixelsHigh - 1),
            (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
        ]
        for (x, y) in corners {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        }
    }
}
