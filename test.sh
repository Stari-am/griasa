#!/bin/zsh
# Runs the invariant checks. Compiles with swiftc directly, like build.sh, so it
# works on a machine with only the Command Line Tools and needs no test
# framework — the point is that a broken rule fails a command, not that there is
# a test target.
#
# release.sh runs this first and refuses to build if it fails.
set -e
cd "$(dirname "$0")"

BIN="${TMPDIR:-/tmp}/griasa-checks"

# Only the units under test, plus whatever they need. PartialStabilizer imports
# nothing but Foundation, which is what makes it testable in isolation.
swiftc -O \
  Sources/Griasa/PartialStabilizer.swift \
  Sources/Griasa/SilenceLevel.swift \
  Sources/Griasa/PersonIdentity.swift \
  Tests/StabilizerChecks.swift \
  Tests/SilenceChecks.swift \
  Tests/IdentityChecks.swift \
  Tests/main.swift \
  -o "$BIN"

"$BIN"
