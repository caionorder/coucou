import Foundation

@main
enum CardInputLockTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("CardInputLock.armedAt")
        check("lock window is 700 ms", CardInputLock.delay == 0.7)
        check("card shown on an empty screen → not locked",
              CardInputLock.armedAt(cardWasVisible: false, now: 100) == nil)
        check("card replaces a visible card → locked from now",
              CardInputLock.armedAt(cardWasVisible: true, now: 100) == 100)

        print("CardInputLock.isLocked")
        check("empty screen: never locked", !CardInputLock.isLocked(armedAt: nil, now: 100))
        let armed = CardInputLock.armedAt(cardWasVisible: true, now: 100)
        check("replaced card: locked at 0 ms", CardInputLock.isLocked(armedAt: armed, now: 100))
        check("replaced card: locked at 699 ms", CardInputLock.isLocked(armedAt: armed, now: 100.699))
        check("replaced card: free at 700 ms (lock expires)", !CardInputLock.isLocked(armedAt: armed, now: 100.7))
        check("replaced card: free long after", !CardInputLock.isLocked(armedAt: armed, now: 160))
        check("clock going backwards does not lock forever", !CardInputLock.isLocked(armedAt: armed, now: 99))

        print("CardInputLock.cardVisible")
        check("nothing on screen", !CardInputLock.cardVisible(approvalFD: -1, questionFD: -1, approvalShown: false, questionShown: false))
        check("real approval", CardInputLock.cardVisible(approvalFD: 7, questionFD: -1, approvalShown: true, questionShown: false))
        check("real question", CardInputLock.cardVisible(approvalFD: -1, questionFD: 9, approvalShown: false, questionShown: true))
        check("demo approval (no fd)", CardInputLock.cardVisible(approvalFD: -1, questionFD: -1, approvalShown: true, questionShown: false))
        check("demo question (no fd)", CardInputLock.cardVisible(approvalFD: -1, questionFD: -1, approvalShown: false, questionShown: true))

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("Card input lock: all cases passed")
    }
}
