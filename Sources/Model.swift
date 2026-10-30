// NxNative Builder's engine. Everything the window does is here: the setup checks and installs, updating the Seedds nxnative copy, the patches, and the build queue.
// Everything the app ships (the patches, the icon) is inside the .app, so copying the .app to another Mac is all it takes. What it downloads goes to
// ~/Library/Application Support/NxNative Builder: nxnative/ (a clone of github.com/seedds/nxnative) and venv/ (the build script's Python environment); config.json there holds
// the user's settings and queue, and patches/ may hold extra .patch files of the user's own. Homebrew and its packages stay where Homebrew keeps them (/opt/homebrew), as Homebrew requires.
// Every change is one of the fixed actions below, and each is put to the user first (ask).
import SwiftUI
import AppKit

let repoURL = "https://github.com/seedds/nxnative"
let pipPackages = ["lz4", "capstone", "fonttools", "backports.zstd", "nsz"]
let formulae: [(id: String, label: String, tool: String, why: String)] = [
    ("python@3.12", "Python 3.12", "python3.12", "runs the build script (its modules go into the app's own environment)"),
    ("xcodegen", "XcodeGen", "xcodegen", "makes the Xcode project the IPA is built from"),
    ("zstd", "zstd", "zstd", "decompresses the game's files"),
    ("glslang", "glslang", "glslangValidator", "compiles an OpenGL game's shaders"),
    ("dotnet", ".NET SDK", "dotnet", "runs the NSP extractor and the shader translator (needs .NET 10)"),
]

let dataDir = ProcessInfo.processInfo.environment["NXB_DATA"] ?? NSString(string: "~/Library/Application Support/NxNative Builder").expandingTildeInPath   // NXB_DATA: another folder, for tests
let repoDir = dataDir + "/nxnative"
let venvDir = dataDir + "/venv"
let configPath = dataDir + "/config.json"

func brewPath() -> String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }

