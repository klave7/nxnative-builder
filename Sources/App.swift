// NxNative Builder: one native window. Setup first (every step asks before it changes anything), then updates, patches and the build queue.
import SwiftUI
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ n: Notification) { NSApp.activate(ignoringOtherApps: true) }
}

@main
struct NxNativeBuilderApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @StateObject var model = AppModel()
    var body: some Scene {
        WindowGroup("NxNative Builder") {
            ContentView().environmentObject(model).frame(minWidth: 820, minHeight: 640)
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NxNative Builder").font(.title2.bold())
                Spacer()
                if !m.busy.isEmpty { ProgressView().controlSize(.small); Text(m.busy + "…").foregroundColor(.accentColor) }
                if m.setupDone { Button(m.showSetup ? "Hide setup" : "Setup") { m.showSetup.toggle() } }
            }.padding([.horizontal, .top], 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !m.checked { HStack { ProgressView().controlSize(.small); Text("Checking requirements…").foregroundColor(.secondary) } }
                    else if !m.setupDone || m.showSetup { SetupSection() }
                    if m.setupDone { SourceSection(); PatchesSection(); QueueSection() }   // all requirements met: the setup page is skipped
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            LogView().frame(height: 190)
        }
        .sheet(item: $m.question) { q in QuestionSheet(q: q) }
        .sheet(isPresented: $m.showUninstall) { UninstallSheet() }
    }
}

struct QuestionSheet: View {
    @EnvironmentObject var m: AppModel
    let q: Question
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(q.title).font(.headline)
            Text(q.message).fixedSize(horizontal: false, vertical: true)
            if !q.command.isEmpty {
                Text(q.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.12)).cornerRadius(6)
            }
            HStack { Spacer(); Button("Cancel") { m.reply(false) }.keyboardShortcut(.cancelAction); Button(q.ok) { m.reply(true) }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 480)
    }
}

struct Card<Content: View>: View {
    let title: String, subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) { Text(title).font(.headline); if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundColor(.secondary) } }
            content
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08)).cornerRadius(10)
    }
}

struct Mark: View {
    let ok: Bool, bad: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : bad ? "xmark.circle.fill" : "circle")
            .foregroundColor(ok ? .green : bad ? .red : .secondary).font(.title3).frame(width: 24)
    }
}

struct SetupSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Card(title: "Setup", subtitle: "Each step asks before it changes anything. Files go to " + dataDir) {
            ForEach(m.setup) { i in
                HStack(alignment: .top) {
                    Mark(ok: i.ok, bad: !i.ok && !i.blocked)
                    VStack(alignment: .leading, spacing: 1) { Text(i.label).bold(); Text(i.why).font(.caption).foregroundColor(.secondary) }
                    Spacer()
                    if !i.ok {
                        Button(i.id == "xcode" ? "Open App Store…" : i.id == "brew" ? "Install in Terminal…" : "Install…") { Task { await m.install(i) } }
                            .disabled(i.blocked || !m.busy.isEmpty)
                    }
                }
                Divider()
            }
            HStack {
                Button("Install everything missing…") { Task { await m.installAll() } }.buttonStyle(.borderedProminent).disabled(m.setupDone || !m.busy.isEmpty)
                Button("Recheck") { Task { await m.refresh() } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Build games from a network drive in a local work folder", isOn: $m.localCache).bold()
                Text("Copies the game files to the folder below, builds there, moves the IPA to the output folder, then deletes the copy, the build and survey folders and the .idx file at once (not to the Trash). Games already on a drive attached to this Mac are built where they are. Needs about twice the game's size free.").font(.caption).foregroundColor(.secondary)
                if m.localCache {
                    HStack {
                        TextField(m.workRoot, text: $m.cacheDir).textFieldStyle(.roundedBorder)
                        Button("Browse…") { if let p = m.pick(folder: true, title: "Local folder for the work copies", start: m.workRoot) { m.cacheDir = p } }
                    }
                }
                HStack {
                    Text(m.workLeftCount == 0 ? "No leftover copies in the work folder." : String(format: "%d leftover copy(ies), %.1f GB, from an interrupted run.", m.workLeftCount, Double(m.workLeft) / 1e9))
                        .font(.caption).foregroundColor(m.workLeftCount == 0 ? .secondary : .orange)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: m.workRoot)) }.disabled(!FileManager.default.fileExists(atPath: m.workRoot))
                    Button("Clear work folder…") { Task { await m.clearWorkFolder() } }.disabled(!m.busy.isEmpty)
                }.onAppear { m.checkWorkFolder() }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Uninstall").bold()
                    Text("Removes what this app put on your Mac: its downloads, settings and caches. You see the list first.").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Uninstall…") { Task { await m.openUninstall() } }.disabled(!m.busy.isEmpty)
            }
        }
    }
}

