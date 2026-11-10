import CoreGraphics

/// Window layouts, in the spirit of Rectangle's WindowCalculation (MIT, © Ryan Hanson).
enum SnapAction: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, almostMaximize, center
    case nextDisplay, previousDisplay

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        }
    }

    var movesAcrossDisplays: Bool { self == .nextDisplay || self == .previousDisplay }
}

/// Pure frame math in a top-left-origin coordinate space (the one Accessibility uses), so it can be
/// unit-tested without screens or windows. `area` is the usable screen area (visible frame).
enum SnapGeometry {
    static func frame(_ action: SnapAction, window: CGRect, area: CGRect, gap: CGFloat = 0) -> CGRect {
        let raw: CGRect
        switch action {
        case .leftHalf: raw = column(area, 0, of: 2)
        case .rightHalf: raw = column(area, 1, of: 2)
        case .topHalf: raw = row(area, 0, of: 2)
        case .bottomHalf: raw = row(area, 1, of: 2)
        case .firstThird: raw = thirds(area, 0, span: 1)
        case .centerThird: raw = thirds(area, 1, span: 1)
        case .lastThird: raw = thirds(area, 2, span: 1)
        case .firstTwoThirds: raw = thirds(area, 0, span: 2)
        case .lastTwoThirds: raw = thirds(area, 1, span: 2)
        case .topLeft: raw = quarter(area, column: 0, row: 0)
        case .topRight: raw = quarter(area, column: 1, row: 0)
        case .bottomLeft: raw = quarter(area, column: 0, row: 1)
        case .bottomRight: raw = quarter(area, column: 1, row: 1)
        case .maximize: raw = area
        case .almostMaximize: raw = area.insetBy(dx: area.width * 0.05, dy: area.height * 0.05)
        case .center: return centered(window.size, in: area)
        case .nextDisplay, .previousDisplay: return window
        }
        return applyGap(raw, area: area, gap: gap)
    }

    /// Keeps the window's position and size relative to its display when moving to another one.
    static func move(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let width = min(target.width, window.width * scaleX)
        let height = min(target.height, window.height * scaleY)
        let x = target.minX + (window.minX - source.minX) * scaleX
        let y = target.minY + (window.minY - source.minY) * scaleY
        return CGRect(x: min(max(target.minX, x), target.maxX - width), y: min(max(target.minY, y), target.maxY - height),
                      width: width, height: height)
    }

    /// Which half/quarter/maximize a drag to `point` near the edges of `area` asks for, if any.
    static func dragTarget(_ point: CGPoint, area: CGRect, margin: CGFloat = 6, corner: CGFloat = 60) -> SnapAction? {
        let nearLeft = point.x <= area.minX + margin
        let nearRight = point.x >= area.maxX - margin
        let nearTop = point.y <= area.minY + margin
        let nearBottom = point.y >= area.maxY - margin
        let inTopBand = point.y <= area.minY + corner
        let inBottomBand = point.y >= area.maxY - corner
        if nearLeft { return inTopBand ? .topLeft : inBottomBand ? .bottomLeft : .leftHalf }
        if nearRight { return inTopBand ? .topRight : inBottomBand ? .bottomRight : .rightHalf }
        if nearTop { return .maximize }
        if nearBottom { return point.x < area.midX ? .bottomLeft : .bottomRight }
        return nil
    }

    private static func column(_ area: CGRect, _ index: Int, of count: Int) -> CGRect {
        let width = area.width / CGFloat(count)
        return CGRect(x: area.minX + width * CGFloat(index), y: area.minY, width: width, height: area.height)
    }

    private static func row(_ area: CGRect, _ index: Int, of count: Int) -> CGRect {
        let height = area.height / CGFloat(count)
        return CGRect(x: area.minX, y: area.minY + height * CGFloat(index), width: area.width, height: height)
    }

    /// Thirds run along the long side of the screen (columns on landscape, rows on portrait), like Rectangle.
    private static func thirds(_ area: CGRect, _ index: Int, span: Int) -> CGRect {
        guard area.width >= area.height else {
            let height = area.height / 3
            return CGRect(x: area.minX, y: area.minY + height * CGFloat(index), width: area.width, height: height * CGFloat(span))
        }
        let width = area.width / 3
        return CGRect(x: area.minX + width * CGFloat(index), y: area.minY, width: width * CGFloat(span), height: area.height)
    }

    private static func quarter(_ area: CGRect, column: Int, row: Int) -> CGRect {
        CGRect(x: area.minX + area.width / 2 * CGFloat(column), y: area.minY + area.height / 2 * CGFloat(row),
               width: area.width / 2, height: area.height / 2)
    }

    private static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// Gaps between windows and screen edges: full gap on outer edges, half on edges shared with a neighbour.
    private static func applyGap(_ rect: CGRect, area: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return rect }
        let left = rect.minX <= area.minX + 0.5 ? gap : gap / 2
        let right = rect.maxX >= area.maxX - 0.5 ? gap : gap / 2
        let top = rect.minY <= area.minY + 0.5 ? gap : gap / 2
        let bottom = rect.maxY >= area.maxY - 0.5 ? gap : gap / 2
        return CGRect(x: rect.minX + left, y: rect.minY + top, width: rect.width - left - right, height: rect.height - top - bottom)
    }
}
