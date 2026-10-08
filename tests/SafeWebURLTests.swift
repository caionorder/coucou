import Foundation

@main
enum SafeWebURLTests {
    static func main() {
        // Accepted: plain http/https URLs
        precondition(safeWebURL("https://example.com") != nil)
        precondition(safeWebURL("http://example.com/a?b=1") != nil)
        precondition(safeWebURL("HTTPS://EXAMPLE.COM") != nil)
        precondition(safeWebURL(" https://example.com \n") != nil)
        precondition(safeWebURL("http://localhost:5678") != nil)

        // Rejected: nil, empty, non-web schemes, malformed
        precondition(safeWebURL(nil) == nil)
        precondition(safeWebURL("") == nil)
        precondition(safeWebURL("file:///etc/hosts") == nil)
        precondition(safeWebURL("javascript:alert(1)") == nil)
        precondition(safeWebURL("vscode://file/etc/hosts") == nil)
        precondition(safeWebURL("smb://server/share") == nil)
        precondition(safeWebURL("mailto:a@b.c") == nil)
        precondition(safeWebURL("https://") == nil)
        precondition(safeWebURL("https:example.com") == nil)
        precondition(safeWebURL("//example.com") == nil)

        // Rejected: a user or a password in front of the host (the link reads as one site and goes to another)
        precondition(safeWebURL("https://apple.com@evil.example/login") == nil)
        precondition(safeWebURL("https://apple.com%2Flogin@evil.example/") == nil)
        precondition(safeWebURL("https://user:secret@example.com") == nil)
        precondition(safeWebURL("http://:pw@example.com") == nil)
        precondition(safeWebURL("https://@example.com") == nil)
        // Still accepted: an @ after the host is part of the path or the query
        precondition(safeWebURL("https://example.com/@user") != nil)
        precondition(safeWebURL("https://example.com/a?mail=a@b.c") != nil)

        print("Safe web links: 22 cases passed")
    }
}
