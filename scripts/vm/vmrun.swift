// vmrun: a tiny macOS VM for testing YMCA Booker on an older macOS
// (scripts/test_macos12.sh drives it). Apple Silicon only; nothing to install.
//   vmrun install <ipsw> <dir>          create <dir>/{disk.img,aux.img,hw,id} and install macOS
//   vmrun run <dir> [[rw:]extra.img ...] boot; extra raw images attach as USB disks (rw: writable)
// While running, write commands to <dir>/cmd (one per line); results go to <dir>/out:
//   shot <png>  |  click <x> <y> [double]  |  type <text>  |  key <name> [cmd|shift|opt|ctrl ...]
//   move <x> <y> | stop
// Coordinates are points in the VM view, origin top left.
import AppKit
import Virtualization

let args = CommandLine.arguments
func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
guard args.count >= 3 else { die("usage: vmrun install <ipsw> <dir> | vmrun run <dir> [img ...]") }

let W = 1280, H = 800

func makeConfig(dir: URL, hw: VZMacHardwareModel, id: VZMacMachineIdentifier, extra: [String]) throws -> VZVirtualMachineConfiguration {
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hw
    platform.machineIdentifier = id
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: dir.appendingPathComponent("aux.img"))
    let c = VZVirtualMachineConfiguration()
    c.platform = platform
    c.bootLoader = VZMacOSBootLoader()
    c.cpuCount = 4
    c.memorySize = 6 << 30
    let g = VZMacGraphicsDeviceConfiguration()
    g.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: W, heightInPixels: H, pixelsPerInch: 80)]
    c.graphicsDevices = [g]
    var disks: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment:
        try VZDiskImageStorageDeviceAttachment(url: dir.appendingPathComponent("disk.img"), readOnly: false))]
    for e in extra {
        let rw = e.hasPrefix("rw:")
        disks.append(VZUSBMassStorageDeviceConfiguration(attachment:
            try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: rw ? String(e.dropFirst(3)) : e), readOnly: !rw)))
    }
    c.storageDevices = disks
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    c.networkDevices = [net]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    c.keyboards = [VZUSBKeyboardConfiguration()]
    try c.validate()
    return c
}

