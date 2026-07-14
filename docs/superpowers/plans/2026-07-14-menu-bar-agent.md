# Menu Bar Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS menu bar icon that shows how many tasks need attention today (overdue + due) and a dropdown to review and complete them, merged into the existing capture agent as a single `TuxedoAgent.app`.

**Architecture:** One persistent `.accessory` AppKit agent owns both the ⌥] capture panel and a new `NSStatusItem`. Task state comes from `tuxedo ls --json` (the Rust binary is the single source of truth); Swift only filters by date. The old `TuxedoCapture.app` / `dev.wolffness.tuxedo.capture` LaunchAgent is renamed to `TuxedoAgent.app` / `dev.wolffness.tuxedo.agent`, with the packaging script booting out the old agent on install.

**Tech Stack:** Swift + AppKit + Carbon (hotkey), compiled with `swiftc`; zsh packaging script; the existing Rust `tuxedo` CLI (`ls --json`, `done N`).

**Spec:** `docs/superpowers/specs/2026-07-14-menu-bar-agent-design.md`

---

## File Structure

The single-file `packaging/TuxedoCapture.swift` becomes a folder of focused files, all compiled together into the agent binary:

```
packaging/agent/
  Paths.swift        Foundation only: resolveTodoFile / resolveInbox / resolveTuxedoBinary
  Theme.swift        AppKit: phosphor/amber NSColors
  Summary.swift      Foundation only: TodoTask, Summary, IconState, computeSummary, fetchTasks
  CapturePanel.swift AppKit+Carbon: the ⌥] panel + hotkey (moved from TuxedoCapture.swift)
  MenuBar.swift      AppKit: MenuBarController (NSStatusItem + menu + actions + refresh)
  main.swift         AppKit: AppDelegate wiring CapturePanel + MenuBarController
  tests/main.swift   Foundation only: assertions over computeSummary (framework-free)
```

`Summary.swift` and `Paths.swift` deliberately avoid AppKit so the test binary compiles with no frameworks. `packaging/TuxedoCapture.swift` is deleted at the end of Task 1.

---

## Task 1: Restructure capture into `packaging/agent/` and rename to TuxedoAgent

Refactor only — the ⌥] capture panel must behave exactly as before. No menu bar yet.

**Files:**
- Create: `packaging/agent/Paths.swift`
- Create: `packaging/agent/Theme.swift`
- Create: `packaging/agent/CapturePanel.swift`
- Create: `packaging/agent/main.swift`
- Modify: `scripts/package-macos.sh` (build the folder, rename bundle + LaunchAgent, migrate old agent)
- Delete: `packaging/TuxedoCapture.swift`

- [ ] **Step 1: Create `packaging/agent/Paths.swift`**

```swift
// Filesystem paths shared by the capture panel and the menu bar. Foundation
// only (no AppKit) so the test binary links without frameworks.
import Foundation

/// TODO_FILE from the user's login shell (LaunchAgents get no shell env),
/// falling back to ~/todo.txt.
func resolveTodoFile() -> URL {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "printf %s \"${TODO_FILE:-$HOME/todo.txt}\""]
    let pipe = Pipe()
    p.standardOutput = pipe
    var todo = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("todo.txt")
    if (try? p.run()) != nil {
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            todo = URL(fileURLWithPath: s)
        }
    }
    return todo
}

/// inbox.txt sibling of TODO_FILE (quick-capture drop point).
func resolveInbox() -> URL {
    resolveTodoFile().deletingLastPathComponent().appendingPathComponent("inbox.txt")
}

/// The `tuxedo` binary in the OUTER app bundle's Resources — a sibling of this
/// nested agent app. resourcePath is
/// .../Tuxedo.app/Contents/Resources/TuxedoAgent.app/Contents/Resources ;
/// three parent hops reach .../Tuxedo.app/Contents/Resources.
func resolveTuxedoBinary() -> URL {
    URL(fileURLWithPath: Bundle.main.resourcePath ?? "")
        .deletingLastPathComponent()   // Contents
        .deletingLastPathComponent()   // TuxedoAgent.app
        .deletingLastPathComponent()   // outer Resources
        .appendingPathComponent("tuxedo")
}
```

