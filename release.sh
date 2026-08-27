#!/bin/zsh
# Builds the signed, notarized Griasa.dmg for sale — the build a stranger can
# double-click without macOS getting in the way.
#
# Difference from ./dist.sh: that one ad-hoc signs, so recipients must
# right-click → Open on first launch. This one uses your Developer ID, enables
# Hardened Runtime, and gets an Apple notarization ticket stapled to both the
# app and the disk image, so Gatekeeper lets it open normally — offline too.
#
#   ./release.sh
#
# Requires, once:
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. A stored notarization credential:
#        xcrun notarytool store-credentials griasa-notary \
#          --apple-id you@example.com --team-id TEAMID --password app-specific-pw
#
# Overridable:
#   DIST_SIGN_IDENTITY   signing identity (default: the only Developer ID found)
#   NOTARY_PROFILE       notarytool keychain profile   (default: griasa-notary)
#   RELEASE_BUNDLE_ID    bundle id for this build only (default: keep Info.plist)
#
# RELEASE_BUNDLE_ID is applied to the copy inside dist/ and never to
# Support/Info.plist, so your local dev build keeps its identity — and with it
# the privacy permissions macOS has already granted it.
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-griasa-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DIST="dist"
APP="$DIST/Griasa.app"
DMG="$DIST/Griasa-$VERSION.dmg"

die() { print -u2 "release.sh: $1"; exit 1 }

# ── Preflight: fail here, with an instruction, rather than half way through ──

