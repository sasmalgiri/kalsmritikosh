import Foundation
import ApplicationServices
import AppKit

// axdrive — minimal Accessibility driver.
// Usage:
//   axdrive pid <pid> tree [maxDepth] [--all]      dump AX tree of the app's windows (and sheets)
//   axdrive pid <pid> find <substring>             print elements whose title/value/desc/id contains substring
//   axdrive pid <pid> press id <identifier>        AXPress element by identifier
//   axdrive pid <pid> press title <title>          AXPress element by exact title (or value for static text)
//   axdrive pid <pid> press frame x,y,w,h          AXPress element with that frame
//   axdrive pid <pid> action id <identifier> <AXAction>
//   axdrive pid <pid> setvalue id <identifier> <text>
//   axdrive pid <pid> focus id <identifier>
//   axdrive pid <pid> windows                      list windows with frames
//   axdrive pid <pid> menu <Top> <Item>            press a menu bar item
//   axdrive click x y                               left click at screen coords
//   axdrive type <text>                             type unicode text
//   axdrive key <combo>                             e.g. cmd+k  cmd+shift+g  return  escape  cmd+a  cmd+q  cmd+.  tab  down
//   axdrive scroll x y dy                           scroll wheel at point (dy lines, negative = down)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    let r = AXUIElementCopyAttributeValue(e, name as CFString, &v)
    if r == .apiDisabled || r == .notImplemented && name == kAXRoleAttribute {
        FileHandle.standardError.write("AX permission error: \(r.rawValue)\n".data(using: .utf8)!)
        exit(2)
    }
    return r == .success ? v : nil
}
let dbg = ProcessInfo.processInfo.environment["AXDBG"] != nil
func str(_ e: AXUIElement, _ name: String) -> String {
    if dbg { FileHandle.standardError.write("attr \(name)\n".data(using: .utf8)!) }
    guard let v = attr(e, name) else { return "" }
    if dbg { FileHandle.standardError.write("  type \(CFGetTypeID(v)) \(type(of: v)) \((v as? String) ?? "")\n".data(using: .utf8)!) }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let av = unsafeBitCast(v, to: AXValue.self)
        var p = CGPoint.zero; var sz = CGSize.zero; var rg = CFRange()
        if AXValueGetValue(av, .cgPoint, &p) { return "(\(I(p.x)),\(I(p.y)))" }
        if AXValueGetValue(av, .cgSize, &sz) { return "\(I(sz.width))x\(I(sz.height))" }
        if AXValueGetValue(av, .cfRange, &rg) { return "range(\(rg.location),\(rg.length))" }
        return "<axvalue>"
    }
    if let arr = v as? [AnyObject] { return "[\(arr.count) items]" }
    return "\(v)"
}
func I(_ d: CGFloat) -> String { d.isFinite && abs(d) < 1e9 ? String(Int(d)) : "nan" }
func frame(_ e: AXUIElement) -> CGRect {
    if dbg { FileHandle.standardError.write("frame\n".data(using: .utf8)!) }
    var p = CGPoint.zero; var s = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute) {
        if dbg { FileHandle.standardError.write("  pos type \(CFGetTypeID(pv)) axvalue=\(AXValueGetTypeID())\n".data(using: .utf8)!) }
        if CFGetTypeID(pv) == AXValueGetTypeID() {
            let av = unsafeBitCast(pv, to: AXValue.self)
            _ = AXValueGetValue(av, .cgPoint, &p)
        }
    }
    if let sv = attr(e, kAXSizeAttribute) {
        if dbg { FileHandle.standardError.write("  size type \(CFGetTypeID(sv))\n".data(using: .utf8)!) }
        if CFGetTypeID(sv) == AXValueGetTypeID() {
            let av = unsafeBitCast(sv, to: AXValue.self)
            _ = AXValueGetValue(av, .cgSize, &s)
        }
    }
    return CGRect(origin: p, size: s)
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    if let c = attr(e, kAXChildrenAttribute) as? [AXUIElement] { out += c }
    return out
}
func actions(_ e: AXUIElement) -> [String] {
    if dbg { FileHandle.standardError.write("actions\n".data(using: .utf8)!) }
    var a: CFArray?
    if AXUIElementCopyActionNames(e, &a) == .success, let arr = a as? [String] { return arr }
    return []
}
func describe(_ e: AXUIElement) -> String {
    let role = str(e, kAXRoleAttribute)
    let sub = str(e, kAXSubroleAttribute)
    let title = str(e, kAXTitleAttribute)
    let value = str(e, kAXValueAttribute)
    let desc = str(e, kAXDescriptionAttribute)
    let ident = str(e, kAXIdentifierAttribute)
    let help = str(e, kAXHelpAttribute)
    let f = frame(e)
    var s = role
    if !sub.isEmpty { s += "/\(sub)" }
    if !title.isEmpty { s += " title=\"\(title)\"" }
    if !value.isEmpty { s += " value=\"\(value.prefix(600))\"" }
    if !desc.isEmpty { s += " desc=\"\(desc)\"" }
    if !ident.isEmpty { s += " id=\(ident.hasPrefix("SwiftUI.") ? "<swiftui>" : ident)" }
    if !help.isEmpty { s += " help=\"\(help)\"" }
    s += " [\(I(f.origin.x)),\(I(f.origin.y)) \(I(f.width))x\(I(f.height))]"
    if dbg { FileHandle.standardError.write("acts-filter\n".data(using: .utf8)!) }
    let acts = actions(e).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" && !$0.hasPrefix("Name:") && !$0.hasPrefix("Target") && !$0.hasPrefix("Selector") }
    if !acts.isEmpty { s += " actions=\(acts.joined(separator: ","))" }
    return s
}
func walk(_ e: AXUIElement, depth: Int, maxDepth: Int, all: Bool, visit: (AXUIElement, Int) -> Void) {
    visit(e, depth)
    if depth >= maxDepth { return }
    for c in children(e) {
        if !all {
            let f = frame(c)
            let role = str(c, kAXRoleAttribute)
            if f.width == 0 && f.height == 0 && role != "AXMenu" && role != "AXMenuItem" && role != "AXSheet" && role != "AXWindow" && role != "AXGroup" { continue }
        }
        walk(c, depth: depth + 1, maxDepth: maxDepth, all: all, visit: visit)
    }
}
func roots(_ app: AXUIElement) -> [AXUIElement] {
    var r: [AXUIElement] = []
    if let ws = attr(app, kAXWindowsAttribute) as? [AXUIElement] { r += ws }
    if let fw = attr(app, kAXFocusedWindowAttribute) { let w = fw as! AXUIElement; if !r.contains(where: { CFEqual($0, w) }) { r.append(w) } }
    if r.isEmpty { r = children(app) }
    return r
}
func findAll(_ app: AXUIElement, maxDepth: Int = 60, pred: (AXUIElement) -> Bool) -> [AXUIElement] {
    var found: [AXUIElement] = []
    for w in roots(app) {
        walk(w, depth: 0, maxDepth: maxDepth, all: true) { e, _ in if pred(e) { found.append(e) } }
    }
    return found
}
func keyCode(_ name: String) -> CGKeyCode? {
    let map: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117]
    return map[name.lowercased()]
}
func sendKey(_ combo: String) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    var flags: CGEventFlags = []
    var key: String = ""
    for p in parts {
        switch p {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: key = p
        }
    }
    guard let kc = keyCode(key) else { FileHandle.standardError.write("unknown key \(key)\n".data(using: .utf8)!); exit(1) }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)!
    down.flags = flags; up.flags = flags
    down.post(tap: .cghidEventTap); usleep(30000); up.post(tap: .cghidEventTap); usleep(60000)
}
func typeText(_ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in text.unicodeScalars {
        var u = [UniChar](String(ch).utf16)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        down.post(tap: .cghidEventTap); usleep(8000); up.post(tap: .cghidEventTap); usleep(12000)
    }
}
func click(_ x: Double, _ y: Double, count: Int = 1) {
    let p = CGPoint(x: x, y: y)
    let src = CGEventSource(stateID: .hidSystemState)
    let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
    mv.post(tap: .cghidEventTap); usleep(80000)
    for i in 1...count {
        let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
        u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        d.post(tap: .cghidEventTap); usleep(40000); u.post(tap: .cghidEventTap); usleep(60000)
    }
}
func scroll(_ x: Double, _ y: Double, _ dy: Int32) {
    let p = CGPoint(x: x, y: y)
    let src = CGEventSource(stateID: .hidSystemState)
    let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
    mv.post(tap: .cghidEventTap); usleep(50000)
    let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
    ev.location = p
    ev.post(tap: .cghidEventTap); usleep(100000)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { print("usage: see source"); exit(1) }

alarm(20)
if !AXIsProcessTrusted() {
    FileHandle.standardError.write("AX permission error: process is not trusted for Accessibility\n".data(using: .utf8)!)
    exit(2)
}

switch args[0] {
case "front":
    if let a = NSWorkspace.shared.frontmostApplication { print("FRONT: \(a.localizedName ?? "?") pid=\(a.processIdentifier)") }
case "activate":
    if let a = NSRunningApplication(processIdentifier: pid_t(args[1])!) { a.activate(); usleep(400000); print("activated \(a.localizedName ?? "?")") }
    if let a = NSWorkspace.shared.frontmostApplication { print("FRONT: \(a.localizedName ?? "?") pid=\(a.processIdentifier)") }
case "click":
    click(Double(args[1])!, Double(args[2])!, count: args.count > 3 ? Int(args[3])! : 1)
case "type":
    typeText(args.dropFirst().joined(separator: " "))
case "typek":
    // type using real virtual key codes (US layout) so apps that read keyCode see the right key
    let text = args.dropFirst().joined(separator: " ")
    let shifted: [Character: String] = ["!":"1","@":"2","#":"3","$":"4","%":"5","^":"6","&":"7","*":"8","(":"9",")":"0","_":"-","+":"=","{":"[","}":"]","|":"\\",":":";","\"":"'","<":",",">":".","?":"/","~":"`"]
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in text {
        var base = String(ch).lowercased(); var shift = false
        if ch.isUppercase { shift = true }
        if let b = shifted[ch] { base = b; shift = true }
        if ch == " " { base = "space" }
        guard let kc = keyCode(base) else {
            var u = [UniChar](String(ch).utf16)
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!; d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!; up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            d.post(tap: .cghidEventTap); usleep(8000); up.post(tap: .cghidEventTap); usleep(12000); continue
        }
        let d = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)!
        let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)!
        if shift {
            let sd = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)!; sd.flags = .maskShift; sd.post(tap: .cghidEventTap); usleep(8000)
            d.flags = .maskShift; up.flags = .maskShift
        } else { d.flags = []; up.flags = [] }
        d.post(tap: .cghidEventTap); usleep(10000); up.post(tap: .cghidEventTap); usleep(10000)
        if shift {
            let su = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)!; su.flags = []; su.post(tap: .cghidEventTap); usleep(8000)
        }
    }
