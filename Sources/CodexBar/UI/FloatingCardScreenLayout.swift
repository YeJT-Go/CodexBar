import Foundation

/// Screen geometry in AppKit's global logical-point coordinate space.
struct FloatingScreen: Equatable, Sendable {
    let id: Int
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
}

enum FloatingCardScreenLayout {
    static func screen(at point: CGPoint, in screens: [FloatingScreen]) -> FloatingScreen? {
        screens.first { contains(point, in: $0.frame) }
    }

    static func isInRightEdge(_ point: CGPoint, of screen: FloatingScreen, width: CGFloat = 2) -> Bool {
        contains(point, in: screen.frame) && point.x >= screen.frame.maxX - width
    }

    static func panelOrigin(size: CGSize, screen: FloatingScreen, trailingInset: CGFloat = 12) -> CGPoint {
        let visible = screen.visibleFrame
        let maximumX = max(visible.minX, visible.maxX - size.width)
        let maximumY = max(visible.minY, visible.maxY - size.height)
        let x = max(visible.minX, visible.maxX - trailingInset - size.width)
        let y = min(max(visible.minY, visible.midY - size.height / 2), maximumY)
        let scale = screen.scale > 0 ? screen.scale : 1

        // Clamp again after rounding so fractional screen bounds remain respected.
        return CGPoint(
            x: min(max(visible.minX, (x * scale).rounded() / scale), maximumX),
            y: min(max(visible.minY, (y * scale).rounded() / scale), maximumY)
        )
    }

    private static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        // Half-open bounds assign shared vertical/horizontal seams to the right/upper screen.
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y < frame.maxY
    }
}
