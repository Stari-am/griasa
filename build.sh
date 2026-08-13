#!/bin/zsh
# Builds Griasa.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

# Note: compiled with swiftc directly rather than through SwiftPM, so the build
# works on a machine with only the standalone Command Line Tools — some of those
# installs ship a broken SwiftPM manifest library. Package.swift describes the
# same build and `swift build` works under full Xcode.
echo "Building (release)…"
mkdir -p .build
ARCH="$(uname -m)"
swiftc -O -parse-as-library -target "${ARCH}-apple-macos14.0" \
    Sources/Griasa/*.swift -o .build/Griasa

APP="Griasa.app"
BIN=".build/Griasa"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Griasa"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Make a local build say so. Both copies carry the same bundle identifier — that
# is deliberate, since it keeps the privacy grants — but it also means macOS
# cannot tell them apart in Privacy settings, Activity Monitor or Force Quit.
# So this build gets the amber DEV icon and its own display name, and marks
# itself so the menu-bar icon differs too. release.sh does none of this.
cp Support/AppIcon-dev.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Griasa Dev" \
                        -c "Set :CFBundleDisplayName Griasa Dev" \
                        -c "Add :GriasaDevBuild bool true" \
                        "$APP/Contents/Info.plist" > /dev/null

# Sign with a stable local identity so macOS privacy grants (mic, screen
# recording, accessibility) survive rebuilds — an ad-hoc signature changes
# every build and makes TCC treat each build as a new app.
# Override with your own certificate:  CODESIGN_IDENTITY="My Cert" ./build.sh
# (create one in Keychain Access → Certificate Assistant → Create a
#  Certificate → type "Code Signing", any name.)
# The rename left the existing local certificate still called "Murmur Dev
# Signing" — a keychain certificate's name can't be edited, only replaced. Any
# stable name works, so try the new one first and fall back to the old rather
# than dropping to ad-hoc, which would reset permissions on every single build.
# Make a "Griasa Dev Signing" certificate whenever you like and it takes over.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    CANDIDATES=("$CODESIGN_IDENTITY")
else
    CANDIDATES=("Griasa Dev Signing" "Murmur Dev Signing")
fi
IDENTITY=""
for candidate in "${CANDIDATES[@]}"; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
        IDENTITY="$candidate"
        break
    fi
done
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: none of ${CANDIDATES[*]} found — ad-hoc signing (permissions will reset on each rebuild)"
    codesign --force --sign - "$APP"
fi

echo
echo "Built $PWD/$APP"
echo "Run:  open $APP"
