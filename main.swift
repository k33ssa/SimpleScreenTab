// SimpleScreenTab — Cmd-Tab that shows only the apps on the display under the mouse.
// https://github.com/k33ssa/SimpleScreenTab  —  MIT.
import Cocoa
import ApplicationServices

struct Entry {
    let app: NSRunningApplication
    let bounds: CGRect   // координаты CG (начало — левый верх главного экрана)
}

final class Switcher {
    static let shared = Switcher()

    var tap: CFMachPort?
    var panel: NSPanel!
    var cells: [NSView] = []
    var entries: [Entry] = []
    var index = 0
    var showing = false

    let cellW: CGFloat = 112, cellH: CGFloat = 118, pad: CGFloat = 16

    // Растягиваемая картинка со скруглёнными углами — маска для блюра и тени.
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    // MARK: экраны и окна

    func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main!
    }

    func cocoaRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens[0].frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    func screenFor(_ r: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let i = s.frame.intersection(r)
            let a = i.isNull ? 0 : i.width * i.height
            if a > bestArea { bestArea = a; best = s }
        }
        return best
    }

    func collect(on screen: NSScreen) -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var seen = Set<pid_t>()
        var out: [Entry] = []
        let me = getpid()
        for w in list {   // список идёт спереди назад — это и есть порядок «недавности»
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, !seen.contains(pid),
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd),
                  b.width > 60, b.height > 40 else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { continue }
            guard screenFor(cocoaRect(b))?.frame == screen.frame,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            seen.insert(pid)
            out.append(Entry(app: app, bounds: b))
        }
        return out
    }

    // MARK: панель

    func makePanel() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.maskImage = Switcher.roundedMask(radius: 18)   // маска задаёт форму блюра И тени окна
        panel.contentView = fx
    }

    func show(reverse: Bool) {
        let screen = screenUnderMouse()
        entries = collect(on: screen)
        guard !entries.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let start = (entries[0].app == front && entries.count > 1) ? 1 : 0
        index = reverse ? entries.count - 1 : start
        layout(on: screen)
        showing = true
        highlight()
        panel.orderFrontRegardless()
    }

    func layout(on screen: NSScreen) {
        let fx = panel.contentView!
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        let perRow = max(1, min(entries.count, Int((screen.visibleFrame.width * 0.9 - pad * 2) / cellW)))
        let rows = (entries.count + perRow - 1) / perRow
        let w = CGFloat(perRow) * cellW + pad * 2
        let h = CGFloat(rows) * cellH + pad * 2
        for (i, e) in entries.enumerated() {
            let col = i % perRow, row = i / perRow
            let cell = NSView(frame: NSRect(x: pad + CGFloat(col) * cellW,
                                            y: h - pad - CGFloat(row + 1) * cellH,
                                            width: cellW, height: cellH))
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 12
            let img = NSImageView(frame: NSRect(x: (cellW - 76) / 2, y: 32, width: 76, height: 76))
            img.image = e.app.icon
            img.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: e.app.localizedName ?? "?")
            label.frame = NSRect(x: 4, y: 8, width: cellW - 8, height: 18)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            cell.addSubview(img)
            cell.addSubview(label)
            fx.addSubview(cell)
            cells.append(cell)
        }
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
    }

    func highlight() {
        for (i, c) in cells.enumerated() {
            c.layer?.backgroundColor = (i == index) ? NSColor.white.withAlphaComponent(0.22).cgColor : nil
        }
    }

    func step(_ d: Int) {
        guard !entries.isEmpty else { return }
        index = (index + d + entries.count) % entries.count
        highlight()
    }

    func hide() {
        showing = false
        panel.orderOut(nil)
    }

    func commit() {
        hide()
        guard index < entries.count else { return }
        let e = entries[index]
        raise(e)
        e.app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.raise(e) }
    }

    // Поднять именно то окно приложения, что лежит на этом мониторе.
    func raise(_ e: Entry) {
        let ax = AXUIElementCreateApplication(e.app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return }
        for w in wins {
            var pv: CFTypeRef?, sv: CFTypeRef?
            var p = CGPoint.zero, s = CGSize.zero
            if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success, let pv {
                AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            }
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success, let sv {
                AXValueGetValue(sv as! AXValue, .cgSize, &s)
            }
            let b = e.bounds
            if abs(p.x - b.minX) < 3, abs(p.y - b.minY) < 3, abs(s.width - b.width) < 3, abs(s.height - b.height) < 3 {
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: перехват клавиш

    func startTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                        callback: tapCallback, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
}

let kTab: Int64 = 48, kEsc: Int64 = 53, kReturn: Int64 = 36, kLeft: Int64 = 123, kRight: Int64 = 124, kQ: Int64 = 12

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    let s = Switcher.shared
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = s.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    switch type {
    case .keyDown:
        if code == kTab, flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) {
            let back = flags.contains(.maskShift)
            if s.showing { s.step(back ? -1 : 1) } else { s.show(reverse: back) }
            return nil
        }
        if s.showing {
            switch code {
            case kEsc: s.hide()
            case kReturn: s.commit()
            case kLeft: s.step(-1)
            case kRight: s.step(1)
            case kQ:   // ⌘Q в списке — закрыть выбранное приложение, как в системном
                if s.index < s.entries.count {
                    s.entries[s.index].app.terminate()
                    s.entries.remove(at: s.index)
                    if s.entries.isEmpty { s.hide() } else {
                        s.index = min(s.index, s.entries.count - 1)
                        s.layout(on: s.screenUnderMouse()); s.highlight()
                    }
                }
            default: break
            }
            return nil
        }
    case .keyUp:
        if s.showing { return nil }
    case .flagsChanged:
        if s.showing, !flags.contains(.maskCommand) { s.commit() }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var retry: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        Switcher.shared.makePanel()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(named: NSImage.applicationIconName) {
            let b = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                icon.draw(in: r); return true
            }
            b.isTemplate = false
            status.button?.image = b
        } else {
            status.button?.title = "⇥"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit SimpleScreenTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        status.menu = menu

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !Switcher.shared.startTap() {
            status.button?.title = "⇥!"
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if Switcher.shared.startTap() { t.invalidate(); self?.status.button?.title = "⇥" }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
