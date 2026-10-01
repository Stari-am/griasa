import Foundation

// Checks for accepting a downloaded speech model. Accepting a bad one hands an
// altered file to a parser with a history of memory-safety bugs; rejecting a
// good one leaves somebody with no local transcription and no reason why.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runModelChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

let model = PinnedModel(fileName: "m.bin", url: URL(string: "https://example.com/r/abc123/m.bin")!,
                        sha256: "aabbcc", size: 10)

check(ModelManifest.verdict(size: 10, digest: { "aabbcc" }, expected: model) == .matches,
      rule: "the right size and the right digest are accepted",
      meaning: "a check that refuses the genuine file is a broken install for everybody",
      saw: "\(ModelManifest.verdict(size: 10, digest: { "aabbcc" }, expected: model))")

check(ModelManifest.verdict(size: 10, digest: { "AABBCC" }, expected: model) == .matches,
      rule: "digest comparison ignores letter case",
      meaning: "hex digests are printed in either case by different tools; that is not a mismatch",
      saw: "uppercase digest was rejected")

check(ModelManifest.verdict(size: 10, digest: { "aabbcd" }, expected: model) == .wrongDigest("aabbcd"),
      rule: "the right size with the wrong digest is refused",
      meaning: "this is the attack the check exists for — a replaced file the same length as the real one",
      saw: "\(ModelManifest.verdict(size: 10, digest: { "aabbcd" }, expected: model))")

var hashed = false
let short = ModelManifest.verdict(size: 7, digest: { hashed = true; return "aabbcc" }, expected: model)
check(short == .wrongSize(7) && !hashed,
      rule: "a file of the wrong size is refused before it is hashed",
      meaning: "a truncated download is the common failure, and finding it should not cost reading 1.6 GB",
      saw: "verdict \(short), hashed: \(hashed)")

check(ModelManifest.verdict(size: nil, digest: { "aabbcc" }, expected: model) == .unreadable
        && ModelManifest.verdict(size: 10, digest: { nil }, expected: model) == .unreadable,
      rule: "a file that cannot be read is never treated as verified",
      meaning: "\"couldn't check\" has to fail closed — otherwise an unreadable file is the easiest way past the check",
      saw: "an unreadable file was not reported as unreadable")

for pinned in ModelManifest.all {
    let path = pinned.url.path
    check(!path.contains("/resolve/main/") && path.contains("/resolve/") && path.hasSuffix(pinned.fileName),
          rule: "every model URL names a repository commit, not a branch",
          meaning: "a URL on main can change underneath the app — either breaking every new install against a stale hash, or checking nothing if the hash moves with it",
          saw: path)
    check(pinned.sha256.count == 64 && pinned.sha256.allSatisfy(\.isHexDigit) && pinned.size > 0,
          rule: "every pinned model carries a full SHA-256 and a size",
          meaning: "a truncated or empty expected value would make the comparison meaningless",
          saw: "\(pinned.fileName): \(pinned.sha256.count) hex chars, size \(pinned.size)")
}

// The streaming hash, against a value computed independently.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("griasa-sha-\(UUID().uuidString)")
try? Data("griasa".utf8).write(to: tmp)
let digest = ModelManifest.sha256(of: tmp)
try? FileManager.default.removeItem(at: tmp)
check(digest == "6e6bf291b4d997477b20b7a4fee9f7615bb4dc394e1d0ad8249bef11f98e2f33",
      rule: "the file hash is the standard SHA-256 of the file's bytes",
      meaning: "a hash that is consistent but not SHA-256 would never match the published value",
      saw: digest ?? "nil")

return failures
}