- [ ] **Step 2: Create `packaging/agent/Theme.swift`**

```swift
// Phosphor-green CRT palette, shared by both surfaces.
import AppKit

enum Theme {
    static let phosphor = NSColor(srgbRed: 0.20, green: 1.00, blue: 0.20, alpha: 1.0)
    static let phosphorDim = NSColor(srgbRed: 0.11, green: 0.56, blue: 0.11, alpha: 1.0)
    /// Alert color for overdue counts — amber, coherent with the CRT look.
    static let amber = NSColor(srgbRed: 1.00, green: 0.75, blue: 0.20, alpha: 1.0)
    static let screenBg = NSColor(srgbRed: 0.008, green: 0.04, blue: 0.008, alpha: 0.97)
}
```

- [ ] **Step 3: Create `packaging/agent/CapturePanel.swift`** — move the panel + hotkey out of `packaging/TuxedoCapture.swift`

Copy the body of the current `Capture` class (lines 14–189 of `packaging/TuxedoCapture.swift`) with these exact changes:
- Rename `final class Capture` → `final class CapturePanel`.
- Delete the color constants at the top (lines 9–11) — use `Theme.phosphor`, `Theme.phosphorDim`, `Theme.screenBg` instead. Replace `phosphor` → `Theme.phosphor`, `phosphorDim` → `Theme.phosphorDim`, `screenBg` → `Theme.screenBg` throughout.
- Delete `resolveInbox()` from the class body (now in `Paths.swift`); keep the `inbox = resolveInbox()` call in `applicationDidFinishLaunching`.
- Remove `NSApplicationDelegate` from the conformance list (it is no longer the app delegate) but KEEP `NSObject, NSTextFieldDelegate`. Rename `applicationDidFinishLaunching(_:)` → `func start()` and drop its `note` parameter; it will be called by the AppDelegate.
- Keep `KeyPanel` (the `NSPanel` subclass) at the top of this file.
- Keep the `import AppKit` and `import Carbon.HIToolbox` lines.

The resulting file exposes `final class CapturePanel: NSObject, NSTextFieldDelegate` with a public `func start()` and a public `func show()` (already exists).

- [ ] **Step 4: Create `packaging/agent/main.swift`**

```swift
// Entry point: one .accessory agent owning the ⌥] capture panel and the menu
// bar status item.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let capture = CapturePanel()
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        capture.start()
        menuBar = MenuBarController(onNewTask: { [weak capture] in capture?.show() })
        menuBar.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

> NOTE: `MenuBarController` does not exist yet. To keep Task 1 self-contained and compilable, temporarily stub it: add a file `packaging/agent/MenuBar.swift` containing the stub below, replaced fully in Task 4.

```swift
import AppKit
final class MenuBarController {
    init(onNewTask: @escaping () -> Void) {}
    func start() {}
}
```

- [ ] **Step 5: Update `scripts/package-macos.sh`** — build the folder, rename to TuxedoAgent, migrate the old LaunchAgent

Replace the capture-agent build block (current lines 28–50) with:

```bash
echo "Building Tuxedo agent (capture + menu bar)..."
AGENTAPP="$APP/Contents/Resources/TuxedoAgent.app"
mkdir -p "$AGENTAPP/Contents/MacOS"
swiftc -O -o "$AGENTAPP/Contents/MacOS/TuxedoAgent" \
    packaging/agent/Paths.swift \
    packaging/agent/Theme.swift \
    packaging/agent/Summary.swift \
    packaging/agent/CapturePanel.swift \
    packaging/agent/MenuBar.swift \
    packaging/agent/main.swift \
    -framework AppKit -framework Carbon