struct UninstallSheet: View {
    @EnvironmentObject var m: AppModel
    func gb(_ b: Int) -> String { b >= 100_000_000 ? String(format: "%.1f GB", Double(b) / 1e9) : String(format: "%.1f MB", Double(b) / 1e6) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uninstall NxNative Builder?").font(.headline)
            Text("This removes the following from your Mac:")
            if m.uninstallItems.isEmpty { Text("Nothing is left in the Library.").foregroundColor(.secondary) }
            ForEach(m.uninstallItems) { it in
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text(it.label); Spacer(); Text(gb(it.bytes)).foregroundColor(.secondary) }
                    Text(it.path).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if !m.brewInstalled.isEmpty {
                Divider()
                Text("Homebrew packages this app installs. Other programs may use them, so they are kept unless you tick them:").font(.callout)
                ForEach(m.brewInstalled, id: \.id) { f in
                    Toggle(f.label + "  (brew uninstall \(f.id))", isOn: Binding(get: { m.brewPick.contains(f.id) }, set: { if $0 { m.brewPick.insert(f.id) } else { m.brewPick.remove(f.id) } }))
                }
            }
            Divider()
            Toggle("Move NxNative Builder.app to the Trash", isOn: $m.trashApp)
            Text("Not touched: your IPAs and game files, Xcode and its components, and Homebrew itself. The app quits when it is done.").font(.caption).foregroundColor(.secondary)
            HStack { Spacer(); Button("Cancel") { m.showUninstall = false }.keyboardShortcut(.cancelAction); Button("Uninstall") { Task { await m.uninstall() } }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 560)
    }
}

struct SourceSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Card(title: "Seedds nxnative", subtitle: "the game compatibility and build code") {
            if !m.repoReady {
                HStack {
                    Button("Download…") { Task { await m.download() } }.buttonStyle(.borderedProminent).disabled(!m.busy.isEmpty)
                    Text("Not downloaded yet (about 450 MB). The patches and the queue need it.").foregroundColor(.secondary)
                }
            } else {
                Text("This Mac has the version from \(m.repoHead). Updating is optional: this copy keeps working as it is.").foregroundColor(.secondary)
                HStack {
                    Button("Check for updates") { Task { await m.checkUpdates() } }.buttonStyle(.borderedProminent).disabled(!m.busy.isEmpty)
                    if let u = m.updates {
                        Text(u.behind > 0 ? "\(u.behind) newer commit(s) on Seedds' main." : "Up to date (checked \(u.checked)).").foregroundColor(.secondary)
                        if u.behind > 0 { Button("Update to latest…") { Task { await m.applyUpdates() } }.disabled(!m.busy.isEmpty) }
                    }
                }
                if let u = m.updates { ForEach(u.subjects, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) } }
            }
        }
    }
}

struct PatchesSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Card(title: "Patches", subtitle: "your changes on top of Seedds' code; apply them in order") {
            if !m.repoReady { Text("Download Seedds nxnative above first.").foregroundColor(.secondary) }
            if m.patches.isEmpty { Text("No patches found.").foregroundColor(.secondary) }
            ForEach(m.patches) { p in
                HStack(alignment: .top) {
                    Mark(ok: p.state == .applied, bad: p.state == .conflict)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).bold()
                        switch p.state {
                        case .applied: Text("Applied").font(.caption).foregroundColor(.green)
                        case .conflict: Text("Does not fit this version of nxnative (Seedds changed the same code).").font(.caption).foregroundColor(.red)
                        case .locked: Text("Apply the patch above first.").font(.caption).foregroundColor(.secondary)
                        default: EmptyView()
                        }
                    }
                    Spacer()
                    if p.state == .applied { Button("Undo…") { Task { await m.undoPatch(p) } }.disabled(!p.canUndo || !m.busy.isEmpty) }
                    else { Button("Apply…") { Task { await m.applyPatch(p) } }.buttonStyle(.borderedProminent).disabled(p.state != .ready || !m.busy.isEmpty) }
                }
                Divider()
            }
        }
    }
}

