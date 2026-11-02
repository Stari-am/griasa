#!/bin/zsh
# Builds the desktop widget extension into an app bundle:
#   Support/build-widget.sh <App.app> <arch> [<arch>…]
#
# Without Xcode, three things make a WidgetKit extension that macOS will load,
# each found the hard way:
#  - the executable starts at `_NSExtensionMain`, not Swift's `main` — with
#    `main` the extension traps in ExtensionFoundation on every launch and the
#    widget never reaches the gallery;
#  - Info.plist carries the platform and SDK keys Xcode adds (DTSDKName and
#    friends), or the widget service passes the extension by;
#  - the app is signed and, for anyone else's Mac, notarized — Gatekeeper's
#    verdict decides whether the widget is offered at all.
# Signing is left to the caller, extension first, then the app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"; shift
APPEX="$APP/Contents/PlugIns/GriasaWidget.appex"
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS" .build
SLICES=()
for arch in "$@"; do
    swiftc -O -parse-as-library -application-extension -target "${arch}-apple-macos14.0" \
        Widget/*.swift Sources/Griasa/WidgetSnapshot.swift \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -o ".build/GriasaWidget-$arch"
    SLICES+=(".build/GriasaWidget-$arch")
done
lipo -create "${SLICES[@]}" -output "$APPEX/Contents/MacOS/GriasaWidget"

# The same platform keys on the app itself, as Xcode writes them.
for P in "$APP/Contents/Info.plist"; do
    for key in DTPlatformName DTPlatformVersion DTSDKName DTSDKBuild CFBundleSupportedPlatforms; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$P" 2>/dev/null || true
    done
done

PLIST="$APPEX/Contents/Info.plist"
cp Support/Widget-Info.plist "$PLIST"
SDK_VERSION=$(xcrun --show-sdk-version)
SDK_BUILD=$(xcrun --show-sdk-build-version)
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $APP_ID.widget" \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD" \
    -c "Add :DTPlatformName string macosx" \
    -c "Add :DTPlatformVersion string $SDK_VERSION" \
    -c "Add :DTSDKName string macosx$SDK_VERSION" \
    -c "Add :DTSDKBuild string $SDK_BUILD" \
    "$PLIST" > /dev/null
/usr/libexec/PlistBuddy \
    -c "Add :DTPlatformName string macosx" \
    -c "Add :DTPlatformVersion string $SDK_VERSION" \
    -c "Add :DTSDKName string macosx$SDK_VERSION" \
    -c "Add :DTSDKBuild string $SDK_BUILD" \
    -c "Add :CFBundleSupportedPlatforms array" \
    -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" \
    "$APP/Contents/Info.plist" > /dev/null
