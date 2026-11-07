import Foundation
import ApplicationServices

// axenabled <pid> <substring> — print role/desc/title/identifier and AXEnabled for every element whose
// description, title or identifier contains the substring (walks the app's windows).
let pid = pid_t(CommandLine.arguments[1])!
let needle = CommandLine.arguments[2...].joined(separator: " ").lowercased()
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1.5)
func a(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func s(_ e: AXUIElement, _ n: String) -> String { (a(e, n) as? String) ?? ((a(e, n) as? NSNumber)?.stringValue ?? "") }
var found = 0
func walk(_ e: AXUIElement, _ d: Int) {
    if d > 60 { return }
    let desc = s(e, kAXDescriptionAttribute), title = s(e, kAXTitleAttribute), ident = s(e, kAXIdentifierAttribute)
    if (desc + " " + title + " " + ident).lowercased().contains(needle) {
        let en = a(e, kAXEnabledAttribute).map { "\($0)" } ?? "n/a"
        print("\(s(e, kAXRoleAttribute)) desc=\"\(desc)\" title=\"\(title)\" id=\(ident) enabled=\(en)")
        found += 1
    }
    if let c = a(e, kAXChildrenAttribute) as? [AXUIElement] { for x in c { walk(x, d + 1) } }
}
var roots: [AXUIElement] = (a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
if roots.isEmpty, let c = a(app, kAXChildrenAttribute) as? [AXUIElement] { roots = c }
for w in roots { walk(w, 0) }
if found == 0 { print("NOT FOUND: \(needle)"); exit(3) }
