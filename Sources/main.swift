// smoothscroll — trackpad-like smooth scrolling for mouse wheels on macOS.
//
// How it works: a CGEvent tap swallows discrete (notched) mouse-wheel events and
// replaces each one with a stream of small pixel-based "continuous" scroll events,
// one per display refresh, easing out exponentially — the same kind of events a
// trackpad produces. Trackpad / Magic Mouse events (already continuous) pass through.

import ApplicationServices
import CoreGraphics
import CoreVideo
import Foundation

let kMagic: Int64 = 0x534D_5343  // tags events we post so the tap ignores them
let kLabel = "local.smoothscroll"

// MARK: - Config

struct Config {
    var step = 60.0       // pixels per wheel notch
    var duration = 0.35   // seconds for a glide to (nearly) finish
    var accel = 1.0       // 0 = off; 1 = up to 3x on fast spins
    var reverse = false
    var verbose = false
}

let usageText = """
    smoothscroll — trackpad-like smooth scrolling for mouse wheels

    USAGE
      smoothscroll [options]             run in the foreground (Ctrl-C to quit)
      smoothscroll install [options]     run at login (LaunchAgent) with these options
      smoothscroll uninstall             remove the LaunchAgent

    OPTIONS
      -s, --step <px>       distance per wheel notch in pixels   (default 60)
      -d, --duration <ms>   glide time after a notch             (default 350)
      -a, --accel <x>       speed-up on fast spins, 0 disables   (default 1)
      -r, --reverse         invert mouse wheel direction (trackpad unaffected)
      -v, --verbose         log wheel events
      -h, --help            show this help

    Hold Cmd, Ctrl or Option to get the original (unsmoothed) wheel, e.g. for zoom.
    Shift + wheel scrolls horizontally.
    Requires Accessibility permission (System Settings > Privacy & Security).
    """

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("smoothscroll: \(msg)\n".utf8))
    exit(1)
}

func parse(_ args: [String]) -> Config {
    var c = Config()
    var i = 0
    func number(_ name: String) -> Double {
        i += 1
        guard i < args.count, let v = Double(args[i]), v.isFinite else { fail("\(name) needs a number") }
        return v
    }
    while i < args.count {
        switch args[i] {
        case "-s", "--step": c.step = number("--step")
        case "-d", "--duration": c.duration = number("--duration") / 1000
        case "-a", "--accel": c.accel = number("--accel")
        case "-r", "--reverse": c.reverse = true
        case "-v", "--verbose": c.verbose = true
        case "-h", "--help": print(usageText); exit(0)
        default: fail("unknown option '\(args[i])' (see --help)")
        }
        i += 1
    }
    if c.step <= 0 { fail("--step must be > 0") }
    if c.duration < 0.03 { fail("--duration must be at least 30 ms") }
    if c.accel < 0 { fail("--accel must be >= 0") }
    return c
}

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Scroll physics

struct Axis {
    var remaining = 0.0  // pixels still to scroll
    var carry = 0.0      // sub-pixel remainder not yet emitted
    var dir = 0.0
    var lastNotch = 0.0
    var streak = 0

    var idle: Bool { remaining == 0 }

    mutating func notch(_ delta: Double, at now: Double, _ cfg: Config) {
        let s: Double = delta > 0 ? 1 : -1
        if s != dir {
            stop()  // reversing direction stops the glide instantly, like a trackpad
        } else if now - lastNotch < 0.12 {
            streak += 1
        } else {
            streak = 0
        }
        dir = s
        lastNotch = now
        remaining += s * cfg.step * (1 + cfg.accel * 0.2 * Double(min(streak, 10)))
    }

    mutating func stop() {
        remaining = 0
        carry = 0
        streak = 0
    }

    /// Emits the whole pixels for one frame; `k` is the fraction of the remaining distance to cover.
    mutating func advance(_ k: Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        var d = remaining * k
        if abs(remaining - d) < 0.5 { d = remaining }
        remaining -= d
        carry += d
        let whole = carry.rounded(.towardZero)
        carry -= whole
        return Int32(whole)
    }
}

// MARK: - Engine (frame driver + event output)

final class Engine {
    private let tau: Double
    private let cfg: Config
    private let lock = NSLock()
    private var y = Axis(), x = Axis()
    private var lastFrame = 0.0

    // Accessed on the main thread only.
    private var link: CVDisplayLink?
    private var timer: DispatchSourceTimer?
    private var running = false
    private let timerQueue = DispatchQueue(label: "smoothscroll.frames", qos: .userInteractive)

