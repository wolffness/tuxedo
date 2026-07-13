#!/bin/zsh
# Package tuxedo as a macOS .app bundle and install it to /Applications.
#
# The bundle wraps the release binary in a native AppKit launcher that
# opens it in an iTerm2/Terminal window with the phosphor profile. The
# terminal session runs through the user's login shell, so TODO_FILE /
# TODO_DIR from dotfiles are honored; with neither set, tuxedo starts in
# $HOME (opening ~/todo.txt or the first-run welcome).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binary..."
cargo build --release

APP=dist/Tuxedo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp target/release/tuxedo "$APP/Contents/Resources/tuxedo"
cp packaging/tuxedo.icns "$APP/Contents/Resources/tuxedo.icns"
# Native quick-capture agent (⌥]): a tiny AppKit panel that appends to
# the inbox.txt sibling of TODO_FILE, kept alive by a per-user
# LaunchAgent. It lives in its OWN nested .app with its own bundle
# identifier — if it ran as a bare binary inside Tuxedo.app,
# LaunchServices would count it as "Tuxedo is already running" and
# Dock/Finder launches of the main app would fail with error -600.
echo "Building quick-capture agent..."
CAP="$APP/Contents/Resources/TuxedoCapture.app"
mkdir -p "$CAP/Contents/MacOS"
swiftc -O -o "$CAP/Contents/MacOS/TuxedoCapture" \
    packaging/TuxedoCapture.swift -framework AppKit -framework Carbon
cat > "$CAP/Contents/Info.plist" <<CAPPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tuxedo Capture</string>
    <key>CFBundleIdentifier</key>
    <string>dev.wolffness.tuxedo.capture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>TuxedoCapture</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
CAPPLIST

# The iTerm2-based capture profile is superseded by the native panel;
# remove it so ⌥] isn't registered twice.
rm -f "$HOME/Library/Application Support/iTerm2/DynamicProfiles/tuxedo-capture.json"

# Native launcher: a real AppKit executable, so the Dock icon stops
# bouncing (shell-script launchers never report "finished launching"),
# shows a running dot while the TUI is open, and refreshes the iTerm2
# profile with this bundle's binary path on every launch.
echo "Building launcher..."
swiftc -O -o "$APP/Contents/MacOS/tuxedo-launcher" \
    packaging/TuxedoLauncher.swift -framework AppKit

VERSION=$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)"/\1/')
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tuxedo</string>
    <key>CFBundleDisplayName</key>
    <string>Tuxedo</string>
    <key>CFBundleIdentifier</key>
    <string>dev.wolffness.tuxedo</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>tuxedo-launcher</string>
    <key>CFBundleIconFile</key>
    <string>tuxedo</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Tuxedo opens its task list in an iTerm2 or Terminal window.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"

# Install to /Applications and drop the staging copy so only one Tuxedo.app
# exists on the machine (a stray dist copy kept showing up in Finder search).
rm -rf /Applications/Tuxedo.app
cp -R "$APP" /Applications/
rm -rf "$APP"
touch /Applications/Tuxedo.app

# LaunchAgent: start the capture panel at login and keep it running.
AGENT="$HOME/Library/LaunchAgents/dev.wolffness.tuxedo.capture.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.wolffness.tuxedo.capture</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Tuxedo.app/Contents/Resources/TuxedoCapture.app/Contents/MacOS/TuxedoCapture</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
AGENTPLIST
launchctl bootout "gui/$(id -u)/dev.wolffness.tuxedo.capture" 2>/dev/null || true
pkill -f "Resources/TuxedoCapture" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$AGENT" || \
    launchctl kickstart -k "gui/$(id -u)/dev.wolffness.tuxedo.capture" || true
echo "Installed: /Applications/Tuxedo.app (+ capture agent on ⌥])"