case "key":
    for k in args.dropFirst() { sendKey(k) }
case "scroll":
    scroll(Double(args[1])!, Double(args[2])!, Int32(args[3])!)
case "pid":
    let pid = pid_t(args[1])!
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.5)
    let cmd = args.count > 2 ? args[2] : "tree"
    switch cmd {
    case "windows":
        for w in roots(app) { print(describe(w)) }
        if let f = attr(app, kAXFocusedUIElementAttribute) { print("FOCUSED: " + describe(f as! AXUIElement)) }
    case "tree":
        let maxDepth = args.count > 3 ? Int(args[3]) ?? 40 : 40
        let all = args.contains("--all")
        for w in roots(app) {
            walk(w, depth: 0, maxDepth: maxDepth, all: all) { e, d in print(String(repeating: "  ", count: d) + describe(e)) }
        }
        if let f = attr(app, kAXFocusedUIElementAttribute) { print("FOCUSED: " + describe(f as! AXUIElement)) }
    case "find":
        let needle = args[3...].joined(separator: " ").lowercased()
        let hits = findAll(app) { e in describe(e).lowercased().contains(needle) }
        for h in hits { print(describe(h)) }
        if hits.isEmpty { print("NOT FOUND: \(needle)"); exit(3) }
    case "press", "action", "setvalue", "focus", "setsel":
        let mode = args[3]  // id | title | frame | value | desc
        let target = args[4]
        let matches = findAll(app) { e in
            switch mode {
            case "id": return str(e, kAXIdentifierAttribute) == target
            case "title": return str(e, kAXTitleAttribute) == target || (str(e, kAXRoleAttribute) == "AXStaticText" && str(e, kAXValueAttribute) == target)
            case "desc": return str(e, kAXDescriptionAttribute) == target
            case "value": return str(e, kAXValueAttribute) == target
            case "frame":
                let f = frame(e); return "\(I(f.origin.x)),\(I(f.origin.y)),\(I(f.width)),\(I(f.height))" == target
            default: return false
            }
        }
        let ordered = matches.sorted { frame($0).width > 0 && frame($1).width <= 0 }
        guard let el = ordered.first else { print("NOT FOUND: \(mode) \(target)"); exit(3) }
        if matches.count > 1 { print("note: \(matches.count) matches, using first: \(describe(el))") }
        switch cmd {
        case "press":
            let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
            print("press \(describe(el)) -> \(r.rawValue)")
        case "action":
            let r = AXUIElementPerformAction(el, args[5] as CFString)
            print("action \(args[5]) \(describe(el)) -> \(r.rawValue)")
        case "setvalue":
            let text = args[5...].joined(separator: " ")
            let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
            print("setvalue \(describe(el)) -> \(r.rawValue)")
        case "focus":
            let r = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            print("focus \(describe(el)) -> \(r.rawValue)")
        case "setsel":
            // insert text through the text system (kAXSelectedText) so SwiftUI bindings update; no keyboard events
            let text = args[5...].joined(separator: " ")
            let f = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(200000)
            let r = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            print("setsel focus=\(f.rawValue) \(describe(el)) -> \(r.rawValue)")
        default: break
        }
    case "appchildren":
        for c in children(app) { print(describe(c).prefix(160)) }
        if let f = attr(app, kAXFocusedUIElementAttribute) { print("FOCUSED: " + describe(f as! AXUIElement).prefix(160)) }
    case "at", "pressat":
        // hit-test the element at screen point and describe / press it (no tree walk)
        var el: AXUIElement?
        let r = AXUIElementCopyElementAtPosition(app, Float(args[3])!, Float(args[4])!, &el)
        guard r == .success, let e = el else { print("hit-test failed \(r.rawValue)"); exit(3) }
        print("at: " + describe(e).prefix(200))
        if cmd == "pressat" { let pr = AXUIElementPerformAction(e, kAXPressAction as CFString); print("pressat -> \(pr.rawValue)") }
    case "menuitem":
        // press an item of a currently open menu (popup/context) without walking the SwiftUI tree
        let want = args[3...].joined(separator: " ")
        var menus: [AXUIElement] = []
        for c in children(app) where str(c, kAXRoleAttribute) == "AXMenu" { menus.append(c) }
        if let f = attr(app, kAXFocusedUIElementAttribute) {
            let fe = f as! AXUIElement
            if str(fe, kAXRoleAttribute) == "AXMenu" { menus.append(fe) }
            for c in children(fe) where str(c, kAXRoleAttribute) == "AXMenu" { menus.append(c) }
        }
        for w in roots(app) { for c in children(w) where str(c, kAXRoleAttribute) == "AXMenu" { menus.append(c) } }
        print("menus found: \(menus.count)")
        for m in menus {
            for it in children(m) {
                let t = str(it, kAXTitleAttribute)
                if args.contains("--list") { print("  item: \(t)") }
                if t == want { let r = AXUIElementPerformAction(it, kAXPressAction as CFString); print("menuitem \(t) -> \(r.rawValue)"); exit(0) }
            }
        }
        if !args.contains("--list") { print("NOT FOUND menuitem \(want)"); exit(3) }
    case "menu":
        guard let mb = attr(app, kAXMenuBarAttribute) else { print("no menubar"); exit(3) }
        let top = args[3]; let item = args[4]
        for m in children(mb as! AXUIElement) where str(m, kAXTitleAttribute) == top {
            for menu in children(m) { for it in children(menu) where str(it, kAXTitleAttribute) == item {
                let r = AXUIElementPerformAction(it, kAXPressAction as CFString); print("menu \(top) > \(item) -> \(r.rawValue)"); exit(0) } }
        }
        print("NOT FOUND menu \(top) > \(item)"); exit(3)
    default: print("unknown pid cmd")
    }
default:
    print("unknown command")
}
