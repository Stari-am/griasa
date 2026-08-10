#!/bin/zsh
# Builds a distributable Griasa.dmg for colleagues:
# universal binary (Apple Silicon + Intel), app icon, ad-hoc signature,
# DMG with /Applications shortcut and install instructions.
#
# Note: without an Apple Developer ID certificate the app can't be notarized,
# so recipients must right-click → Open on first launch (see INSTALL.txt).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DIST="dist"
APP="$DIST/Griasa.app"

echo "Building universal binary (arm64 + x86_64)…"
mkdir -p .build "$DIST"
rm -rf "$APP"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    Sources/Griasa/*.swift -o .build/Griasa-arm64
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 \
    Sources/Griasa/*.swift -o .build/Griasa-x86_64
lipo -create .build/Griasa-arm64 .build/Griasa-x86_64 -output .build/Griasa-universal

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/Griasa-universal "$APP/Contents/MacOS/Griasa"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature by default: identical for every recipient, so their
# privacy grants stick. With an Apple Developer ID (removes the
# right-click-to-open step after notarization), run:
#   DIST_SIGN_IDENTITY="Developer ID Application: You (TEAMID)" ./dist.sh
codesign --force --sign "${DIST_SIGN_IDENTITY:--}" "$APP"

cat > "$DIST/INSTALL.txt" <<'EOF'
MURMUR — INSTALL
================

1. Drag Griasa.app to Applications.

2. First launch: RIGHT-CLICK Griasa.app → Open → Open.
   (Required once — the app isn't notarized by Apple. If macOS still blocks
   it: System Settings → Privacy & Security → "Open Anyway".)

3. Grant the four permissions when asked (all required):
   Microphone, Speech Recognition, Accessibility, Screen Recording.
   Then quit and relaunch Griasa once.

4. First launch also auto-installs the Whisper speech engine:
   - needs Homebrew (https://brew.sh) — the menu will tell you if it's missing
   - downloads the speech model (~1.6 GB, progress shown in the menu)
   Until it finishes, the app works with Apple's built-in recognizer.

5. Optional but recommended: menu bar icon → Settings → AI formatting →
   paste an Anthropic API key. This enables dictation cleanup, meeting
   summaries with action items, and the selected-text tools.

WHAT IT DOES
------------
• Hold RIGHT OPTION (⌥) and speak — text types live into any app,
  then self-corrects to a polished version on release. RU/EN auto-detected.
• Menu → Start Recording — records mic + system audio (calls);
  on stop you get meeting notes with a summary and action items.
• Select text anywhere: ⌃⌥⌘S = summary popup, ⌃⌥⌘G = grammar fix popup (hotkeys configurable in Settings).

Recordings and transcripts: ~/Documents/Griasa Recordings/
Remember: recording calls may require consent of all participants.
EOF

echo "Creating DMG…"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE" "$DIST/Griasa-$VERSION.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$DIST/INSTALL.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Griasa $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST/Griasa-$VERSION.dmg" > /dev/null
rm -rf "$STAGE"

echo
echo "Done:"
ls -lh "$DIST/Griasa-$VERSION.dmg"
lipo -archs "$APP/Contents/MacOS/Griasa"
