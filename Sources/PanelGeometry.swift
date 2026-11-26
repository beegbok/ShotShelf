import CoreGraphics

enum PanelGeometry {
    /// Grow or shrink downward so the top edge, where the count control sits, stays under the pointer.
    static func resized(keepingTopOf frame: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: frame.origin.x, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    static func placed(anchor: CGRect, size: CGSize, visible: CGRect, blockers: [CGRect]) -> CGRect {
        let proposed = CGRect(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - size.height - 6,
            width: size.width,
            height: size.height
        )
        let fitted = clamp(proposed, to: visible)
        return cleared(fitted, blockers: blockers, visible: visible, anchorMidX: anchor.midX)
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var frame = frame
        let maxWidth = max(visible.width - 16, 1)
        if frame.width > maxWidth { frame.size.width = maxWidth }
        frame.origin.x = pin(frame.origin.x, min: visible.minX + 8, max: visible.maxX - frame.width - 8)
        frame.origin.y = pin(frame.origin.y, min: visible.minY + 8, max: visible.maxY - frame.height - 8)
        return frame
    }

    static func cleared(_ frame: CGRect, blockers: [CGRect], visible: CGRect, anchorMidX: CGFloat) -> CGRect {
        var frame = frame
        for _ in 0..<6 {
            let padded = frame.insetBy(dx: -8, dy: -8)
            guard let blocker = blockers.first(where: { $0.intersects(padded) }) else { return frame }
            let options = shifts(of: frame, awayFrom: blocker)
                .map { clamp($0, to: visible) }
                .filter { candidate in
                    !blockers.contains { $0.intersects(candidate.insetBy(dx: -8, dy: -8)) }
                }
            guard let best = options.min(by: { abs($0.midX - anchorMidX) < abs($1.midX - anchorMidX) }) else {
                return frame
            }
            frame = best
        }
        return frame
    }

    private static func shifts(of frame: CGRect, awayFrom blocker: CGRect) -> [CGRect] {
        let gap: CGFloat = 12
        return [
            CGRect(x: blocker.minX - frame.width - gap, y: frame.minY, width: frame.width, height: frame.height),
            CGRect(x: blocker.maxX + gap, y: frame.minY, width: frame.width, height: frame.height),
        ]
    }

    private static func pin(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
