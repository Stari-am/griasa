import Foundation

// Checks for the comparison that decides whether the microphone is worth
// tapping. A tap installed against a format the hardware is not using records
// nothing — measured twice on a real machine, once as a thrown -10868 and once
// as a start that reported success and then delivered no buffers at all. What
// reaches the user either way is a meeting with their own voice missing from it.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runAudioFormatChecks() -> Int {
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

check(AudioFormatMatch.agree(rate: 48000, channels: 1, otherRate: 48000, otherChannels: 1),
      rule: "the same format agrees with itself",
      meaning: "refusing a format that is perfectly fine would mean never recording a microphone at all",
      saw: "48 kHz mono was rejected against 48 kHz mono")

check(!AudioFormatMatch.agree(rate: 24000, channels: 1, otherRate: 48000, otherChannels: 1),
      rule: "a node at 48 kHz does not agree with hardware at 24 kHz",
      meaning: "this is the measured failure — the engine kept the built-in microphone's rate after a Bluetooth headset arrived in call mode, and the recording lost its own side",
      saw: "24 kHz hardware was accepted against a 48 kHz node")

check(!AudioFormatMatch.agree(rate: 48000, channels: 1, otherRate: 48000, otherChannels: 2),
      rule: "the same rate with a different channel count does not agree",
      meaning: "a rate comparison alone passes a mono/stereo mismatch, which delivers nothing in exactly the same silent way",
      saw: "1 channel was accepted against 2")

check(!AudioFormatMatch.agree(rate: 48000, channels: 0, otherRate: 48000, otherChannels: 0),
      rule: "a format with no channels never agrees, whatever its rate says",
      meaning: "a device mid-switch reports a rate and no channels; treating that as a match installs a tap on nothing",
      saw: "two zero-channel formats were called a match")

check(!AudioFormatMatch.agree(rate: 0, channels: 1, otherRate: 0, otherChannels: 1),
      rule: "a format with no rate never agrees",
      meaning: "same reason, the other way round: equality is not enough when both sides are equally absent",
      saw: "two zero-rate formats were called a match")

check(!AudioFormatMatch.usable(rate: 0, channels: 1)
        && !AudioFormatMatch.usable(rate: 48000, channels: 0)
        && AudioFormatMatch.usable(rate: 24000, channels: 1),
      rule: "usable separates absent hardware from hardware that disagrees with itself",
      meaning: "\"there is no microphone\" and \"the microphone is there and the engine has the wrong idea of it\" are different sentences to show somebody, and only one of them is about permissions",
      saw: "usable did not answer for one of: no rate, no channels, 24 kHz mono")

return failures
}
