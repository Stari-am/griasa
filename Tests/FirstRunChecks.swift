import Foundation

// Checks for where the first-run card goes. Its whole job is to show somebody
// who just installed Griasa where the app went, so it must point at the icon
// when the icon can be seen, and must not point at anything when it can't.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runFirstRunChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

// A 1512×982 laptop screen; the menu bar is the top 33 points.
let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
let notch = CGRect(x: 662, y: 949, width: 188, height: 33)
let card = CGSize(width: 340, height: 230)
func item(at x: CGFloat) -> CGRect { CGRect(x: x, y: 949, width: 26, height: 33) }

let middle = FirstRunPlacement.place(item: item(at: 1100), screen: screen, notch: notch, card: card)
check(middle.arrowX != nil && abs(middle.origin.x + middle.arrowX! - 1113) < 0.5,
      rule: "the arrow points at the middle of the icon",
      meaning: "a card that points beside the icon sends people to the wrong item in a crowded menu bar",
      saw: "origin \(middle.origin), arrow \(String(describing: middle.arrowX))")
check(abs(middle.origin.y + card.height - (949 - FirstRunPlacement.gap)) < 0.5,
      rule: "the card hangs just under the menu bar",
      meaning: "a card lower down no longer reads as belonging to the icon above it",
      saw: "top edge at \(middle.origin.y + card.height)")

let edge = FirstRunPlacement.place(item: item(at: 1490), screen: screen, notch: notch, card: card)
check(edge.origin.x + card.width <= screen.maxX - FirstRunPlacement.margin + 0.5,
      rule: "an icon at the right edge keeps the card on screen",
      meaning: "the rightmost slot is where a newly installed item usually lands, and a card cut off by the edge hides its own buttons",
      saw: "card right edge \(edge.origin.x + card.width)")
check(edge.arrowX.map { abs(edge.origin.x + $0 - 1503) < 0.5 || $0 == card.width - FirstRunPlacement.arrowInset } ?? false,
      rule: "the arrow still points at the icon when the card is pushed sideways",
      meaning: "centring the arrow on the card would point at a neighbour's icon",
      saw: "arrow \(String(describing: edge.arrowX)) in card at \(edge.origin.x)")

let hidden = FirstRunPlacement.place(item: item(at: 700), screen: screen, notch: notch, card: card)
check(hidden.iconHidden && hidden.arrowX == nil,
      rule: "an icon behind the notch is reported as hidden, with no arrow",
      meaning: "this is the commonest reason people cannot find the app; pointing at the camera explains nothing",
      saw: "hidden \(hidden.iconHidden), arrow \(String(describing: hidden.arrowX))")

let missing = FirstRunPlacement.place(item: nil, screen: screen, notch: notch, card: card)
check(missing.arrowX == nil && !missing.iconHidden
        && missing.origin.x + card.width <= screen.maxX && missing.origin.y + card.height <= screen.maxY,
      rule: "with no icon found, the card sits in the top-right corner without an arrow",
      meaning: "the hint must still appear — it is the only sign the app opened at all",
      saw: "origin \(missing.origin), arrow \(String(describing: missing.arrowX))")

let offscreen = FirstRunPlacement.place(item: item(at: -300), screen: screen, notch: nil, card: card)
check(offscreen.arrowX == nil,
      rule: "an icon laid out off screen gets no arrow",
      meaning: "macOS parks items it cannot fit outside the visible bar; an arrow clamped to the edge would point at something else",
      saw: "arrow \(String(describing: offscreen.arrowX))")

let noNotch = FirstRunPlacement.place(item: item(at: 700), screen: screen, notch: nil, card: card)
check(noNotch.arrowX != nil && !noNotch.iconHidden,
      rule: "on a screen without a notch the middle of the bar is an ordinary place",
      meaning: "external displays have no camera housing; calling an icon there hidden would be false",
      saw: "hidden \(noNotch.iconHidden), arrow \(String(describing: noNotch.arrowX))")

return failures
}
