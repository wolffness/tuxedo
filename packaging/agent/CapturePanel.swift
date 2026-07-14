import AppKit
import Carbon.HIToolbox

/// Borderless panels refuse key status unless told otherwise.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CapturePanel: NSObject, NSTextFieldDelegate {
    var panel: KeyPanel!
    var field: NSTextField!
    var inbox: URL!

    func start() {
        inbox = resolveInbox()
        buildPanel()
        registerHotkey()
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
        root.layer?.backgroundColor = Theme.screenBg.cgColor
        root.layer?.cornerRadius = 10
        root.layer?.borderWidth = 1.5
        root.layer?.borderColor = Theme.phosphorDim.cgColor

        let mono = NSFont(name: "IBMPlexMono-Regular", size: 18)
            ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)

        let prompt = NSTextField(labelWithString: ">")
        prompt.font = mono
        prompt.textColor = Theme.phosphor
        prompt.frame = NSRect(x: 18, y: (h - 26) / 2, width: 20, height: 26)
        root.addSubview(prompt)

        field = NSTextField(frame: NSRect(x: 44, y: (h - 26) / 2, width: w - 62, height: 26))
        field.font = mono
        field.textColor = Theme.phosphor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: "nova tarefa… (amanhã, toda sexta, todo dia 2)",
            attributes: [.foregroundColor: Theme.phosphorDim, .font: mono]
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
                let me = Unmanaged<CapturePanel>.fromOpaque(userData!).takeUnretainedValue()
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
