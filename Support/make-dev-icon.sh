#!/bin/zsh
# Regenerates Support/AppIcon-dev.icns from Support/AppIcon.icns. Only needed
# when the real icon changes — the result is committed, so a normal build does
# not run this.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="${TMPDIR:-/tmp}/griasa-dev-icon"
rm -rf "$WORK"; mkdir -p "$WORK"

iconutil --convert iconset --output "$WORK/in.iconset" Support/AppIcon.icns
swiftc -O Support/make-dev-icon.swift -o "$WORK/stamp"
print "Stamping:"
"$WORK/stamp" "$WORK/in.iconset" "$WORK/out.iconset"
iconutil --convert icns --output Support/AppIcon-dev.icns "$WORK/out.iconset"
rm -rf "$WORK"

print
print "Wrote Support/AppIcon-dev.icns ($(du -h Support/AppIcon-dev.icns | cut -f1))"
