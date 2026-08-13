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

# A local build gets its own identity: bundle identifier, name and icon.
#
# The identifier is the important one, and sharing it was a mistake worth
# recording. Both builds used to be am.stari.griasa, on the theory that one
# identifier keeps the privacy grants. TCC actually stores a grant against the
# identifier *and the code requirement it saw*, and these two builds are signed
# by different certificates — so whichever ran last owned the record, the other
# was re-prompted every launch, and neither ever worked reliably. The system log
# says it plainly: "Failed to match existing code requirement for subject
# am.stari.griasa".
#
# Separate identifiers cost one round of permission prompts for the local build,
# once, and then the two never interfere again. Settings are not shared either;
# copy them across if you want them:
#   defaults export am.stari.griasa - | defaults import am.stari.griasa.dev -
cp Support/AppIcon-dev.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier am.stari.griasa.dev" \
                        -c "Set :CFBundleName Griasa Dev" \
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
