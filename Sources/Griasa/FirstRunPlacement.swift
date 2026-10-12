import Foundation
import CoreGraphics

/// Where the first-run hint goes, worked out from where the menu-bar icon is.
///
/// People install Griasa, open it, and find nothing: there is no Dock icon and
/// no window, only an item in a menu bar that is often already full. So the
/// first thing the app shows is a small card hanging under its own icon, with
/// an arrow at it. When there is no icon to point at — the status item was not
/// found, or macOS put it behind the camera notch because the bar ran out of
/// room — the card goes to the top-right corner without an arrow and says why
/// the icon cannot be seen, instead of pointing at nothing.
///
/// Geometry only, in AppKit's screen coordinates (origin bottom-left), so the
/// rules can be checked without a screen.
enum FirstRunPlacement {
    struct Result: Equatable {
        /// Bottom-left corner of the card.
        var origin: CGPoint
        /// Horizontal position of the arrow tip inside the card; nil = no arrow.
        var arrowX: CGFloat?
        /// The icon exists but cannot be seen: hidden behind the notch.
        var iconHidden: Bool
    }

    /// Distance from screen edges.
    static let margin: CGFloat = 8
    /// Space between the bottom of the menu bar and the arrow tip.
    static let gap: CGFloat = 4
    /// The arrow keeps this far from the card's rounded corners.
    static let arrowInset: CGFloat = 22

    /// - Parameters:
    ///   - item: the status item's frame, nil when it could not be found.
    ///   - screen: the screen's visible frame (below the menu bar).
    ///   - notch: the part of the menu bar the camera housing covers, if any.
    ///   - card: the card's size, arrow included.
    static func place(item: CGRect?, screen: CGRect, notch: CGRect?, card: CGSize) -> Result {
        let corner = CGPoint(x: screen.maxX - card.width - margin,
                             y: screen.maxY - card.height - margin)
        // An item macOS could not fit is still laid out, just where nobody can
        // see it — behind the notch, or past the edge of the screen.
        guard let item, item.width > 0,
              item.midX > screen.minX, item.midX < screen.maxX else {
            return Result(origin: corner, arrowX: nil, iconHidden: false)
        }
        if let notch, notch.width > 0, item.midX >= notch.minX, item.midX <= notch.maxX {
            return Result(origin: corner, arrowX: nil, iconHidden: true)
        }
        let lowest = screen.minX + margin
        let highest = screen.maxX - card.width - margin
        let x = min(max(item.midX - card.width / 2, lowest), max(lowest, highest))
        let y = min(item.minY, screen.maxY) - gap - card.height
        let arrow = min(max(item.midX - x, arrowInset), card.width - arrowInset)
        return Result(origin: CGPoint(x: x, y: y), arrowX: arrow, iconHidden: false)
    }
}