struct QueueSection: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let t = m.newName.trimmingCharacters(in: .whitespaces)
        let cut = t.isEmpty ? nil : m.truncatedLabel(t)
        Card(title: "Build queue", subtitle: "") {
            pathRow("prod.keys", $m.keys, "path of prod.keys") { if let p = m.pick(folder: false, title: "Select prod.keys", start: (m.keys as NSString).deletingLastPathComponent) { m.keys = p } }
            pathRow("IPA output", $m.out, "folder for the finished .ipa files") { if let p = m.pick(folder: true, title: "Folder for the finished IPA files", start: m.out) { m.out = p } }
            Toggle("After each game, delete the build folders it created (<title ID>_build etc. in the NSP folder; they take many GB)", isOn: $m.cleanup)
            Divider()
            pathRow("Games folder", $m.gamesFolder, "a folder with one subfolder per game") {
                if let p = m.pick(folder: true, title: "Folder that holds one subfolder per game", start: m.gamesFolder) { m.gamesFolder = p; m.scanGames() }
            }
            if !m.gamesFolder.isEmpty {
                HStack {
                    Text(m.scanning ? "Scanning the games folder…" : !m.scanned ? "Press Rescan to list the game folders." : m.found.isEmpty ? "No subfolders with game files (NSP, NSZ, XCI, XCZ) found." : "\(m.found.count) game folder(s) found. Name each one and add it to the queue.").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Rescan") { m.scanGames() }
                }
                ForEach(m.found) { g in FoundRow(g: g) }
            }
            Divider()
            pathRow("NSP folder", $m.newFolder, "folder with the game / update / DLC NSP files") {
                if let p = m.pick(folder: true, title: "Folder with the game / update / DLC NSP files") { m.newFolder = p; if m.newName.isEmpty { m.newName = (p as NSString).lastPathComponent } }
            }
            HStack {
                Text("Game name").frame(width: 80, alignment: .leading).foregroundColor(.secondary)
                TextField("name on the home screen", text: $m.newName).textFieldStyle(.roundedBorder).onSubmit { m.add() }
                Button("Add to queue") { m.add() }.buttonStyle(.borderedProminent)
            }
            if let c = cut {
                Label("Too long for the iPhone home screen: it will show as “\(c)”. (An estimate: about 11–12 characters fit.) You can still add it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            } else if !t.isEmpty { Text("Fits on the home screen.").font(.caption).foregroundColor(.secondary) }
            ForEach(m.jobs) { j in
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(j.name).bold().frame(width: 180, alignment: .leading)
                    Text(j.folder).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(j.status).foregroundColor(color(j.status)).frame(width: 70, alignment: .leading)
                    if j.status != "running" {
                        Button { m.move(j, -1) } label: { Image(systemName: "arrow.up") }
                        Button { m.move(j, 1) } label: { Image(systemName: "arrow.down") }
                        Button { m.remove(j) } label: { Image(systemName: "xmark") }
                    }
                }
                if j.status == "failed" || j.status == "done", let r = j.reason { Text(r).font(.caption).foregroundColor(j.status == "failed" ? .red : .orange).textSelection(.enabled) }
              }
            }
            HStack {
                Button("Process queue…") { Task { await m.runQueue() } }.buttonStyle(.borderedProminent).disabled(!m.busy.isEmpty)
                Button("Stop") { m.stop() }.disabled(m.busy.isEmpty)
                Button("Clear queue…") { Task { await m.clearQueue() } }.disabled(m.jobs.isEmpty || !m.busy.isEmpty)
                Text(m.message).foregroundColor(.orange)
            }
        }
    }
    func color(_ s: String) -> Color { s == "done" ? .green : s == "failed" ? .red : s == "running" ? .accentColor : s == "stopped" ? .orange : .secondary }
    func pathRow(_ label: String, _ text: Binding<String>, _ prompt: String, _ browse: @escaping () -> Void) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading).foregroundColor(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
            Button("Browse…", action: browse)
        }
    }
}

struct FoundRow: View {
    @EnvironmentObject var m: AppModel
    let g: FoundGame
    var body: some View {
        let name = Binding(get: { m.foundNames[g.path] ?? "" }, set: { m.foundNames[g.path] = $0 })
        let t = name.wrappedValue.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(g.folder).bold().lineLimit(1).truncationMode(.middle).frame(width: 190, alignment: .leading)
                Text("\(g.files) file(s)").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                if m.isQueued(g) {
                    Label("In the queue", systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                    Spacer()
                } else {
                    TextField("name on the home screen", text: name).textFieldStyle(.roundedBorder).onSubmit { m.addFound(g) }
                    Button("Add to queue") { m.addFound(g) }.disabled(t.isEmpty)
                }
            }
            if !m.isQueued(g), !t.isEmpty, let c = m.truncatedLabel(t) {
                Label("Too long for the iPhone home screen: it will show as “\(c)”.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange).padding(.leading, 250)
            }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        ScrollViewReader { r in
            ScrollView {
                Text(String(m.log.suffix(60000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                Color.clear.frame(height: 1).id("end")
            }.onChange(of: m.log) { _ in r.scrollTo("end") }
        }.background(Color.secondary.opacity(0.08))
    }
}