cat > "$AGENTAPP/Contents/Info.plist" <<CAPPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tuxedo Agent</string>
    <key>CFBundleIdentifier</key>
    <string>dev.wolffness.tuxedo.agent</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>TuxedoAgent</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
CAPPLIST
```

> Task 1 references `packaging/agent/Summary.swift`, created in Task 2. Create an empty-but-valid placeholder now so Task 1 compiles: a file containing only `import Foundation`. Task 2 fills it in.

Replace the LaunchAgent block (current lines 105–131) with:

```bash
# Migrate the pre-rename capture agent, then (re)install the unified agent.
OLD_AGENT="$HOME/Library/LaunchAgents/dev.wolffness.tuxedo.capture.plist"
launchctl bootout "gui/$(id -u)/dev.wolffness.tuxedo.capture" 2>/dev/null || true
pkill -f "Resources/TuxedoCapture" 2>/dev/null || true
rm -f "$OLD_AGENT"

AGENT="$HOME/Library/LaunchAgents/dev.wolffness.tuxedo.agent.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.wolffness.tuxedo.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Tuxedo.app/Contents/Resources/TuxedoAgent.app/Contents/MacOS/TuxedoAgent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
AGENTPLIST
launchctl bootout "gui/$(id -u)/dev.wolffness.tuxedo.agent" 2>/dev/null || true
pkill -f "Resources/TuxedoAgent" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$AGENT" || \
    launchctl kickstart -k "gui/$(id -u)/dev.wolffness.tuxedo.agent" || true
echo "Installed: /Applications/Tuxedo.app (+ agent: ⌥] capture & menu bar)"
```

- [ ] **Step 6: Delete the old single file**

```bash
git rm packaging/TuxedoCapture.swift
```

- [ ] **Step 7: Build and install, verify capture still works**

Run: `./scripts/package-macos.sh`
Expected: ends with `Installed: /Applications/Tuxedo.app (+ agent: ⌥] capture & menu bar)`, no swiftc errors.

Verify the migration and the panel:
```bash
ls ~/Library/LaunchAgents/ | grep tuxedo    # expect ONLY dev.wolffness.tuxedo.agent.plist
pgrep -lf "Resources/TuxedoAgent"           # expect the agent process running
pgrep -lf "Resources/TuxedoCapture"         # expect NOTHING
```
Then press **⌥]** — the green capture panel must appear and typing + Enter must append to `inbox.txt`. (A stray old `tuxedo-capture.sh` iTerm session, if any, is unrelated and harmless.)

- [ ] **Step 8: Commit**

```bash
git add packaging/agent scripts/package-macos.sh
git rm packaging/TuxedoCapture.swift
git commit -m "refactor(agent): split capture into packaging/agent, rename to TuxedoAgent"
```

---

## Task 2: Pure summary logic + tests (TDD)

**Files:**
- Modify (fill in): `packaging/agent/Summary.swift`
- Create: `packaging/agent/tests/main.swift`

- [ ] **Step 1: Write the failing test** — create `packaging/agent/tests/main.swift`

```swift
import Foundation

func check(_ cond: Bool, _ label: String) {
    if !cond { print("FAIL: \(label)"); exit(1) }
}

// today = 2026-07-14. Task 1 overdue, 2 today, 3 future, 4 no-date, 5 done.
let tasks = [
    TodoTask(n: 1, raw: "(A) Ligar cliente due:2026-07-10", done: false, priority: "A", due: "2026-07-10"),
    TodoTask(n: 2, raw: "(B) Revisar due:2026-07-14",       done: false, priority: "B", due: "2026-07-14"),
    TodoTask(n: 3, raw: "Estudar due:2026-07-20",           done: false, priority: nil, due: "2026-07-20"),
    TodoTask(n: 4, raw: "Sem data",                          done: false, priority: nil, due: nil),
    TodoTask(n: 5, raw: "x concluida due:2026-07-10",       done: true,  priority: nil, due: "2026-07-10"),
]
let s = computeSummary(tasks, today: "2026-07-14")
check(s.overdue.count == 1, "overdue count == 1")
check(s.overdue.first?.n == 1, "overdue is task 1")
check(s.today.count == 1, "today count == 1")
check(s.today.first?.n == 2, "today is task 2")
check(s.actionable == 2, "actionable == 2")
check(s.iconState == .alert, "iconState alert when overdue present")