final class App: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    var vm: VZVirtualMachine!
    var view: VZVirtualMachineView!
    var window: NSWindow!
    var dir: URL!
    var installer: VZMacOSInstaller?
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        dir = URL(fileURLWithPath: args[args[1] == "install" ? 3 : 2])
        if args[1] == "install" { install(URL(fileURLWithPath: args[2])) } else { run(Array(args.dropFirst(3))) }
    }

    func install(_ ipsw: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        VZMacOSRestoreImage.load(from: ipsw) { result in
            DispatchQueue.main.async {
                do {
                    let image = try result.get()
                    guard let req = image.mostFeaturefulSupportedConfiguration else { die("unsupported image") }
                    let hw = req.hardwareModel, id = VZMacMachineIdentifier()
                    try hw.dataRepresentation.write(to: self.dir.appendingPathComponent("hw"))
                    try id.dataRepresentation.write(to: self.dir.appendingPathComponent("id"))
                    _ = try VZMacAuxiliaryStorage(creatingStorageAt: self.dir.appendingPathComponent("aux.img"), hardwareModel: hw, options: [.allowOverwrite])
                    let disk = self.dir.appendingPathComponent("disk.img")
                    FileManager.default.createFile(atPath: disk.path, contents: nil)
                    let h = try FileHandle(forWritingTo: disk); try h.truncate(atOffset: 48 << 30); try h.close()
                    let c = try makeConfig(dir: self.dir, hw: hw, id: id, extra: [])
                    self.vm = VZVirtualMachine(configuration: c)
                    let inst = VZMacOSInstaller(virtualMachine: self.vm, restoringFromImageAt: ipsw)
                    self.installer = inst
                    self.timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                        print(String(format: "install %.0f%%", inst.progress.fractionCompleted * 100)); fflush(stdout)
                    }
                    inst.install { r in
                        switch r {
                        case .success: print("INSTALL-OK"); exit(0)
                        case .failure(let e): die("install failed: \(e)")
                        }
                    }
                } catch { die("install: \(error)") }
            }
        }
    }

    func run(_ extra: [String]) {
        do {
            guard let hw = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: dir.appendingPathComponent("hw"))),
                  let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: dir.appendingPathComponent("id")))
            else { die("bad hw/id") }
            vm = VZVirtualMachine(configuration: try makeConfig(dir: dir, hw: hw, id: id, extra: extra))
        } catch { die("config: \(error)") }
        vm.delegate = self
        view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "vmrun"
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        vm.start { r in
            if case .failure(let e) = r { die("start: \(e)") }
            print("RUNNING"); fflush(stdout)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { print("STOPPED"); exit(0) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { die("stopped: \(error)") }

    // MARK: commands

    func poll() {
        let cmdURL = dir.appendingPathComponent("cmd")
        guard let text = try? String(contentsOf: cmdURL, encoding: .utf8), !text.isEmpty else { return }
        try? FileManager.default.removeItem(at: cmdURL)
        var out: [String] = []
        for line in text.split(separator: "\n").map(String.init) where !line.isEmpty {
            out.append(handle(line))
        }
        try? (out.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("out"), atomically: true, encoding: .utf8)
    }

    func handle(_ line: String) -> String {
        let p = line.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = p.count > 1 ? p[1] : ""
        let nums = rest.split(separator: " ").compactMap { Double($0) }
        switch p[0] {
        case "shot": return shot(rest)
        case "move" where nums.count >= 2: mouse(.mouseMoved, nums[0], nums[1]); return "ok move"
        case "click" where nums.count >= 2:
            let clicks = rest.hasSuffix("double") ? 2 : 1
            mouse(.mouseMoved, nums[0], nums[1])
            for n in 1...clicks {
                mouse(.leftMouseDown, nums[0], nums[1], count: n)
                mouse(.leftMouseUp, nums[0], nums[1], count: n)
            }
            return "ok click"
        case "type": for ch in rest { typeChar(ch) }; return "ok type"
        case "key": return key(rest)
        case "stop": try? vm.requestStop(); return "ok stop"
        default: return "? \(line)"
        }
    }

    func point(_ x: Double, _ y: Double) -> NSPoint {
        view.convert(NSPoint(x: x, y: Double(H) - y), to: nil)
    }

    func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, count: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: point(x, y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: e)
        case .leftMouseUp: view.mouseUp(with: e)
        default: view.mouseMoved(with: e)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    }

    static let codes: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    func typeChar(_ ch: Character) {
        var base = ch, flags: NSEvent.ModifierFlags = []
        if ch.isUppercase { base = Character(ch.lowercased()); flags = .shift }
        if let s = Self.shifted[ch] { base = s; flags = .shift }
        let name = ch == " " ? "space" : String(base)
        guard let code = Self.codes[name] else { return }
        send(code, flags, String(ch))
    }

    func key(_ spec: String) -> String {
        let parts = spec.split(separator: " ").map(String.init)
        guard let name = parts.first, let code = Self.codes[name] else { return "? key \(spec)" }
        var flags: NSEvent.ModifierFlags = []
        for m in parts.dropFirst() {
            switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option); case "ctrl": flags.insert(.control); default: break }
        }
        send(code, flags, name.count == 1 ? name : "")
        return "ok key"
    }

    /// The left-hand key's device bit too (NX_DEVICEL*KEYMASK); the VM's keyboard reads those.
    static let device: [(NSEvent.ModifierFlags, UInt)] = [(.command, 0x8), (.shift, 0x2), (.option, 0x20), (.control, 0x1)]
    static func raw(_ f: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var r = f.rawValue
        for (m, bit) in device where f.contains(m) { r |= bit }
        return NSEvent.ModifierFlags(rawValue: r)
    }

    func send(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) {
        let modCodes: [(NSEvent.ModifierFlags, UInt16)] = [(.command, 55), (.shift, 56), (.option, 58), (.control, 59)]
        var held: NSEvent.ModifierFlags = []
        for (f, c) in modCodes where flags.contains(f) { held.insert(f); flagsEvent(held, c) }
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: Self.raw(flags), timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            if t == .keyDown { view.keyDown(with: e) } else { view.keyUp(with: e) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.012))
        }
        for (f, c) in modCodes.reversed() where flags.contains(f) { held.remove(f); flagsEvent(held, c) }
    }

    func flagsEvent(_ flags: NSEvent.ModifierFlags, _ code: UInt16) {
        guard let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: Self.raw(flags), timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: code) else { return }
        view.flagsChanged(with: e)
        RunLoop.current.run(until: Date().addingTimeInterval(0.012))
    }

    /// The VM's frame: from the view's IOSurface-backed layers, else the view itself.
    func shot(_ path: String) -> String {
        func surfaces(_ l: CALayer) -> [IOSurface] {
            var r: [IOSurface] = []
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() { r.append(c as! IOSurface) }
            for s in l.sublayers ?? [] { r += surfaces(s) }
            return r
        }
        var cg: CGImage?
        if let layer = view.layer, let s = surfaces(layer).max(by: { IOSurfaceGetWidth($0) < IOSurfaceGetWidth($1) }) {
            let ci = CIImage(ioSurface: s)
            cg = CIContext().createCGImage(ci, from: ci.extent)
        }
        if cg == nil, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep); cg = rep.cgImage
        }
        guard let cg, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return "fail shot" }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return "fail shot \(error)" }
        return "ok shot \(cg.width)x\(cg.height)"
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
