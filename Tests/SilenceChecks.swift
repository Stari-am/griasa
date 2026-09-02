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
    let decision = clock.decide(silentFor: 0.1, soundRun: 6, asking: 119)
    check(decision == .keepWatching,
          rule: "speech resuming while the question is up cancels it",
          meaning: "stopping a recording that is capturing speech again would lose a meeting "
                 + "that was in progress — the worst thing this feature could do",
          saw: "decided \(decision) with sound arriving now after 6s of it, question up 119s")
}

// The bug this rule exists for, with the number that was measured rather than
// imagined. The question plays an alert sound to reach somebody in another
// room; that sound comes back through the system-audio capture at -16.9 dBFS,
// far above the speech threshold. Funk, the longest alert sound macOS ships, is
// 2.163458 s. If a stretch of sound that short counts as the conversation
// resuming, the question dismisses itself about a second after appearing —
// which is exactly what it did, once a minute, unclickable.
do {
    let decision = clock.decide(silentFor: 0.2, soundRun: 2.163458, asking: 3)
    check(decision == .ask,
          rule: "the question's own beep does not dismiss the question",
          meaning: "a question that erases itself before it can be read is worse than no "
                 + "question: the recording keeps running and the user is told nothing",
          saw: "decided \(decision) with 2.16s of sound — the longest macOS alert sound")
}

// Any short noise, not just ours: a notification chime, a door, a cough. The
// old rule treated one loud buffer from any source as a meeting resuming.
do {
    let decision = clock.decide(silentFor: 0.1, soundRun: 0.4, asking: 30)
    check(decision == .ask,
          rule: "one short noise is not a conversation resuming",
          meaning: "otherwise any chime in earshot cancels the question and the unattended "
                 + "recording carries on, which is the failure this feature exists to stop",
          saw: "decided \(decision) with a 0.4s noise while the question was up 30s")
}

// A long stretch of sound that finished a while ago is not sound now. Without
// this the last conversation of the day would keep the question off screen
// forever.
do {
    let decision = clock.decide(silentFor: 30, soundRun: 60, asking: 5)
    check(decision == .ask,
          rule: "a run of sound that has already ended does not count as talking",
          meaning: "the watch would otherwise be disarmed permanently by the fact that people "
                 + "did once speak during the recording",
          saw: "decided \(decision) with a 60s run that ended 30s ago")
}

do {
    let decision = clock.decide(silentFor: 301, soundRun: 0, asking: nil)
    check(decision == .ask,
          rule: "silence past the configured wait asks the question",
          meaning: "without this the watch never triggers and an unattended recording runs "
                 + "until the disk or the battery gives up",
          saw: "decided \(decision) after 301s of silence with no question showing")
}

do {
    let decision = clock.decide(silentFor: 400, soundRun: 0, asking: 119)
    check(decision == .ask,
          rule: "the question keeps showing while its own time is still running",
          meaning: "a question that disappears before the countdown ends takes the user's "
                 + "chance to answer with it",
          saw: "decided \(decision) with the question up for 119s of an allowed 120s")
}

do {
    let decision = clock.decide(silentFor: 400, soundRun: 0, asking: 120)
    check(decision == .stopAutomatically,
          rule: "an unanswered question stops the recording when its time is up",
          meaning: "this is the whole point: nobody is at the machine, so nobody will ever "
                 + "press the button",
          saw: "decided \(decision) with the question up for exactly the allowed 120s")
}

// The countdown expiring while a sound is actually arriving. Half a second of
// somebody clearing their throat is not a conversation, but cutting the
// recording off in the middle of it is still the wrong moment to choose.
do {
    let decision = clock.decide(silentFor: 0.2, soundRun: 1, asking: 130)
    check(decision == .ask,
          rule: "the recording is not stopped in the middle of a sound",
          meaning: "if that sound turns out to be the start of the meeting resuming, stopping "
                 + "now loses the first seconds of it and the meeting with them",
          saw: "decided \(decision) with sound still arriving past the reply deadline")
}

// Just under the wait must not ask. Off-by-one here means the question appears
// a minute early on every setting.
do {
    let decision = clock.decide(silentFor: 299, soundRun: 0, asking: nil)
    check(decision == .keepWatching,
          rule: "silence just short of the configured wait does not ask",
          meaning: "the number in settings has to be the number that happens, or the setting "
                 + "is decoration",
          saw: "decided \(decision) after 299s of an allowed 300s")
}

// The boundary of the new rule, from both sides.
do {
    let atBoundary = clock.decide(silentFor: 0.1, soundRun: SilenceClock.resumeAfter, asking: 10)
    let justUnder = clock.decide(silentFor: 0.1, soundRun: SilenceClock.resumeAfter - 0.01, asking: 10)
    check(atBoundary == .keepWatching && justUnder == .ask,
          rule: "sound counts as a conversation at resumeAfter and not before",
          meaning: "the constant has to be the length that actually decides, or the margin "
                 + "over the longest alert sound is imaginary",
          saw: "at \(SilenceClock.resumeAfter)s: \(atBoundary); just under: \(justUnder)")
}

// The gap tolerance has to leave room over the longest alert sound, or the
// measurement that chose it stops being a reason.
do {
    let longestAlertSound: TimeInterval = 2.163458   // Funk.aiff, measured with afinfo
    check(SilenceClock.resumeAfter > longestAlertSound * 1.5,
          rule: "resumeAfter keeps a real margin over the longest alert sound",
          meaning: "a margin of a few hundredths would make this rule depend on which alert "
                 + "sound the user picked, and break again the day they pick a longer one",
          saw: "resumeAfter \(SilenceClock.resumeAfter)s vs longest alert sound "
             + "\(longestAlertSound)s")
}

return failures
}