func toolEnv() -> [String: String] {
    var paths: [String] = []
    if let b = brewPath() { paths.append((b as NSString).deletingLastPathComponent) }
    paths += [venvDir + "/bin", "/usr/local/share/dotnet", NSString(string: "~/.dotnet").expandingTildeInPath, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = paths.joined(separator: ":")
    env["PYTHONUNBUFFERED"] = "1"
    env["HOMEBREW_NO_ENV_HINTS"] = "1"
    env["PYTHONPATH"] = nil
    return env
}

func which(_ tool: String) -> String? {
    for d in (toolEnv()["PATH"] ?? "").split(separator: ":") {
        let p = "\(d)/\(tool)"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

/// Runs a command to the end and returns its exit code and output (stdout and stderr together). Blocking: call it off the main thread.
func capture(_ args: [String], cwd: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.environment = toolEnv()
    if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
}

func runAsync(_ args: [String], cwd: String? = nil) async -> (Int32, String) {
    await Task.detached { capture(args, cwd: cwd) }.value
}

struct SetupItem: Identifiable {
    let id: String
    let label, why, how, command: String
    var ok = false
    var blocked = false
    var manual = false
    var deps: [String] = []
}

enum PatchState { case applied, ready, locked, conflict, norepo }

struct PatchItem: Identifiable {
    var id: String { name }
    let name, title, path: String
    var state: PatchState
    var canUndo = false
    var note = ""   // e.g. its docs were left out
    var requires: [String] = []   // titles of the patches this one needs (a "Requires:" line in the patch's header)
}

struct Job: Identifiable, Codable {
    var id: Int
    var folder, name: String
    var status = "waiting"
    var reason: String? = nil   // one sentence on why the last build failed
}

struct Config: Codable {
    var keys = "", out = ""
    var cleanup = false
    var queue: [Job] = []
    var games: String? = nil   // the games folder last scanned
    var localCache: Bool? = nil
    var cacheDir: String? = nil
    var bigSeparate: Bool? = nil
}

struct Updates {
    var head = "", checked = ""
    var behind = 0
    var subjects: [String] = []
}

/// A subfolder of the games folder that holds game files (NSP, NSZ, XCI, XCZ).
struct FoundGame: Identifiable {
    var id: String { path }
    let path, folder: String
    let files: Int
}

struct UninstallItem: Identifiable {
    var id: String { path }
    let path, label: String
    let bytes: Int
}

struct Question: Identifiable {
    let id = UUID()
    let title, message, command, ok: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var setup: [SetupItem] = []
    @Published var patches: [PatchItem] = []
    @Published var updates: Updates?
    @Published var jobs: [Job] = []
    @Published var keys = "" { didSet { save() } }
    @Published var out = "" { didSet { save() } }
    @Published var cleanup = false { didSet { save() } }
    @Published var log = ""
    @Published var busy = ""
    @Published var message = ""
    @Published var question: Question?
    @Published var showSetup = false
    @Published var checked = false
    @Published var repoReady = false
    @Published var repoHead = ""
    @Published var newFolder = ""
    @Published var newName = ""
    @Published var gamesFolder = "" { didSet { save() } }
    /// Copy a game that is on a network drive to a local folder, build there, move the IPA out and delete the copy.
    @Published var localCache = false { didSet { save() } }
    @Published var bigSeparate = false { didSet { save() } }   // games over 4 GB: the game files stay out of the IPA
    @Published var cacheDir = "" { didSet { save() } }
    var workRoot: String { cacheDir.isEmpty ? NSTemporaryDirectory() + "NxNative Builder Work" : cacheDir }
    @Published var found: [FoundGame] = []
    @Published var foundNames: [String: String] = [:]
    @Published var showUninstall = false
    @Published var uninstallItems: [UninstallItem] = []
    @Published var brewInstalled: [(id: String, label: String)] = []
    @Published var brewPick: Set<String> = []
    @Published var trashApp = true

    private var answer: CheckedContinuation<Bool, Never>?
    private var current: Process?
    private var stopFlag = false
    private var nextId = 0
    private var loaded = false

    var setupDone: Bool { checked && setup.allSatisfy { $0.ok } }

    init() {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        if let d = FileManager.default.contents(atPath: configPath), let c = try? JSONDecoder().decode(Config.self, from: d) {
            keys = c.keys; out = c.out; cleanup = c.cleanup; jobs = c.queue; gamesFolder = c.games ?? ""; localCache = c.localCache ?? false; bigSeparate = c.bigSeparate ?? false; cacheDir = c.cacheDir ?? ""
            nextId = (jobs.map { $0.id }.max() ?? -1) + 1
        }
        loaded = true
        checkWorkFolder()
        Task { await refresh() }
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
            Task { @MainActor in if !self.setupDone && self.busy.isEmpty && self.question == nil { await self.refresh() } }
        }
    }

    func save() {
        guard loaded else { return }
        let c = Config(keys: keys, out: out, cleanup: cleanup, queue: jobs.filter { $0.status != "done" }.map { var j = $0; j.status = "waiting"; return j }, games: gamesFolder, localCache: localCache, cacheDir: cacheDir, bigSeparate: bigSeparate)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: URL(fileURLWithPath: configPath)) }
    }

    func say(_ s: String) {
        var parts = s.components(separatedBy: "\r")
        log += parts.removeFirst()
        for part in parts {   // a carriage return redraws the current line (git's progress): drop it and write the new one
            if let nl = log.lastIndex(of: "\n") { log = String(log[...nl]) } else { log = "" }
            log += part
        }
        if log.count > 2_000_000 { log = String(log.suffix(1_500_000)) }
    }

    // MARK: asking the user
    func ask(_ title: String, _ message: String, command: String = "", ok: String = "Continue") async -> Bool {
        await withCheckedContinuation { c in
            answer = c
            question = Question(title: title, message: message, command: command, ok: ok)
        }
    }
    func reply(_ yes: Bool) { question = nil; answer?.resume(returning: yes); answer = nil }

    // MARK: running commands
    /// Runs a command, copying its output to the log. It leads its own process group, so Stop reaches everything it started.
    @Published var workLeft = 0
    @Published var workLeftCount = 0
    @Published var scanning = false
    @Published var scanned = false   // the folder is listed only when asked: at launch a sleeping drive would freeze the app
    var streamText = ""   // the output of the last command, for failureReason

    /// One sentence on why a build failed, from the script's output: the step that failed (its ✗ line) and the last Python exception, FAIL: line or [RED] line after it.
    func failureReason(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: #"^\[\d\d:\d\d:\d\d\] "#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        let at = lines.lastIndex { $0.hasPrefix("✗") }
        var step = ""
        if let a = at { step = lines[a].replacingOccurrences(of: #"^✗ (\[\d+/\d+\] )?"#, with: "", options: .regularExpression).replacingOccurrences(of: #" \(\d+:\d+\)$"#, with: "", options: .regularExpression) }
        let tail = Array(lines[(at ?? 0)...])
        func clean(_ s: String) -> String {
            var r = s.replacingOccurrences(of: "[RED] ", with: "").replacingOccurrences(of: "FAIL: ", with: "")
            if let q = r.range(of: #": ['\"/]"#, options: .regularExpression), r.hasPrefix("FileExists") || r.hasPrefix("FileNotFound") || r.hasPrefix("PermissionError") { r = String(r[..<q.lowerBound]) }
            if let dot = r.range(of: ". ") { r = String(r[..<dot.lowerBound]) }
            if r.count > 170 { r = String(r.prefix(170)) + "…" }
            return r.trimmingCharacters(in: CharacterSet(charactersIn: " .;:"))
        }
        // a 32-bit ARM version of a game: name the version and the ones the profile registers
        if let re = try? NSRegularExpression(pattern: #"(.+?) is a 32-bit ARM program.*?registers (.+?): pack"#),
           let l = tail.first(where: { $0.contains("32-bit ARM program") }),
           let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
           let a = Range(m.range(at: 1), in: l), let b = Range(m.range(at: 2), in: l) {
            return "\(l[a].replacingOccurrences(of: "[RED] ", with: "")) is a 32-bit ARM version, which cannot run here; put an update the profile registers (\(l[b])) in the game's folder."
        }
        let isErr = { (l: String) in l.range(of: #"^[A-Za-z_.]+(Error|Exception|Exit|Interrupt): "#, options: .regularExpression) != nil }
        let why = tail.last(where: isErr) ?? tail.last { $0.hasPrefix("FAIL:") } ?? tail.last { $0.hasPrefix("[RED]") && !$0.contains("exit code") && !$0.contains("provisional game profile") }
            ?? lines.last { $0.hasPrefix("[RED]") && !$0.contains("exit code") && !$0.contains("provisional game profile") }
        let w = why.map(clean) ?? ""
        if !step.isEmpty && !w.isEmpty { return "Failed at \(step): \(w)." }
        if !w.isEmpty { return "Failed: \(w)." }
        return step.isEmpty ? "Failed; the log has no reason." : "Failed at \(step); the log has no reason."
    }

    /// A note for a build that succeeded, from the script's output: the profile registers another game version than the files (the IPA is packed from a derived profile, without that version's fixes), or it was provisional.
    func successNote(_ text: String) -> String? {
        var notes: [String] = []
        if let re = try? NSRegularExpression(pattern: #"is not a version game profile \S+ registers \(v(\d+) ([^)]*)\): packing v(\d+)"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            func g(_ i: Int) -> String { Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            notes.append((Int(g(1)) ?? 0) > (Int(g(3)) ?? 0) ? "profile requests a more recent update of the game (\(g(2))); get its update files for the tested build"
                                                            : "the game files are newer than the version the profile was tested on (\(g(2)))")
        }
        if text.contains("[RED] provisional game profile") { notes.append("built with a provisional profile, so it may not boot") }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    func stream(_ args: [String], cwd: String? = nil) async -> Int32 {
        say("$ " + args.joined(separator: " ") + "\n")
        streamText = ""
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", "setpgrp(0,0); exec @ARGV or die \"$!\\n\"", "--"] + args
            p.environment = toolEnv()
            if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                let s = String(decoding: d, as: UTF8.self)
                DispatchQueue.main.async { self.say(s); self.streamText += s }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async {
                    if !rest.isEmpty { let r = String(decoding: rest, as: UTF8.self); self.say(r); self.streamText += r }
                    self.current = nil
                    cont.resume(returning: proc.terminationStatus)
                }
            }
            do { try p.run(); current = p } catch { say("cannot start: \(error)\n"); cont.resume(returning: 127) }
        }
    }

    func stop() {
        stopFlag = true
        if let p = current { kill(-p.processIdentifier, SIGINT) }
    }

    /// One job at a time: the window shows `label` while it runs.
    func work(_ label: String, _ body: () async -> Void) async {
        guard busy.isEmpty else { return }
        busy = label; stopFlag = false; message = ""
        await body()
        busy = ""
        await refresh()
    }

    // MARK: setup
    func refresh() async {
        let s = await Task.detached { AppModel.checkSetup() }.value
        let p = await Task.detached { AppModel.checkPatches() }.value
        let ready = FileManager.default.fileExists(atPath: repoDir + "/.git")
        let head = ready ? await runAsync(["git", "log", "-1", "--format=%h, %cs"], cwd: repoDir).1 : ""
        setup = s; patches = p; repoReady = ready; repoHead = head; checked = true
    }

    nonisolated static func checkSetup() -> [SetupItem] {
        var items: [SetupItem] = []
        let xc = capture(["xcodebuild", "-version"])
        let xcodeOK = xc.0 == 0 && xc.1.contains("Xcode")
        items.append(SetupItem(id: "xcode", label: "Xcode", why: "builds the iPhone app and compiles the shaders (a large download from the Mac App Store; the app cannot install it for you)",
                               how: "Opens the Mac App Store page. Install Xcode, open it once and accept its licence, then press Recheck.", command: "open the Xcode page in the Mac App Store", ok: xcodeOK, manual: true))
        let sdk = xcodeOK && capture(["xcodebuild", "-showsdks"]).1.contains("iphoneos")
        items.append(SetupItem(id: "ios", label: "iOS platform for Xcode", why: "the iPhone SDK the app is built against (several GB)", how: "", command: "xcodebuild -downloadPlatform iOS", ok: sdk, deps: ["xcode"]))
        let metal = xcodeOK && capture(["xcrun", "-sdk", "iphoneos", "metal", "--version"]).0 == 0
        items.append(SetupItem(id: "metal", label: "Metal compiler", why: "compiles the game's shaders (Xcode installs it separately)", how: "", command: "xcodebuild -downloadComponent MetalToolchain", ok: metal, deps: ["xcode"]))
        let brew = brewPath()
        items.append(SetupItem(id: "brew", label: "Homebrew", why: "installs the command line tools below; its installer opens in Terminal and asks for your Mac password there", how: "",
                               command: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"   (runs in Terminal)", ok: brew != nil, manual: true))
        for f in formulae {
            items.append(SetupItem(id: "brew:" + f.id, label: f.label, why: f.why, how: "", command: "brew install " + f.id, ok: which(f.tool) != nil, deps: ["brew"]))
        }
        var venvOK = false
        if FileManager.default.fileExists(atPath: venvDir + "/bin/python") { venvOK = capture([venvDir + "/bin/python", "-c", "import lz4.block,capstone,fontTools,backports.zstd"]).0 == 0 }
        items.append(SetupItem(id: "venv", label: "Python environment", why: "the build script's Python modules (" + pipPackages.joined(separator: ", ") + "), kept in the app's own folder", how: "",
                               command: "python3.12 -m venv '\(venvDir)' && pip install " + pipPackages.joined(separator: " "), ok: venvOK, deps: ["brew:python@3.12"]))
        let ok = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.ok) })
        return items.map { var i = $0; i.blocked = !i.ok && i.deps.contains { !(ok[$0] ?? false) }; return i }
    }

    func install(_ item: SetupItem) async {
        let verb = item.manual ? (item.id == "xcode" ? "Open" : "Open Terminal") : "Install"
        let msg = item.manual && !item.how.isEmpty ? item.how : "This will: \(item.why)."
        guard await ask("\(item.id == "xcode" ? "Get" : "Install") \(item.label)?", msg, command: item.command, ok: verb) else { return }
        switch item.id {
        case "xcode":
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!)
        case "brew":
            let script = NSTemporaryDirectory() + "install-homebrew.command"   // a throwaway launcher, not an app file
            let body = "#!/bin/bash\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\necho\necho \"Done. Close this window and press Recheck in NxNative Builder.\"\n"
            try? body.write(toFile: script, atomically: true, encoding: .utf8)
            chmod(script, 0o755)
            NSWorkspace.shared.open(URL(fileURLWithPath: script), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            say("Homebrew's installer is open in Terminal: finish it there, then press Recheck.\n")
        default:
            await work("Installing \(item.label)") { await runInstall(item.id) }
        }
    }

    private func runInstall(_ id: String) async {
        switch id {
        case "ios": _ = await stream(["xcodebuild", "-downloadPlatform", "iOS"])
        case "metal": _ = await stream(["xcodebuild", "-downloadComponent", "MetalToolchain"])
        case "venv":
            let py = ((brewPath() ?? "") as NSString).deletingLastPathComponent + "/python3.12"
            if await stream([py, "-m", "venv", venvDir]) == 0 {
                _ = await stream([venvDir + "/bin/python", "-m", "pip", "install", "--upgrade", "pip"] + pipPackages)
            }
        default: if id.hasPrefix("brew:") { _ = await stream([brewPath() ?? "brew", "install", String(id.dropFirst(5))]) }
        }
    }

    func installAll() async {
        await refresh()
        while let item = setup.first(where: { !$0.ok && !$0.blocked }) {
            if item.manual { await install(item); return }
            guard await ask("Install \(item.label)?", "This will: \(item.why).", command: item.command, ok: "Install") else { return }
            await work("Installing \(item.label)") { await runInstall(item.id) }
            if let again = setup.first(where: { $0.id == item.id }), !again.ok { return }   // it failed: stop and let the log be read
        }
    }

    // MARK: Seedds nxnative: downloaded from the main page, updated only when the user wants
    func download() async {
        guard await ask("Download Seedds nxnative?", "Copies the project (about 450 MB, a couple of minutes) into the app's own folder. You can update it later or keep using that copy.",
                        command: "git clone \(repoURL) '\(repoDir)'", ok: "Download") else { return }
        await work("Downloading nxnative") {
            if await stream(["git", "clone", "--progress", repoURL, repoDir]) != 0 { try? FileManager.default.removeItem(atPath: repoDir) }   // a cut-short clone is no copy
        }
    }

    // MARK: updates
    func checkUpdates() async {
        await work("Checking for updates") { await fetchUpdates() }
    }
    private func fetchUpdates() async {
        guard await stream(["git", "fetch", "origin"], cwd: repoDir) == 0 else { return }
        let head = await runAsync(["git", "rev-parse", "--short", "HEAD"], cwd: repoDir).1
        let behind = await runAsync(["git", "log", "--format=%h %s", "HEAD..origin/main"], cwd: repoDir).1.split(separator: "\n").map(String.init)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        updates = Updates(head: head, checked: f.string(from: Date()), behind: behind.count, subjects: Array(behind.prefix(12)))
        say("Seedds nxnative: at \(head), \(behind.count) newer commit(s) on main.\n")
    }
    func applyUpdates() async {
        guard let u = updates else { return }
        guard await ask("Update nxnative?", "This takes your applied patches off, then replaces the local copy with Seedds' latest main (\(u.behind) newer commit(s)). Apply the patches again afterwards.",
                        command: "git reset --hard origin/main", ok: "Update") else { return }
        await work("Updating nxnative") {
            for p in patches.reversed() where p.state == .applied { _ = await stream(["git", "apply", "-R"] + undoArgs(p.path) + [p.path], cwd: repoDir) }
            if await stream(["git", "reset", "--hard", "origin/main"], cwd: repoDir) == 0 { for p in patches { for f in AppModel.removeStale(p.path) { say("Removed the leftover \(f).\n") } }; await fetchUpdates() }
        }
    }


    // MARK: newest Seedds version the patches fit
    @Published var compat: (sha: String, subject: String, behind: Int, date: String)? = nil
    @Published var compatNote = ""

    /// Looks back through Seedds' main for the newest commit the whole patch stack goes onto (the doubling steps back, then a binary search between the last miss and the first fit).
    func findCompatible() async {
        compat = nil; compatNote = ""
        await work("Looking for the newest version the patches fit") {
            say("Fetching Seedds' latest …\n")
            _ = await stream(["git", "fetch", "origin"], cwd: repoDir)
            let revs = (await runAsync(["git", "rev-list", "--first-parent", "-n", "600", "origin/main"], cwd: repoDir)).1.split(separator: "\n").map(String.init)
            let files = AppModel.patchFiles().map { $0.1 }
            guard !revs.isEmpty, !files.isEmpty else { compatNote = "No Seedds history to search."; return }
            func fits(_ i: Int) async -> Bool { await Task.detached { AppModel.stackFits(revs[i], files) }.value }
            if await fits(0) { compatNote = "The patches fit Seedds' newest version; use Update to latest."; return }
            var lo = 0, step = 1, hi = -1
            while lo + step < revs.count {
                let i = lo + step
                if await fits(i) { hi = i; break }
                lo = i; step *= 2
            }
            if hi < 0, await fits(revs.count - 1) { hi = revs.count - 1 }
            guard hi >= 0 else { compatNote = "The patches do not fit any of Seedds' last \(revs.count) commits. They need updating."; return }
            while hi - lo > 1 { let mid = (lo + hi) / 2; if await fits(mid) { hi = mid } else { lo = mid } }
            let info = (await runAsync(["git", "log", "-1", "--format=%cs|%s", revs[hi]], cwd: repoDir)).1.split(separator: "|", maxSplits: 1).map(String.init)
            compat = (revs[hi], info.count > 1 ? info[1] : "", hi, info.first ?? "")
            say("Newest fit: \(String(revs[hi].prefix(7))), \(hi) commit(s) behind Seedds' newest.\n")
        }
    }

    func useCompatible() async {
        guard let c = compat else { return }
        guard await ask("Use Seedds' version from \(c.date)?", "This takes your applied patches off, then sets the local copy to Seedds' commit \(c.sha.prefix(7)) (\(c.behind) commit(s) older than the newest), where all three patches fit. Apply the patches again afterwards. Update to latest returns to the newest.",
                        command: "git reset --hard \(c.sha.prefix(7))", ok: "Use it") else { return }
        await work("Going back to a version the patches fit") {
            for p in patches.reversed() where p.state == .applied { _ = await stream(["git", "apply", "-R"] + undoArgs(p.path) + [p.path], cwd: repoDir) }
            _ = await stream(["git", "reset", "--hard", c.sha], cwd: repoDir)
            for p in patches { for f in AppModel.removeStale(p.path) { say("Removed the leftover \(f).\n") } }
        }
        compat = nil; compatNote = ""
        await refresh()
    }

    // MARK: patches (an ordered stack: each one goes on after the ones above it)
    nonisolated static func patchFiles() -> [(String, String)] {
        var found: [String: String] = [:]
        for d in [(Bundle.main.resourcePath ?? "") + "/patches", dataDir + "/patches"] {
            for n in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []) where n.hasSuffix(".patch") { found[n] = d + "/" + n }
        }
        return found.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    nonisolated static func patchTitle(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (path as NSString).lastPathComponent }
        var subj = "", cur = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Subject:") { subj = line.dropFirst(8).trimmingCharacters(in: .whitespaces); cur = true }
            else if cur && line.hasPrefix(" ") { subj += " " + line.trimmingCharacters(in: .whitespaces) }
            else if cur { break }
        }
        if let r = subj.range(of: #"^\[PATCH[^\]]*\]\s*"#, options: .regularExpression) { subj.removeSubrange(r) }
        return subj.isEmpty ? (path as NSString).lastPathComponent : subj
    }

    // How a patch may go on, in the order tried: as written, with one line of context (Seedds' surroundings moved), and without the documentation and test files (Seedds edited the same docs).
    // The code hunks must always fit; only those optional files may be left out.
    nonisolated static let optional = ["--exclude=docs/*", "--exclude=dm/tools/tests/*", "--exclude=dm/host/tests/*"]
    nonisolated static let applyVariants: [(args: [String], say: String)] = [
        ([], ""),
        (["-C1"], "The patch's surrounding lines moved in this version of nxnative; applying it with one line of context.\n"),
        (optional, "Its documentation and test changes no longer fit this version, so they are left out; the code changes are applied.\n"),
        (["-C1"] + optional, "The surrounding lines moved and its documentation and test changes no longer fit: one line of context, the docs and tests left out.\n"),
    ]
    /// The files a patch creates (its "new file mode" entries).
    nonisolated static func newFiles(_ patchPath: String) -> [String] {
        guard let text = try? String(contentsOfFile: patchPath, encoding: .isoLatin1) else { return [] }
        var out: [String] = [], last = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), let r = line.range(of: " b/", options: .backwards) { last = String(line[r.upperBound...]) }
            else if line.hasPrefix("new file mode"), !last.isEmpty { out.append(last) }
        }
        return out
    }
    /// Files the patch would create that already sit untracked in the copy: what an earlier version of the patch left behind when it could not be taken off (a reset does not delete untracked files).
    nonisolated static func staleNewFiles(_ patchPath: String) -> [String] {
        newFiles(patchPath).filter { FileManager.default.fileExists(atPath: repoDir + "/" + $0) && capture(["git", "ls-files", "--error-unmatch", $0], cwd: repoDir).0 != 0 }
    }
    nonisolated static func removeStale(_ patchPath: String) -> [String] {
        let gone = staleNewFiles(patchPath)
        for f in gone { try? FileManager.default.removeItem(atPath: repoDir + "/" + f) }
        return gone
    }

    /// The first way that the patch can be applied (or, with reverse, taken off) to the working tree; nil if none.
    nonisolated static func variant(_ path: String, reverse: Bool = false) -> Int? {
        // a leftover untracked file the patch would create is left out of the check: applying removes it first
        let stale = reverse ? [] : staleNewFiles(path).map { "--exclude=" + $0 }
        return applyVariants.firstIndex { capture(["git", "apply", "--check"] + (reverse ? ["-R"] : []) + $0.args + stale + [path], cwd: repoDir).0 == 0 }
    }
    /// Whether the whole patch stack goes onto a Seedds commit, tried in a scratch index (nothing in the working tree is touched).
    nonisolated static func stackFits(_ commit: String, _ files: [String]) -> Bool {
        let idx = NSTemporaryDirectory() + "nxb-index-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: idx) }
        func git(_ a: [String]) -> Int32 { capture(["env", "GIT_INDEX_FILE=" + idx, "git"] + a, cwd: repoDir).0 }
        guard git(["read-tree", commit]) == 0 else { return false }
        for f in files {
            // git apply changes the index only when it succeeds, so the first variant that works also leaves the patch applied for the next one
            guard applyVariants.contains(where: { git(["apply", "--cached"] + $0.args + [f]) == 0 }) else { return false }
        }
        return true
    }

    /// The patch's "Requires: 0001-name, 0002-name" header line: the patches it cannot go on without.
    nonisolated static func requirements(_ path: String) -> [String] {
        guard let h = try? String(contentsOfFile: path, encoding: .isoLatin1) else { return [] }
        for line in h.split(separator: "\n", omittingEmptySubsequences: false).prefix(30) where line.hasPrefix("Requires:") {
            return line.dropFirst(9).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// The patches are independent: each goes on or comes off by itself, in any order, except that one with a "Requires:" line waits for those.
    nonisolated static func checkPatches() -> [PatchItem] {
        let have = FileManager.default.fileExists(atPath: repoDir + "/.git")
        let files = patchFiles()
        let stem = { (n: String) in n.hasSuffix(".patch") ? String(n.dropLast(6)) : n }
        var out: [PatchItem] = []
        var reverseVariant: [String: Int] = [:]
        for (name, path) in files where have { if let v = variant(path, reverse: true) { reverseVariant[name] = v } }
        for (name, path) in files {
            var item = PatchItem(name: name, title: patchTitle(path), path: path, state: .norepo)
            item.requires = requirements(path)
            if have {
                if let v = reverseVariant[name] {
                    item.state = .applied
                    if applyVariants[v].args.contains(where: { $0.hasPrefix("--exclude") }) { item.note = "its documentation and test changes were left out (they no longer fit)" }
                } else if item.requires.contains(where: { r in !files.contains { stem($0.0) == r && reverseVariant[$0.0] != nil } }) {
                    item.state = .locked
                } else if variant(path) != nil || capture(["git", "apply", "--check", "--3way", path], cwd: repoDir).0 == 0 {
                    item.state = .ready
                } else { item.state = .conflict }
            }
            out.append(item)
        }
        // a patch that an applied one needs is on too, though its own lines no longer check as they were (the other patch changes them); it comes off only after that one
        for p in out where p.state == .applied { for r in p.requires { if let k = out.firstIndex(where: { stem($0.name) == r }) { out[k].state = .applied; out[k].note = "" } } }
        // a patch comes off only while no applied patch needs it
        for i in out.indices where out[i].state == .applied {
            let me = stem(out[i].name)
            out[i].canUndo = !out.contains { $0.state == .applied && $0.requires.contains(me) }
        }
        return out
    }

    func applyPatch(_ p: PatchItem) async {
        guard await ask("Apply this patch?", "Changes files in the local nxnative copy to add: \(p.title)", command: "git apply \(p.name)", ok: "Apply") else { return }
        await work("Applying \(p.name)") {
            if let v = await Task.detached(operation: { AppModel.variant(p.path) }).value {
                let ver = AppModel.applyVariants[v]
                for f in AppModel.removeStale(p.path) { say("Removed the leftover \(f) from an earlier version of this patch.\n") }
                if !ver.say.isEmpty { say(ver.say) }
                _ = await stream(["git", "apply"] + ver.args + [p.path], cwd: repoDir)
            } else if await stream(["git", "apply", "--3way", p.path], cwd: repoDir) == 0 {
                _ = await runAsync(["git", "reset", "-q"], cwd: repoDir)   // keep the changes in the working tree, not staged
            } else {
                say("The patch does not fit this version of nxnative (see above). Nothing was changed.\n")
            }
        }
    }
    /// The way the patch went on, so that it comes off the same way
    func undoArgs(_ path: String) -> [String] { AppModel.variant(path, reverse: true).map { AppModel.applyVariants[$0].args } ?? [] }
    func undoPatch(_ p: PatchItem) async {
        guard await ask("Undo this patch?", "Removes from the local nxnative copy: \(p.title)", command: "git apply -R \(p.name)", ok: "Undo") else { return }
        await work("Undoing \(p.name)") { _ = await stream(["git", "apply", "-R"] + undoArgs(p.path) + [p.path], cwd: repoDir) }
    }

    // MARK: queue
    func pick(folder: Bool, title: String, start: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder; panel.canCreateDirectories = folder
        panel.allowsMultipleSelection = false
        if let s = start, !s.isEmpty { panel.directoryURL = URL(fileURLWithPath: s) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newFolder, isDirectory: &isDir), isDir.boolValue else { message = "Pick the folder that holds the NSP files."; return }
        guard !name.isEmpty else { message = "Enter the game's name."; return }
        jobs.append(Job(id: nextId, folder: newFolder, name: name)); nextId += 1
        newFolder = ""; newName = ""; message = ""; save()
    }
    /// Lists the game folders in the background: a sleeping or slow external drive must not freeze the window.
    func scanGames() {
        let path = gamesFolder
        found = []; scanned = false
        guard !path.isEmpty else { return }
        scanning = true
        Task {
            let r = await Task.detached { AppModel.scan(path) }.value
            if path == gamesFolder { found = r; scanned = true }
            scanning = false
        }
    }
    nonisolated static func scan(_ gamesFolder: String) -> [FoundGame] {
        var out: [FoundGame] = []
        guard let subs = try? FileManager.default.contentsOfDirectory(atPath: gamesFolder) else { return out }
        let exts: Set<String> = ["nsp", "nsz", "xci", "xcz"]
        for n in subs.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !n.hasPrefix(".") {
            let p = gamesFolder + "/" + n
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            let count = ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }.count
            if count > 0 { out.append(FoundGame(path: p, folder: n, files: count)) }
        }
        return out
    }
    func isQueued(_ g: FoundGame) -> Bool { jobs.contains { $0.folder == g.path } }
    func addFound(_ g: FoundGame) {
        let name = (foundNames[g.path] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { message = "Enter a name for \(g.folder)."; return }
        jobs.append(Job(id: nextId, folder: g.path, name: name)); nextId += 1
        foundNames[g.path] = nil; message = ""; save()
    }

    // MARK: uninstall: what the app put on this Mac, listed with sizes and removed only after the user confirms
    nonisolated static func leftovers() -> [UninstallItem] {
        let home = NSString(string: "~").expandingTildeInPath
        let bid = Bundle.main.bundleIdentifier ?? "local.nxnative.builder"
        let cands: [(String, String)] = [
            (dataDir + "/nxnative", "Downloaded Seedds nxnative (with the applied patches)"),
            (dataDir + "/venv", "Python environment for the build script"),
            (dataDir, "Settings, queue and the rest of the app's folder"),
            (home + "/Library/Preferences/\(bid).plist", "App preferences"),
            (home + "/Library/Caches/\(bid)", "App caches"),
            (home + "/Library/Saved Application State/\(bid).savedState", "Saved window state"),
            (home + "/Library/HTTPStorages/\(bid)", "App network storage"),
            (home + "/Library/WebKit/\(bid)", "App web storage"),
        ]
        func size(_ p: String) -> Int {
            var total = 0
            if let e = FileManager.default.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0 }
            }
            return total
        }
        var out: [UninstallItem] = []
        var covered: [String] = []
        for (p, label) in cands where FileManager.default.fileExists(atPath: p) {
            if covered.contains(where: { p.hasPrefix($0 + "/") }) { continue }   // already inside an entry above
            var bytes = size(p)
            if p == dataDir { bytes = max(0, bytes - out.filter { covered.contains($0.path) }.reduce(0) { $0 + $1.bytes }) }   // what is left besides the entries above
            out.append(UninstallItem(path: p, label: label, bytes: bytes))
            if p != dataDir { covered.append(p) }
        }
        return out
    }

    func openUninstall() async {
        guard busy.isEmpty else { message = "Wait for the current job to finish."; return }
        brewPick = []; trashApp = true; showUninstall = true
        uninstallItems = await Task.detached { AppModel.leftovers() }.value
        var have: [(String, String)] = []
        if let b = brewPath() {
            let list = Set(await runAsync([b, "list", "--formula", "-1"]).1.split(separator: "\n").map(String.init))
            have = formulae.filter { list.contains($0.id) }.map { ($0.id, $0.label) }
        }
        brewInstalled = have
    }

    func uninstall() async {
        showUninstall = false
        busy = "Uninstalling"; stopFlag = false
        if !brewPick.isEmpty, let b = brewPath() {
            for f in brewPick.sorted() { _ = await stream([b, "uninstall", f]) }
        }
        loaded = false   // nothing may be written back into the folder being removed
        let bid = Bundle.main.bundleIdentifier ?? "local.nxnative.builder"
        UserDefaults.standard.removePersistentDomain(forName: bid)
        var removed: [String] = []
        for it in uninstallItems {
            // never anything but this app's own folders and files
            let ok = it.path.hasPrefix(dataDir) || it.path.contains("/Library/") && it.path.contains(bid)
            guard ok, it.path.split(separator: "/").count >= 3 else { continue }
            do { try FileManager.default.removeItem(atPath: it.path); removed.append(it.path); say("Removed \(it.path)\n") }
            catch { say("Could not remove \(it.path): \(error.localizedDescription)\n") }
        }
        if trashApp {
            await withCheckedContinuation { c in
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, err in
                    DispatchQueue.main.async { self.say(err == nil ? "Moved the app to the Trash.\n" : "Could not move the app to the Trash: \(err!.localizedDescription)\n"); c.resume() }
                }
            }
        }
        // The app writes its window frame and saved state while it quits: sweep those once more after it has gone.
        let sweep = removed.filter { $0.contains("/Library/") }.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        if !sweep.isEmpty {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 3; rm -rf " + sweep]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    func clearQueue() async {
        guard !jobs.isEmpty, busy.isEmpty else { return }
        guard await ask("Clear the whole queue?", "Removes all \(jobs.count) game(s) from the queue. Nothing on disk is deleted.", ok: "Clear queue") else { return }
        jobs.removeAll(); save()
    }
    func remove(_ j: Job) { jobs.removeAll { $0.id == j.id }; save() }
    func move(_ j: Job, _ d: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == j.id }), jobs.indices.contains(i + d) else { return }
        jobs.swapAt(i, i + d); save()
    }

    /// While a queue runs: tells macOS this is work the user started, so it does not slow the app (and the build it launched) down when the window is in the background, and does not
    /// put the Mac to sleep partway through (the display may still sleep).
    private var activity: NSObjectProtocol?
    func holdActivity() { if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Building IPA files") } }
    func releaseActivity() { if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil } }

    func runQueue() async {
        guard FileManager.default.fileExists(atPath: keys) else { message = "Set the path of prod.keys."; return }
        guard !out.isEmpty else { message = "Choose the output folder for the IPA files."; return }
        guard setupDone else { message = "Finish the setup first."; return }
        guard repoReady else { message = "Download Seedds nxnative first."; return }
        let n = jobs.filter { ["waiting", "failed", "stopped"].contains($0.status) }.count
        guard n > 0 else { message = "The queue has nothing to build."; return }
        guard await ask("Process the queue?", "Builds \(n) game(s) in order and writes each IPA to \(out). The output folder is created if it is missing."
                        + (localCache ? " Games on a network drive are copied to \(workRoot), built there, and the copy deleted afterwards." : "") + (cleanup ? " After each build, whether it succeeds, fails or is stopped, its build folders in the NSP folder are deleted." : ""), ok: "Start") else { return }
        for i in jobs.indices where jobs[i].status == "failed" || jobs[i].status == "stopped" { jobs[i].status = "waiting" }
        holdActivity()
        defer { releaseActivity() }
        await work("Building the queue") {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            while !stopFlag, let i = jobs.firstIndex(where: { $0.status == "waiting" }) {
                jobs[i].status = "running"
                let job = jobs[i]
                let safe = job.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
                let ipa = out + "/" + safe + ".ipa"
                say("\n===== \(job.name)  (\(job.folder)) -> \(ipa) =====\n")
                let started = Date().addingTimeInterval(-2)
                let (status, why) = await buildJob(job, safe: safe, ipa: ipa, started: started)
                if let k = jobs.firstIndex(where: { $0.id == job.id }) { jobs[k].status = status; jobs[k].reason = why }
                say("----- \(job.name): \(status)" + (why.map { " — " + $0 } ?? "") + "\n")
                save()
            }
            for k in jobs.indices where jobs[k].status == "running" { jobs[k].status = "stopped" }
            say(stopFlag ? "\nStopped.\n" : "\nQueue finished.\n")
        }
    }

    /// Builds one queue item and returns its status and a one-sentence note. A game on a network volume is first copied to a local folder (when the option is on),
    /// built there, and the IPA moved to the output folder; the local copy, the build and survey folders and the .idx are then deleted outright (rm, not the Trash).
    func buildJob(_ job: Job, safe: String, ipa: String, started: Date) async -> (String, String?) {
        let fm = FileManager.default
        guard !out.isEmpty else { return ("failed", "Failed: no output folder is set.") }
        let cached = localCache && !AppModel.onLocalVolume(job.folder)
        let exts: Set<String> = ["nsp", "nsz", "xci", "xcz"]
        let names = ((try? fm.contentsOfDirectory(atPath: job.folder)) ?? []).filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
        let total = names.reduce(0) { $0 + (((try? fm.attributesOfItem(atPath: job.folder + "/" + $1))?[.size] as? Int) ?? 0) }
        // FlareStore refuses an IPA with an entry over 4 GiB ("out of range integral type conversion attempted"), and the game files are one entry: above that size they stay out of the IPA (--romfs separate)
        // and go on the phone once as Documents/romfs.img, which no installer limits.
        let separate = bigSeparate && total > 4 << 30
        var folder = job.folder, target = ipa, work = ""
        if cached {
            work = workRoot + "/job-\(job.id)"
            try? fm.createDirectory(atPath: workRoot, withIntermediateDirectories: true)
            let free = (try? URL(fileURLWithPath: workRoot).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).flatMap { $0 } ?? Int64.max
            if names.isEmpty { return ("failed", "Failed: no NSP, NSZ or XCI files in the folder.") }
            if free < Int64(total) * 2 { return ("failed", String(format: "Failed: the local work folder needs about %.0f GB free (the game is %.0f GB) and has %.0f GB.", Double(total) * 2 / 1e9, Double(total) / 1e9, Double(free) / 1e9)) }
            say(String(format: "Copying %d file(s), %.1f GB, from %@ to the local work folder %@ …\n", names.count, Double(total) / 1e9, job.folder, work))
            _ = await stream(["/bin/rm", "-rf", work]); try? fm.createDirectory(atPath: work + "/out", withIntermediateDirectories: true)
            let rc = await stream(["/usr/bin/rsync", "-a", "--progress"] + names.map { job.folder + "/" + $0 } + [work + "/"])
            if rc != 0 || stopFlag {
                _ = await stream(["/bin/rm", "-rf", work])
                return stopFlag ? ("stopped", nil) : ("failed", "Failed: copying the game files to the local work folder did not finish (rsync exit \(rc)).")
            }
            folder = work; target = work + "/out/" + safe + ".ipa"
        }
        // The packer writes <ipa>.idx (its reuse index, valid only beside the IPA it describes) next to the IPA it is given, so the IPA is packed in a build folder of its own and never straight into the
        // output folder: no .idx lands there. With the cleanup box checked that folder is hidden on the output volume (the .ipa is renamed out of it and the rest deleted); without it the folder
        // stays in the game's folder with its IPA and index (a repack of the game reuses them), and the output gets a copy.
        var stage = ""
        if !cached {
            stage = cleanup ? out + "/.nxb-build-\(job.id)" : job.folder + "/.nxb-ipa"
            if cleanup { _ = await stream(["/bin/rm", "-rf", stage]) }
            try? fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
            target = stage + "/" + safe + ".ipa"
        }
        let cmd = [venvDir + "/bin/python", "-u", repoDir + "/scripts/build_ipa_from_nsp.py", folder, "-k", keys, "--app-name", job.name, "-o", target, "--progress", "lines"] + (separate ? ["--romfs", "separate"] : cleanup || cached ? ["--no-keep-extracted"] : [])
        let rc = await stream(cmd, cwd: repoDir)
        var status = stopFlag ? "stopped" : rc == 0 ? "done" : "failed"
        var why = status == "failed" ? failureReason(streamText) : status == "done" ? successNote(streamText).map { "Success: " + $0 + "." } : nil
        var keep = false
        var gameFiles = ""   // where a separate build's romfs.img was put
        if status == "done", separate {
            // the image is the extraction's RomFS.img, named in the line the build prints for push_romfs.sh; it moves beside the IPA, in a folder of its own, under the name the phone wants
            if let re = try? NSRegularExpression(pattern: #"push_romfs\.sh <device UDID> \S+ "([^"\n]+)""#), let m = re.firstMatch(in: streamText, range: NSRange(streamText.startIndex..., in: streamText)),
               let r = Range(m.range(at: 1), in: streamText) {
                let image = String(streamText[r])
                let dir = out + "/" + safe + " (game files)"
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                say("Moving the game files image to \(dir) …\n")
                if await stream(["/bin/mv", "-f", image, dir + "/romfs.img"]) == 0 { gameFiles = dir + "/romfs.img" }
            }
            if gameFiles.isEmpty { status = "failed"; keep = true; why = "Failed: the IPA was built, but its game files image (romfs.img) could not be found or moved; it is in the build folder of the NSP folder." }
        }
        if status == "done" {
            if cached { say("Moving the IPA to \(ipa) …\n") }
            var mv: Int32
            if cached || cleanup { mv = await stream(["/bin/mv", "-f", target, ipa]) }
            else {   // the IPA stays beside its index in the build folder; the output gets a copy (a clone where the volume can), put in place only when whole
                say("Copying the IPA to \(ipa) (the build folder keeps its own with the index) …\n")
                let part = ipa + ".partial"
                mv = await stream(["/bin/cp", "-c", target, part])
                if mv != 0 { mv = await stream(["/bin/cp", target, part]) }
                if mv == 0 { mv = await stream(["/bin/mv", "-f", part, ipa]) } else { _ = await stream(["/bin/rm", "-f", part]) }
            }
            if mv != 0 { status = "failed"; keep = true; why = "Failed: the IPA was built but could not be put in the output folder; it is kept in \(target)." }
            else {
                try? fm.removeItem(atPath: ipa + ".idx")   // an index left in the output by an older version
                if !gameFiles.isEmpty { why = "Success: the game files are not in the IPA (over 4 GB); after installing it, copy " + gameFiles + " to the app's Documents folder on the iPhone (Files app, or Finder's Files tab)." }
                else if ((try? fm.attributesOfItem(atPath: ipa))?[.size] as? Int ?? 0) > 4 << 30 { why = (why.map { $0 + " " } ?? "Success: ") + "The IPA is over 4 GB, which some installers (FlareStore) refuse; the option under Build queue keeps the game files out of it." }
            }
        }
        if cached { if !keep { say("Deleting the local work folder \(work) …\n"); _ = await stream(["/bin/rm", "-rf", work]) } }
        else if cleanup { if !keep { _ = await stream(["/bin/rm", "-rf", stage]) }; clean(folder: job.folder, ipa: ipa, since: started, built: status == "done") }
        return (status, why)
    }

    /// The copies a crashed or killed run left in the work folder: only job-<n> folders, so a work folder chosen by mistake as a real one is never emptied.
    nonisolated static func leftoverCopies(_ root: String) -> [(path: String, bytes: Int)] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.range(of: #"^job-\d+$"#, options: .regularExpression) != nil }.sorted().map { n in
            let p = root + "/" + n
            var bytes = 0
            if let e = fm.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                for case let u as URL in e { let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]); if v?.isSymbolicLink != true { bytes += v?.fileSize ?? 0 } }
            }
            return (p, bytes)
        }
    }

    func checkWorkFolder() {
        let root = workRoot
        Task { let r = await Task.detached { AppModel.leftoverCopies(root) }.value; workLeft = r.map { $0.bytes }.reduce(0, +); workLeftCount = r.count }
    }

    func clearWorkFolder() async {
        let root = workRoot
        let found = await Task.detached { AppModel.leftoverCopies(root) }.value
        guard !found.isEmpty else { workLeft = 0; workLeftCount = 0; message = "The work folder has nothing left over."; return }
        let gb = String(format: "%.1f GB", Double(found.map { $0.bytes }.reduce(0, +)) / 1e9)
        guard await ask("Delete the leftover work copies?", "Deletes \(found.count) folder(s), \(gb), at once (not to the Trash):\n" + found.map { $0.path }.joined(separator: "\n"), ok: "Delete") else { return }
        await work("Clearing the work folder") {
            for f in found { say("Deleting \(f.path) …\n"); _ = await stream(["/bin/rm", "-rf", f.path]) }
            say("Work folder cleared.\n")
        }
        checkWorkFolder()
    }

    nonisolated static func onLocalVolume(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }

    /// Deletes the build folders this run used in the game's NSP folder: <title ID>_build, _survey and -work, nothing else, and only once the IPA exists.
    func clean(folder: String, ipa: String, since: Date, built: Bool = true) {
        let fm = FileManager.default
        if built, !(((try? fm.attributesOfItem(atPath: ipa))?[.size] as? Int ?? 0) > 0) { say("Cleanup skipped: the IPA is not in the output folder.\n"); return }   // a failed or stopped build has no IPA to protect: its folders are only scratch
        var freed = 0
        let kept = folder + "/.nxb-ipa"   // the IPA and its index kept by a build without the cleanup box
        if let e = fm.enumerator(atPath: kept) { for case let f as String in e { freed += (try? fm.attributesOfItem(atPath: kept + "/" + f))?[.size] as? Int ?? 0 } }
        if fm.fileExists(atPath: kept) { try? fm.removeItem(atPath: kept); say("Removed \(kept)\n") }
        let idx = ipa + ".idx"   // the packer's reuse index beside the IPA: only useful for a quick repack, and it can be large
        if let a = try? fm.attributesOfItem(atPath: idx) {
            freed += a[.size] as? Int ?? 0
            try? fm.removeItem(atPath: idx)
            say("Removed \(idx)\n")
        }
        for n in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() where n.range(of: #"^[0-9A-Fa-f]{16}(_build|_survey|-work)$"#, options: .regularExpression) != nil {
            let p = folder + "/" + n
            guard let a = try? fm.attributesOfItem(atPath: p), a[.type] as? FileAttributeType == .typeDirectory, (a[.modificationDate] as? Date ?? .distantPast) >= since else { continue }
            var bytes = 0
            if let e = fm.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) {
                for case let u as URL in e { let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]); if v?.isSymbolicLink != true { bytes += v?.fileSize ?? 0 } }
            }
            try? fm.removeItem(atPath: p)
            freed += bytes
            say(String(format: "Removed %@ (%.1f GB)\n", p, Double(bytes) / 1e9))
        }
        say(String(format: "Cleanup done: %.1f GB freed.\n", Double(freed) / 1e9))
    }

    /// The name as the iPhone home screen shows it: nil when it fits, else the text with an ellipsis where it would be cut (an estimate by width, not by character count; calibrated on an iPhone Duo: "Cursed to Golf" fits and "Echoes of Wisdom" shows as "Echoes of Wisd…").
    func truncatedLabel(_ t: String) -> String? {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let maxW: CGFloat = 103   // measured on the user's iPhone Duo: "Cursed to Golf" (83.8) fits and "Echoes of Wisdom" shows as "Echoes of Wisd…", so the limit is between 99.6 and 106.7 in this font; the middle
        if width(t) <= maxW { return nil }
        var s = t
        while !s.isEmpty && width(s + "…") > maxW { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces) + "…"
    }
}
