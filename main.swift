// SimpleScreenTab — Cmd-Tab that shows only the apps on the display under the mouse.
// https://github.com/k33ssa/SimpleScreenTab  —  MIT.
import Cocoa
import ApplicationServices
import ServiceManagement

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
    var mouseAtShow = NSPoint.zero   // где был курсор при открытии: стоящая мышь ничего не выбирает

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
            let cr = cocoaRect(b)
            guard screenFor(cr)?.frame == screen.frame,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            // пропустить полноэкранные окна (границы совпадают со всем экраном)
            let f = screen.frame
            if abs(cr.width - f.width) < 2, abs(cr.height - f.height) < 2 { continue }
            seen.insert(pid)
            out.append(Entry(app: app, bounds: b))
        }
        return out
    }

    // MARK: панель

    // Иконки рисуются один раз в маленький битмап: достать и отрисовать иконку — сотни мс.
    var iconCache: [String: NSImage] = [:]

    func iconKey(_ app: NSRunningApplication) -> String {
        app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
    }

    func icon(for app: NSRunningApplication) -> NSImage? {
        let k = iconKey(app)
        if let c = iconCache[k] { return c }
        guard let src = app.icon else { return nil }
        let side: CGFloat = 76, scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let px = Int(side * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return src }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: side, height: side))
        img.addRepresentation(rep)
        iconCache[k] = img
        return img
    }

    // Прогреть кэш заранее: при старте и когда запускается новая программа.
    func warmIcons() {
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { _ = icon(for: a) }
        NotificationCenter.default.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                               object: nil, queue: .main, using: { [weak self] n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  a.activationPolicy == .regular else { return }
            _ = self?.icon(for: a)
        })
    }

    func makePanel() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let fx = HoverView()
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.maskImage = Switcher.roundedMask(radius: 18)   // маска задаёт форму блюра И тени окна
        panel.contentView = fx
    }

    func show(reverse: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let screen = screenUnderMouse()
        entries = collect(on: screen)
        let t1 = CFAbsoluteTimeGetCurrent()
        guard !entries.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let start = (entries[0].app == front && entries.count > 1) ? 1 : 0
        index = reverse ? entries.count - 1 : start
        layout(on: screen)
        mouseAtShow = NSEvent.mouseLocation
        showing = true
        highlight()
        panel.orderFrontRegardless()
        let t2 = CFAbsoluteTimeGetCurrent()
        if ProcessInfo.processInfo.environment["SST_TIMING"] != nil {
            NSLog("SST timing: windows %.0f ms, panel %.0f ms", (t1 - t0) * 1000, (t2 - t1) * 1000)
        }
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
            img.image = icon(for: e.app)
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

    // Мышь: выбор только над иконкой; поля панели и всё вокруг выбор не меняют.
    func cellIndex(at p: NSPoint) -> Int? { cells.firstIndex { $0.frame.contains(p) } }

    func hover(_ p: NSPoint) {
        guard showing, NSEvent.mouseLocation != mouseAtShow,
              let i = cellIndex(at: p), i != index else { return }
        index = i
        highlight()
        if ProcessInfo.processInfo.environment["SST_TIMING"] != nil { NSLog("SST hover -> %d", i) }
    }

    func click(_ p: NSPoint) {
        guard showing, let i = cellIndex(at: p) else { return }
        index = i
        commit()
    }

    func commit() {
        guard showing else { return }   // уже переключились кликом — отпускание ⌘ ничего не делает
        hide()
        guard index < entries.count else { return }
        let e = entries[index]
        // запросы к Accessibility — не в главном потоке: подвисшее приложение не должно стопорить UI
        DispatchQueue.global(qos: .userInteractive).async {
            self.raise(e)
            DispatchQueue.main.async { e.app.activate(options: [.activateIgnoringOtherApps]) }
            usleep(50_000)
            self.raise(e)
        }
    }

    func quitSelected() {
        guard index < entries.count else { return }
        entries[index].app.terminate()
        entries.remove(at: index)
        if entries.isEmpty { hide(); return }
        index = min(index, entries.count - 1)
        layout(on: screenUnderMouse()); highlight()
    }

    // Поднять именно то окно приложения, что лежит на этом мониторе.
    func raise(_ e: Entry) {
        let ax = AXUIElementCreateApplication(e.app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)   // по умолчанию ~6 с
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return }
        for w in wins {
            AXUIElementSetMessagingTimeout(w, 0.25)
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
        // свой поток: перехват отвечает системе сразу, даже если главный поток занят панелью
        let th = Thread {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "event-tap"
        th.qualityOfService = .userInteractive
        th.start()
        return true
    }
}

let kTab: Int64 = 48, kEsc: Int64 = 53, kReturn: Int64 = 36, kLeft: Int64 = 123, kRight: Int64 = 124, kQ: Int64 = 12

// Состояние для потока перехвата (меняется только в нём).
var tapShowing = false

func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

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
            if tapShowing { onMain { s.step(back ? -1 : 1) } }
            else { tapShowing = true; onMain { s.show(reverse: back) } }
            return nil
        }
        if tapShowing {
            switch code {
            case kEsc: tapShowing = false; onMain { s.hide() }
            case kReturn: tapShowing = false; onMain { s.commit() }
            case kLeft: onMain { s.step(-1) }
            case kRight: onMain { s.step(1) }
            case kQ: onMain { s.quitSelected() }   // ⌘Q в списке — закрыть выбранное приложение
            default: break
            }
            return nil
        }
    case .keyUp:
        if tapShowing { return nil }
    case .flagsChanged:
        if tapShowing, !flags.contains(.maskCommand) { tapShowing = false; onMain { s.commit() } }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

// Подложка панели: ловит движение мыши и клики.
final class HoverView: NSVisualEffectView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // клики по иконке и подписи достаются панели, а не вложенным полям
    override func hitTest(_ p: NSPoint) -> NSView? { frame.contains(p) ? self : nil }
    override func mouseMoved(with e: NSEvent) { Switcher.shared.hover(convert(e.locationInWindow, from: nil)) }
    override func mouseEntered(with e: NSEvent) { Switcher.shared.hover(convert(e.locationInWindow, from: nil)) }
    override func mouseDown(with e: NSEvent) { Switcher.shared.click(convert(e.locationInWindow, from: nil)) }
}

// MARK: приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var retry: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        // второй экземпляр не нужен
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) { exit(0) }
        // автозапуск при входе (для установки из zip/brew; сборка из исходников ставит LaunchAgent)
        let agent = NSHomeDirectory() + "/Library/LaunchAgents/\(Bundle.main.bundleIdentifier ?? "").plist"
        if Bundle.main.bundleURL.pathExtension == "app",
           !FileManager.default.fileExists(atPath: agent), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        Switcher.shared.makePanel()
        DispatchQueue.main.async { Switcher.shared.warmIcons() }
        #if PREVIEW
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Switcher.shared.show(reverse: false) }
        return
        #endif

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
            status.button?.title = " !"
            status.button?.imagePosition = .imageLeft
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if Switcher.shared.startTap() { t.invalidate(); self?.status.button?.title = "" }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