let onlyToday = computeSummary(
    [TodoTask(n: 2, raw: "b due:2026-07-14", done: false, priority: nil, due: "2026-07-14")],
    today: "2026-07-14")
check(onlyToday.iconState == .normal, "iconState normal when only today")

let empty = computeSummary([], today: "2026-07-14")
check(empty.iconState == .empty, "iconState empty when nothing")
check(empty.actionable == 0, "actionable 0 when empty")

print("ALL SUMMARY TESTS PASSED")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swiftc packaging/agent/Summary.swift packaging/agent/tests/main.swift -o /tmp/tuxedo-summary-tests && /tmp/tuxedo-summary-tests`
Expected: FAIL — compile error `cannot find 'TodoTask' in scope` / `computeSummary` undefined (Summary.swift is still just `import Foundation`).

- [ ] **Step 3: Implement `packaging/agent/Summary.swift`**

```swift
// Task model + the pure "what's due" logic. Foundation only so the test binary
// links without frameworks. Dates are ISO "YYYY-MM-DD" strings, which sort
// lexicographically — no Date parsing needed for overdue/today comparisons.
import Foundation

struct TodoTask: Decodable {
    let n: Int
    let raw: String
    let done: Bool
    let priority: String?
    let due: String?
    // The JSON has more fields (projects, contexts, rec, t, created,
    // completed); Decodable ignores keys we don't declare.
}

enum IconState { case empty, normal, alert }

struct Summary {
    let overdue: [TodoTask]
    let today: [TodoTask]
    var actionable: Int { overdue.count + today.count }
    var iconState: IconState {
        if !overdue.isEmpty { return .alert }
        if !today.isEmpty { return .normal }
        return .empty
    }
}

/// Pure: partition pending tasks into overdue (due < today) and due-today.
func computeSummary(_ tasks: [TodoTask], today: String) -> Summary {
    let pending = tasks.filter { !$0.done }
    let overdue = pending.filter { t in t.due.map { $0 < today } ?? false }
    let dueToday = pending.filter { $0.due == today }
    return Summary(overdue: overdue, today: dueToday)
}

/// Today as "YYYY-MM-DD" in the local time zone.
func todayString() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f.string(from: Date())
}

