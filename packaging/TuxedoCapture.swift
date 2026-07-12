// Tuxedo quick-capture: a tiny native agent that shows a floating
// phosphor-green entry panel on ⌥] (OmniFocus-style) and appends each line
// to the inbox.txt sibling of TODO_FILE. tuxedo drains the inbox with
// natural-language parsing. Compiled and installed by package-macos.sh;
// kept alive by a LaunchAgent.
import AppKit
import Carbon.HIToolbox

let phosphor = NSColor(srgbRed: 0.20, green: 1.00, blue: 0.20, alpha: 1.0)
let phosphorDim = NSColor(srgbRed: 0.11, green: 0.56, blue: 0.11, alpha: 1.0)
let screenBg = NSColor(srgbRed: 0.008, green: 0.04, blue: 0.008, alpha: 0.97)

/// Borderless panels refuse key status unless told otherwise.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Capture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var panel: KeyPanel!
    var field: NSTextField!
    var inbox: URL!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        inbox = resolveInbox()
        buildPanel()
        registerHotkey()
    }

    /// TODO_FILE comes from the user's login shell (LaunchAgents get no
    /// shell environment), falling back to ~/todo.txt.
    func resolveInbox() -> URL {
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
        return todo.deletingLastPathComponent().appendingPathComponent("inbox.txt")
    }

    func buildPanel() {
        let w: CGFloat = 560
        let h: CGFloat = 64
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = screenBg.cgColor
        root.layer?.cornerRadius = 10
        root.layer?.borderWidth = 1.5
        root.layer?.borderColor = phosphorDim.cgColor

        let mono = NSFont(name: "IBMPlexMono-Regular", size: 18)
            ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)

        let prompt = NSTextField(labelWithString: ">")
        prompt.font = mono
        prompt.textColor = phosphor
        prompt.frame = NSRect(x: 18, y: (h - 26) / 2, width: 20, height: 26)
        root.addSubview(prompt)

        field = NSTextField(frame: NSRect(x: 44, y: (h - 26) / 2, width: w - 62, height: 26))
        field.font = mono
        field.textColor = phosphor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: "nova tarefa… (amanhã, toda sexta, todo dia 2)",
            attributes: [.foregroundColor: phosphorDim, .font: mono]
        )
        field.delegate = self
        root.addSubview(field)

        panel.contentView = root
    }

    func registerHotkey() {
        // ⌥] — key code 30, option modifier. Carbon hotkeys need no
        // accessibility permission.
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5458_4344), id: 1) // "TXCD"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_RightBracket),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                let me = Unmanaged<Capture>.fromOpaque(userData!).takeUnretainedValue()
                me.toggle()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // Top third of the screen with the mouse, centered — the OmniFocus
        // quick-entry spot.
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let x = f.midX - panel.frame.width / 2
            let y = f.minY + f.height * 0.72
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        field.stringValue = ""
        field.becomeFirstResponder()
    }

    func hide() {
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy sel: Selector
    ) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            save()
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    func save() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let line = text + "\n"
            if let handle = try? FileHandle(forWritingTo: inbox) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: inbox)
            }
        }
        hide()
    }
}

let app = NSApplication.shared
let delegate = Capture()
app.delegate = delegate
app.run()
