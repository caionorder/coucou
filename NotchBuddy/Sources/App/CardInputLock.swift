import Foundation

/// A short moment during which a card that took the place of another card ignores clicks, so a click aimed
/// at the previous card cannot approve or answer the new one. Compiled in every build (the cmux queue has its
/// own lock for promoted cards, in CmuxRouting). It only ignores input: it never answers anything by itself.
enum CardInputLock {
    static let delay: TimeInterval = 0.7

    /// True when an approval or a question is on screen. The fd is live for a real card; a demo card has none.
    static func cardVisible(approvalFD: Int32, questionFD: Int32, approvalShown: Bool, questionShown: Bool) -> Bool {
        approvalFD >= 0 || questionFD >= 0 || approvalShown || questionShown
    }

    /// When the lock starts for a card that is being shown. nil on an empty screen: no delay in the normal case.
    static func armedAt(cardWasVisible: Bool, now: TimeInterval) -> TimeInterval? {
        cardWasVisible ? now : nil
    }

    static func isLocked(armedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = armedAt else { return false }
        return now >= at && now - at < delay
    }
}
