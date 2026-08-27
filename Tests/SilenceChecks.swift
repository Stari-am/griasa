import Foundation

// Checks for the silence watch. The thing being protected against is not a
// crash: it is a recording that stops itself while somebody is still talking,
// which would lose a meeting and be blamed on the app forever. So the case
// given the most attention here is "sound came back while the question was on
// screen".
//
// The check helper is duplicated from StabilizerChecks rather than shared,
// because these two files are meant to be readable on their own and the helper
// is eight lines.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runSilenceChecks() -> Int {
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

// ── Levels ───────────────────────────────────────────────────────────────────

// log10(0) is -infinity, and -infinity compared against a threshold behaves
// differently from a number depending on which side you write it. A floor keeps
// every caller comparing two ordinary Floats.
do {
    let silence = [Float](repeating: 0, count: 512)
    let level = AudioLevel.dBFS(silence)
    check(level.isFinite && level <= AudioLevel.floor,
          rule: "digital silence reports a finite floor, not -infinity",
          meaning: "a non-finite level makes the speech threshold comparison unpredictable, "
                 + "so a silent room might read as speech or as nothing depending on the compiler",
          saw: "dBFS(all zeroes) = \(level)")
}

do {
    let fullScale = [Float](repeating: 1, count: 512)
    let level = AudioLevel.dBFS(fullScale)
    check(abs(level) < 0.001,
          rule: "a full-scale signal reports 0 dBFS",
          meaning: "if the scale is wrong every threshold in the feature is wrong, and the "
                 + "numbers in the settings screen stop meaning anything",
          saw: "dBFS(all ones) = \(level)")
}

// The microphone and the system-audio stream do not have to arrive in the same
// format. One threshold has to mean the same loudness in both, or the watch
// fires on one input and never on the other.
do {
    var floats: [Float] = []
    var ints: [Int16] = []
    for i in 0..<512 {
        let sample = Float(sin(Double(i) * 0.05)) * 0.1   // about -23 dBFS
        floats.append(sample)
        ints.append(Int16(sample * Float(Int16.max)))
    }
    let asFloat = AudioLevel.dBFS(floats)
    let asInt = ints.withUnsafeBufferPointer { AudioLevel.dBFS($0.baseAddress!, count: $0.count) }
    check(abs(asFloat - asInt) < 0.1,
          rule: "the same signal measures the same in Float and Int16",
          meaning: "otherwise the threshold means one loudness for the microphone and another "
                 + "for the Mac's own audio, and the watch fires on only one of the two inputs",
          saw: "float \(asFloat) dBFS vs int16 \(asInt) dBFS")
}

do {
    let roomTone = [Float](repeating: 0.00316, count: 512)   // about -50 dBFS
    let speech = [Float](repeating: 0.056, count: 512)       // about -25 dBFS
    let toneLevel = AudioLevel.dBFS(roomTone)
    let speechLevel = AudioLevel.dBFS(speech)
    check(toneLevel < AudioLevel.speechThreshold && speechLevel >= AudioLevel.speechThreshold,
          rule: "room tone is silence and speech is not",
          meaning: "a threshold below room tone keeps a recording alive all night, which is the "
                 + "bug this feature exists to stop; one above speech stops a live meeting",
          saw: "room tone \(toneLevel) dBFS, speech \(speechLevel) dBFS, "
             + "threshold \(AudioLevel.speechThreshold)")
}

// ── The decision ─────────────────────────────────────────────────────────────

let clock = SilenceClock(silenceAfter: 300, replyWithin: 120)

// THE important one. Someone stops talking, the question appears, and then the
// meeting resumes. Whatever else happens, the recording must not stop.
do {
    let decision = clock.decide(silentFor: 4, asking: 119)
    check(decision == .keepWatching,
          rule: "speech resuming while the question is up cancels it",
          meaning: "stopping a recording that is capturing speech again would lose a meeting "
                 + "that was in progress — the worst thing this feature could do",
          saw: "decided \(decision) with 4s of silence and the question up for 119s")
}

do {
    let decision = clock.decide(silentFor: 301, asking: nil)
    check(decision == .ask,
          rule: "silence past the configured wait asks the question",
          meaning: "without this the watch never triggers and an unattended recording runs "
                 + "until the disk or the battery gives up",
          saw: "decided \(decision) after 301s of silence with no question showing")
}

do {
    let decision = clock.decide(silentFor: 400, asking: 119)
    check(decision == .ask,
          rule: "the question keeps showing while its own time is still running",
          meaning: "a question that disappears before the countdown ends takes the user's "
                 + "chance to answer with it",
          saw: "decided \(decision) with the question up for 119s of an allowed 120s")
}

do {
    let decision = clock.decide(silentFor: 400, asking: 120)
    check(decision == .stopAutomatically,
          rule: "an unanswered question stops the recording when its time is up",
          meaning: "this is the whole point: nobody is at the machine, so nobody will ever "
                 + "press the button",
          saw: "decided \(decision) with the question up for exactly the allowed 120s")
}

// Just under the wait must not ask. Off-by-one here means the question appears
// a minute early on every setting.
do {
    let decision = clock.decide(silentFor: 299, asking: nil)
    check(decision == .keepWatching,
          rule: "silence just short of the configured wait does not ask",
          meaning: "the number in settings has to be the number that happens, or the setting "
                 + "is decoration",
          saw: "decided \(decision) after 299s of an allowed 300s")
}

return failures
}