if [[ -n "${DIST_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$DIST_SIGN_IDENTITY"
else
    # `|| true`: no match makes grep exit 1, and under pipefail that would kill
    # the script before it could explain what's missing.
    MATCHES=$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)
    [[ -n "$MATCHES" ]] || die "no \"Developer ID Application\" certificate in the keychain.
  Create one: developer.apple.com → Certificates → + → Developer ID Application.
  Choose the G2 Sub-CA — certificates issued off the older intermediate expire
  when it does, on 2027-02-01, however long you have owned the account. Upload a
  CSR made in Keychain Access, then import the downloaded .cer with:
    security import ~/Downloads/developerID_application.cer \\
      -k ~/Library/Keychains/login.keychain-db
  Double-clicking it usually fails with -25294: Keychain Access aims the import
  at \"Local Items\" rather than the login keychain, and reports it as if the
  certificate were at fault. A G2 certificate also needs the G2 intermediate,
  which is not bundled with it — without that, codesign refuses with \"unable to
  build chain to self-signed root\" and errSecInternalComponent:
    curl -fsSL -o /tmp/DeveloperIDG2CA.cer \\
      https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
    security import /tmp/DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db
  Verify with: security find-identity -v -p codesigning"

    # Reissued Developer ID certificates carry the *same* common name, so a name
    # is not a unique handle and `codesign --sign "<name>"` refuses when two
    # match. Sign by SHA-1 hash, and refuse to guess when several qualify —
    # taking the first would silently decide which certificate ships.
    if [[ $(print -- "$MATCHES" | wc -l) -gt 1 ]]; then
        die "more than one \"Developer ID Application\" identity in the keychain:
$MATCHES
  These usually share a common name, so name one by its SHA-1 hash instead:
    DIST_SIGN_IDENTITY=<hash> ./release.sh"
    fi
    IDENTITY=$(print -- "$MATCHES" | sed -E 's/^[[:space:]]*[0-9]+\) ([0-9A-F]+).*/\1/')
fi

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarization credential \"$NOTARY_PROFILE\" not stored, or not usable.
  Store it: xcrun notarytool store-credentials $NOTARY_PROFILE \\
              --apple-id you@example.com --team-id TEAMID --password app-specific-pw
  App-specific passwords are made at appleid.apple.com → Sign-In and Security."

[[ -f Support/Griasa.entitlements ]] || die "Support/Griasa.entitlements is missing."

# Show when the signing certificate stops working. One issued off the retiring
# G1 intermediate is capped at 2027-02-01 no matter when you bought the account,
# and that is better noticed here than on the day a build refuses to sign.
# `|| true`: a keychain lookup that finds nothing must not abort the release.
CERT_EXPIRY=$(security find-certificate -c "Developer ID Application" -p 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || true)

print "Identity : $IDENTITY"
if [[ -n "$CERT_EXPIRY" ]]; then print "Expires  : $CERT_EXPIRY"; fi
print "Notary   : $NOTARY_PROFILE"
print "Version  : $VERSION"
print

# ── Invariant checks, before anything expensive ──
#
# The rules live typing must never break are checked here rather than described
# in a comment, because a comment cannot fail a build. This runs before the
# notarization round trips: finding a broken invariant after two trips to Apple
# is the expensive way to find out.

print "Checking invariants…"
if ! ./test.sh; then
    die "invariant checks failed — the message above names the rule that broke. Not shipping this."
fi
print

# ── Build: universal, so Intel Macs are not excluded from the sale ──

print "Building universal binary (arm64 + x86_64)…"
mkdir -p .build "$DIST"
rm -rf "$APP" "$DMG"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    Sources/Griasa/*.swift -o .build/Griasa-arm64
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 \
    Sources/Griasa/*.swift -o .build/Griasa-x86_64
lipo -create .build/Griasa-arm64 .build/Griasa-x86_64 -output .build/Griasa-universal

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/Griasa-universal "$APP/Contents/MacOS/Griasa"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${RELEASE_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RELEASE_BUNDLE_ID" "$APP/Contents/Info.plist"
    print "Bundle id: $RELEASE_BUNDLE_ID (this build only)"
else
    CURRENT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
    print "Bundle id: $CURRENT_ID"
    [[ "$CURRENT_ID" == local.* ]] && print -u2 "  warning: \"$CURRENT_ID\" is a local development id.
  Ship a real reverse-DNS id you own, e.g. RELEASE_BUNDLE_ID=am.stari.griasa ./release.sh"
fi

# ── Sign: Hardened Runtime + a secure timestamp, both required to notarize ──

print "Signing…"
codesign --force --sign "$IDENTITY" \
    --options runtime \
    --entitlements Support/Griasa.entitlements \
    --timestamp \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ── Notarize the app, then staple, so the ticket travels inside the app ──

print "Notarizing app (Apple usually answers in 1–5 minutes)…"
ZIP="$DIST/Griasa-$VERSION-app.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# ── Package, then notarize the image too, so it validates before mounting ──

print "Creating DMG…"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Griasa $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

# Sign the image too — the outermost container is the thing a customer's Mac
# evaluates, and notarization does not stand in for a signature. An unsigned
# image still notarizes and still takes a ticket, so nothing here complains;
# `spctl` then rejects it with "no usable signature" at the very end, after both
# trips to Apple have already been spent. No Hardened Runtime or entitlements:
# those describe a running program, and a disk image does not run.
print "Signing DMG…"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

print "Notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# ── Verify the way a customer's Mac will, not the way the build hopes ──
#
# Every check runs even when an earlier one fails. Under `set -e` the first
# rejection aborted the script, which hid the remaining verdicts and made a real
# verification failure look indistinguishable from a crash — with both trips to
# Apple already paid for. Failures are collected and named at the end instead.

print
# ── Do the entitlements match what the code actually calls? ──
#
# The bug this exists for: EventKit is refused under Hardened Runtime unless the
# entitlement is declared, and three releases shipped without it. Nothing caught
# it, because the only place it can fail is the signed artifact — a local build
# has no Hardened Runtime, so every test on this machine passed.
#
# So the check reads the *signature of the thing about to ship* and compares it
# against what the source imports. Each row is: if the code uses this, the
# signature must declare that. Adding an API that needs a new entitlement fails
# the release until it is declared — which is the opposite of a comment claiming
# no entitlement is needed.
print "Checking entitlements against what the code calls…"
SIGNED_ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null)

needs() {  # <grep pattern over Sources> <entitlement key> <what breaks without it>
    local pattern="$1" key="$2" feature="$3"
    grep -rqE "$pattern" Sources/Griasa/*.swift || return 0
    if ! print -- "$SIGNED_ENTITLEMENTS" | grep -q "\"$key\""; then
        print
        print "  The code uses $pattern but the signature does not declare $key."
        print "  Without it macOS refuses the call even after the user grants permission,"
        print "  so $feature would ship dead. This is what happened in 1.0 through 1.02."
        die "entitlement missing — not shipping this."
    fi
    print "  ok  $key — required by $pattern"
}

needs "import EventKit"        "com.apple.security.personal-information.calendars" "free-slot snippets and the pre-meeting brief"
needs "EKReminder|EKEntityType.reminder" "com.apple.security.personal-information.reminders" "Remind me"
needs "AVAudioEngine|AVCaptureDevice" "com.apple.security.device.audio-input" "dictation and meeting recording"
needs "NSAppleScript|osascript"  "com.apple.security.automation.apple-events" "the link back to a browser tab in a reminder"
print

# An entitlement is only half of a permission. The other half is somebody
# actually asking for it, and the pre-meeting brief shipped for four releases
# without that: it checked authorizationStatus on a timer, deliberately never
# prompted, and nothing else on the launch path requested calendar access — so
# the feature was on by default and silently dead, and the app never appeared
# under Privacy & Security → Calendars for the user to fix it by hand.
#
# The rule is about automatic features only. "Remind me" and the {slots} snippet
# ask at the moment they are used, which is the right design and is not checked
# here — a user who presses the shortcut is present for the dialog. What must be
# on the launch path is the permission for anything that runs on its own, because
# there is no moment of use to hang a request on. Checked by grep, because the
# failure was never in the logic.
asks() {  # <status check pattern> <request pattern> <what breaks without it>
    local gate="$1" request="$2" feature="$3"
    grep -rqE "$gate" Sources/Griasa/*.swift || return 0
    # Comment lines stripped first. Without that, the paragraph explaining why
    # this check exists would satisfy the check — and a grep that its own
    # documentation can satisfy is not a check.
    if ! sed -E 's|//.*||' Sources/Griasa/Permissions.swift | grep -qE "$request"; then
        print
        print "  Something is gated on $gate, but Permissions.swift never asks for it."
        print "  A status check with no request is a feature that can never turn on:"
        print "  $feature would ship dead, and macOS would not list the app in"
        print "  Privacy & Security, so the user could not grant it either."
        die "permission never requested — not shipping this."
    fi
    print "  ok  $feature — gated on $gate and requested in Permissions.swift"
}

asks "authorizationStatus\(for: \.event\)" "requestFullAccessToEvents" "the pre-meeting brief"
print

print "Verification:"
FAILED=()
verify() {
    local label="$1"; shift
    local out
    out=$("$@" 2>&1) || FAILED+=("$label")
    print -- "$out" | sed "s|^|  $label: |"
}

verify app    spctl --assess --type execute --verbose=4 "$APP"
verify dmg    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
verify ticket xcrun stapler validate "$DMG"
verify arches lipo -archs "$APP/Contents/MacOS/Griasa"

if (( ${#FAILED[@]} )); then
    print
    die "verification failed (${FAILED[*]}) — this build is not fit to sell."
fi

# The staged .app has done its job — it exists to be signed, notarized and
# verified, and the disk image is the artifact. Leaving it behind puts a second
# "Griasa" in Spotlight and in Launch Services with the same name and icon as the
# installed one, which is exactly the confusion this release fixed elsewhere.
# Removed only after verification passed, so a failed run leaves it for inspection.
rm -rf "$APP"

print
print "Ready to ship:"
ls -lh "$DMG"
print
print "The staged app bundle was removed; the disk image above is the artifact."