/// Side-effecting: run `tuxedo ls --json` and decode the pending task list.
/// Returns [] on any failure (missing binary, bad JSON) so the UI degrades to
/// an empty/neutral icon rather than crashing.
func fetchTasks() -> [TodoTask] {
    let p = Process()
    p.executableURL = resolveTuxedoBinary()
    p.arguments = ["ls", "--json"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (try? JSONDecoder().decode([TodoTask].self, from: data)) ?? []
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swiftc packaging/agent/Summary.swift packaging/agent/tests/main.swift -o /tmp/tuxedo-summary-tests && /tmp/tuxedo-summary-tests`
Expected: `ALL SUMMARY TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
git add packaging/agent/Summary.swift packaging/agent/tests/main.swift
git commit -m "feat(agent): pure due-date summary logic with tests"
```

---

## Task 3: MenuBarController — status item + menu rendering

Builds the visible menu bar item from a `Summary`. Actions are wired in Task 4.

**Files:**
- Replace: `packaging/agent/MenuBar.swift` (was the Task 1 stub)

- [ ] **Step 1: Implement the status item + rendering**

```swift
// Menu bar surface: an NSStatusItem showing the overdue+today count (amber when
// overdue) and a dropdown grouped into ATRASADAS / HOJE with check-to-complete.
import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onNewTask: () -> Void
    private var current = Summary(overdue: [], today: [])
    private let maxPerGroup = 5

    init(onNewTask: @escaping () -> Void) {
        self.onNewTask = onNewTask
        super.init()
    }

    func start() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    /// Re-fetch tasks and repaint the icon. Safe to call from any thread; hops
    /// to main for UI.
    func refresh() {
        let tasks = fetchTasks()
        let summary = computeSummary(tasks, today: todayString())
        DispatchQueue.main.async { [weak self] in
            self?.current = summary
            self?.renderIcon()
        }
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        switch current.iconState {
        case .empty:
            button.attributedTitle = NSAttributedString(
                string: "☰",
                attributes: [.foregroundColor: Theme.phosphorDim, .font: mono])
        case .normal:
            button.attributedTitle = NSAttributedString(
                string: "☰ \(current.actionable)",
                attributes: [.foregroundColor: Theme.phosphor, .font: mono])
        case .alert:
            button.attributedTitle = NSAttributedString(
                string: "☰ \(current.actionable)",
                attributes: [.foregroundColor: Theme.amber, .font: mono])
        }
    }

    // NSMenuDelegate: rebuild the menu right before it opens, from fresh data.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let tasks = fetchTasks()
        current = computeSummary(tasks, today: todayString())
        renderIcon()
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        addGroup(menu, title: "ATRASADAS", tasks: current.overdue, overdue: true)
        addGroup(menu, title: "HOJE", tasks: current.today, overdue: false)
        if current.actionable == 0 {
            let none = NSMenuItem(title: "Nada para hoje 🎉", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        // Actions are attached in Task 4; placeholders keep the layout visible.
        menu.addItem(NSMenuItem(title: "Abrir Tuxedo", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Nova tarefa…", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addGroup(_ menu: NSMenu, title: String, tasks: [TodoTask], overdue: Bool) {
        guard !tasks.isEmpty else { return }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for task in tasks.prefix(maxPerGroup) {
            menu.addItem(taskItem(task, overdue: overdue))
        }
        if tasks.count > maxPerGroup {
            let more = NSMenuItem(title: "  … +\(tasks.count - maxPerGroup) mais", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
    }

    /// A single task row: "☐ <text>   −Nd" for overdue, "☐ <text>" for today.
    private func taskItem(_ task: TodoTask, overdue: Bool) -> NSMenuItem {
        var label = "☐ " + displayText(task)
        if overdue, let d = task.due, let days = daysAgo(d) {
            label += "   −\(days)d"
        }
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.representedObject = task.raw   // used in Task 4 to re-locate the task
        return item
    }

    /// Strip the leading "(A) " priority and any "due:" token for a clean label.
    private func displayText(_ task: TodoTask) -> String {
        var s = task.raw
        if let p = task.priority { s = s.replacingOccurrences(of: "(\(p)) ", with: "") }
        s = s.replacingOccurrences(
            of: #"\s*due:\d{4}-\d{2}-\d{2}"#, with: "",
            options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func daysAgo(_ due: String) -> Int? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let d = f.date(from: due), let t = f.date(from: todayString()) else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: t).day
    }
}
```

- [ ] **Step 2: Build the whole agent to confirm it compiles**

Run: `./scripts/package-macos.sh`
Expected: builds and installs with no swiftc errors; the agent restarts.

- [ ] **Step 3: Verify the icon appears**

Look at the menu bar (top-right). Expect a `☰` glyph, followed by a count if any tasks are overdue/due today (amber if overdue, green if only today). Click it: the dropdown shows ATRASADAS / HOJE groups (or "Nada para hoje 🎉"), plus disabled "Abrir Tuxedo" / "Nova tarefa…" placeholders and an enabled "Sair".

- [ ] **Step 4: Commit**

```bash
git add packaging/agent/MenuBar.swift
git commit -m "feat(agent): menu bar status item with grouped task dropdown"
```

---

## Task 4: Interactions — complete, open, new task

**Files:**
- Modify: `packaging/agent/MenuBar.swift` (wire the actions)

- [ ] **Step 1: Add the action methods and target/action wiring**

In `MenuBar.swift`, replace the three placeholder lines in `rebuildMenu` (the `taskItem` `action:`, "Abrir Tuxedo", and "Nova tarefa…" items) so they target these methods, and add the methods to the class:

Replace `taskItem`'s creation line
`let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")`
with
```swift
        let item = NSMenuItem(title: label, action: #selector(completeTask(_:)), keyEquivalent: "")
        item.target = self
```

Replace the two placeholder action items in `rebuildMenu` with:
```swift
        let open = NSMenuItem(title: "Abrir Tuxedo", action: #selector(openTuxedo), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let new = NSMenuItem(title: "Nova tarefa…", action: #selector(newTask), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
```

Add these methods to the class:
```swift
    /// Complete a task. Anti-race: re-fetch and match by raw text (positions
    /// shift when the file changes), then `tuxedo done <current n>`.
    @objc private func completeTask(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        DispatchQueue.global().async { [weak self] in
            let fresh = fetchTasks()
            guard let match = fresh.first(where: { $0.raw == raw && !$0.done }) else {
                self?.refresh(); return
            }
            let p = Process()
            p.executableURL = resolveTuxedoBinary()
            p.arguments = ["done", String(match.n)]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            self?.refresh()
        }
    }

    @objc private func openTuxedo() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/Tuxedo.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func newTask() { onNewTask() }
```

- [ ] **Step 2: Build and install**

Run: `./scripts/package-macos.sh`
Expected: compiles, installs, agent restarts.

- [ ] **Step 3: Verify each interaction**

1. Add a task due today via ⌥] (type e.g. `Teste do menu hoje`), wait a moment.
2. Open the menu bar dropdown → the task appears under HOJE.
3. Click it (the ☐ row) → it should complete. Reopen the menu → it's gone and the count dropped.
4. Confirm in the file: `grep "Teste do menu" ~/tarefas.txt` shows a leading `x ` (done) — or it moved to done on archive.
5. Click **Nova tarefa…** → the ⌥] panel appears.
6. Click **Abrir Tuxedo** → the app opens.

- [ ] **Step 4: Commit**

```bash
git add packaging/agent/MenuBar.swift
git commit -m "feat(agent): complete-from-menu (anti-race), open app, new task"
```

---

## Task 5: Live refresh — file watch + midnight rollover

Without this, the count only updates when the menu opens. Add a file watcher and a midnight timer.

**Files:**
- Modify: `packaging/agent/MenuBar.swift`

- [ ] **Step 1: Add a DispatchSource file watch and midnight timer**

Add stored properties to `MenuBarController`:
```swift
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var midnightTimer: Timer?
```

Add these methods and call `startWatching()` and `scheduleMidnight()` at the end of `start()`:
```swift
    /// Watch TODO_FILE for external writes (TUI saves, CLI edits, inbox drains
    /// land here after merge). Editors that replace the file break the fd, so we
    /// re-arm on cancel.
    private func startWatching() {
        let path = resolveTodoFile().path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global())
        src.setEventHandler { [weak self] in
            self?.refresh()
            if let s = self, s.watchSource?.data.contains(.delete) == true
                || s.watchSource?.data.contains(.rename) == true {
                s.watchSource?.cancel()
            }
        }
        src.setCancelHandler { [weak self] in
            if let self, self.watchedFD >= 0 { close(self.watchedFD); self.watchedFD = -1 }
            // Atomic-save replaced the file: re-arm shortly.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startWatching()
            }
        }
        watchSource = src
        src.resume()
    }

    /// Recompute overdue/today when the date rolls over.
    private func scheduleMidnight() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        guard let next = cal.nextDate(after: Date(),
              matching: DateComponents(hour: 0, minute: 0, second: 5),
              matchingPolicy: .nextTime) else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.refresh()
            self?.scheduleMidnight()
        }
        RunLoop.main.add(t, forMode: .common)
        midnightTimer = t
    }
```

Update `start()` to:
```swift
    func start() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        startWatching()
        scheduleMidnight()
    }
```

- [ ] **Step 2: Build and install**

Run: `./scripts/package-macos.sh`
Expected: compiles and installs.

- [ ] **Step 3: Verify live refresh**

1. Note the current menu bar count.
2. In a terminal: `TODO_FILE="$HOME/tarefas.txt" /Applications/Tuxedo.app/Contents/Resources/tuxedo add "Refresh test due:$(date +%F)"`
3. Within ~1s the menu bar count should increase **without** opening the menu.
4. Complete it: `... tuxedo done <n>` (find n via `... tuxedo ls`) → count decreases live.

- [ ] **Step 4: Commit**

```bash
git add packaging/agent/MenuBar.swift
git commit -m "feat(agent): live refresh via file watch + midnight rollover"
```

---

## Task 6: Final end-to-end verification + docs (ships launcher fix too)

**Files:**
- Modify: `README.md` (document the menu bar feature)
- Modify: `scripts/update-from-upstream.sh` header comment only if needed (no code change expected)

- [ ] **Step 1: Full rebuild ships the launcher pgrep fix + the agent**

The launcher fix (`packaging/TuxedoLauncher.swift`, committed earlier) goes live with this same package run.

Run: `./scripts/package-macos.sh`
Then verify the launcher fix is now active — with no TUI open, the anchored pgrep must return nothing:
```bash
pgrep -f "/Applications/Tuxedo.app/Contents/Resources/tuxedo$" || echo "clean (no false positive)"
```
Expected: `clean (no false positive)` when the TUI isn't running.

- [ ] **Step 2: Re-run the summary unit tests**

Run: `swiftc packaging/agent/Summary.swift packaging/agent/tests/main.swift -o /tmp/tuxedo-summary-tests && /tmp/tuxedo-summary-tests`
Expected: `ALL SUMMARY TESTS PASSED`

- [ ] **Step 3: Run the Rust suite (guard against accidental breakage)**

Run: `cargo test`
Expected: all tests pass (same total as before this work, ~522).

- [ ] **Step 4: Manual acceptance pass**

- Click the Tuxedo Dock icon while a terminal is already open → the TUI opens (launcher bug fixed).
- Menu bar shows the count; amber iff there is an overdue task.
- Complete a task from the menu → count updates; nothing lost if the TUI is open (it flashes "file changed on disk — reloaded").
- ⌥] still opens the capture panel; "Nova tarefa…" opens the same panel.

- [ ] **Step 5: Document in README**

Add a short bullet under the fork's features describing the menu bar icon (count of overdue+today, amber alert, dropdown to review/complete, "Nova tarefa…"). Match the surrounding README style.

- [ ] **Step 6: Commit and push**

```bash
git add README.md
git commit -m "docs: document the menu bar agent"
git push origin main
```

---

## Self-Review Notes

- **Spec coverage:** icon count+amber (Task 3), dropdown groups + "+N mais" (Task 3), complete-from-menu anti-race (Task 4), open/new-task (Task 4), `tuxedo ls --json` source (Task 2), refresh file-watch + midnight + menuNeedsUpdate (Tasks 3 & 5), one-agent merge + rename + migration (Task 1), pure-logic tests (Task 2), concurrency-with-TUI (verified in spec; acceptance in Task 6). All covered.
- **Types:** `TodoTask`, `Summary`, `IconState`, `computeSummary`, `fetchTasks`, `todayString`, `MenuBarController(onNewTask:)`, `CapturePanel.start()/show()` are used consistently across tasks.
- **No placeholders** other than the explicitly-temporary Task 1 stubs (MenuBar stub, empty Summary.swift), each replaced in a named later task.
```