    init(_ cfg: Config) {
        self.cfg = cfg
        tau = cfg.duration / 4.6  // exp(-4.6) ≈ 1% left at `duration`
        var l: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&l) == kCVReturnSuccess, let l {
            CVDisplayLinkSetOutputHandler(l) { [unowned self] _, _, _, _, _ in
                self.frame()
                return kCVReturnSuccess
            }
            link = l
        }
    }

    func wheel(dy: Double, dx: Double) {
        let now = uptime()
        lock.lock()
        if dy != 0 { y.notch(dy, at: now, cfg) }
        if dx != 0 { x.notch(dx, at: now, cfg) }
        lock.unlock()
        start()
    }

    func cancel() {
        lock.lock()
        y.stop()
        x.stop()
        lock.unlock()
    }

    private func start() {
        guard !running else { return }
        running = true
        if let link {
            if CVDisplayLinkStart(link) == kCVReturnSuccess { return }
            print("display link unavailable, falling back to a timer")
            self.link = nil
        }
        var hz = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
        if hz < 30 { hz = 60 }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1 / hz, leeway: .nanoseconds(0))
        t.setEventHandler { [unowned self] in self.frame() }
        t.resume()
        timer = t
    }

    private func stopIfIdle() {
        lock.lock()
        let idle = y.idle && x.idle
        lock.unlock()
        guard running, idle else { return }
        if let link { CVDisplayLinkStop(link) }
        timer?.cancel()
        timer = nil
        running = false
    }

    // Called once per display refresh while a glide is in progress (render thread).
    private func frame() {
        let now = uptime()
        lock.lock()
        let dt = lastFrame == 0 ? 1.0 / 60 : min(max(now - lastFrame, 0.001), 0.05)
        lastFrame = now
        let k = 1 - exp(-dt / tau)
        let dy = y.advance(k), dx = x.advance(k)
        let idle = y.idle && x.idle
        if idle { lastFrame = 0 }
        lock.unlock()

        if dy != 0 || dx != 0 { post(dy, dx) }
        if idle { DispatchQueue.main.async { self.stopIfIdle() } }
    }

    private func post(_ dy: Int32, _ dx: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: kMagic)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.flags = .maskNonCoalesced  // no modifiers, so a held Cmd mid-glide doesn't zoom
        e.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Event tap

var cfg = Config()
var engine: Engine!
var tap: CFMachPort?

func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return pass
    case .scrollWheel:
        break
    default:  // a click stops the glide, like touching a trackpad
        engine.cancel()
        return pass
    }

    if event.getIntegerValueField(.eventSourceUserData) == kMagic { return pass }

    // Trackpad, Magic Mouse, or already-smooth devices: leave alone.
    if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
        engine.cancel()
        return pass
    }

    let mods = event.flags
    if !mods.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
        engine.cancel()
        return pass
    }

    var dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    var dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    if dy == 0 && dx == 0 {
        dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    }
    if dy == 0 && dx == 0 { return pass }
    if mods.contains(.maskShift) && dx == 0 { swap(&dx, &dy) }
    if cfg.reverse { dy = -dy; dx = -dx }

    if cfg.verbose { print(String(format: "wheel dy=%+.2f dx=%+.2f", dy, dx)) }
    engine.wheel(dy: dy, dx: dx)
    return nil  // swallow the original notch
}

func waitForAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) { return }
    print("""
        Waiting for Accessibility permission…
          System Settings > Privacy & Security > Accessibility
          enable the entry for: \(Bundle.main.executablePath ?? "smoothscroll") (or your terminal app)
        """)
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 2) }
    print("Permission granted.")
}

func run(_ args: [String]) -> Never {
    cfg = parse(args)
    waitForAccessibility()
    engine = Engine(cfg)

    let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    let callback: CGEventTapCallBack = { _, type, event, _ in handle(type, event) }

    var created: CFMachPort?
    for attempt in 0..<10 {
        created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: mask,
                                    callback: callback, userInfo: nil)
        if created != nil { break }
        if attempt == 0 { print("Event tap not available yet, retrying…") }
        Thread.sleep(forTimeInterval: 1)
    }
    guard let created else {
        fail("could not create event tap — check Accessibility permission, then restart")
    }
    tap = created
    let source = CFMachPortCreateRunLoopSource(nil, created, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)

    print(String(format: "smoothscroll running (step %.0fpx, duration %.0fms, accel %.2f%@)",
                 cfg.step, cfg.duration * 1000, cfg.accel, cfg.reverse ? ", reversed" : ""))
    CFRunLoopRun()
    exit(0)
}

// MARK: - LaunchAgent

let plistURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(kLabel).plist")

@discardableResult
func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func install(_ args: [String]) {
    _ = parse(args)  // validate before writing anything
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
        fail("cannot determine executable path")
    }
    let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/smoothscroll.log").path
    let plist: [String: Any] = [
        "Label": kLabel,
        "ProgramArguments": [exe] + args,
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Interactive",  // don't let launchd throttle us
        "StandardOutPath": log,
        "StandardErrorPath": log,
    ]
    do {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    } catch {
        fail("writing \(plistURL.path): \(error.localizedDescription)")
    }
    let domain = "gui/\(getuid())"
    launchctl("bootout", "\(domain)/\(kLabel)")
    guard launchctl("bootstrap", domain, plistURL.path) == 0 else {
        fail("launchctl bootstrap failed for \(plistURL.path)")
    }
    print("""
        Installed and started: \(exe) \(args.joined(separator: " "))
        Agent: \(plistURL.path)
        Log:   \(log)
        If prompted, allow \(exe) in System Settings > Privacy & Security > Accessibility.
        """)
}

func uninstall() {
    launchctl("bootout", "gui/\(getuid())/\(kLabel)")
    try? FileManager.default.removeItem(at: plistURL)
    print("Removed \(plistURL.path)")
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)
var argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "install": install(Array(argv.dropFirst()))
case "uninstall": uninstall()
case "run": run(Array(argv.dropFirst()))
default: run(argv)
}
