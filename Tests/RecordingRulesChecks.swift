import Foundation

// Checks for deleting old recording audio and placing recording folders. The
// expensive mistake is deleting the only copy of a meeting — audio from a
// recording that was never transcribed, or the one still being recorded.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runRecordingRulesChecks() -> Int {
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

let now = RecordingRules.startDate(ofFolderNamed: "2026-10-05 12.00.00")!
let root = URL(fileURLWithPath: "/tmp/rec")
func session(_ name: String, transcript: Bool = true) -> RecordingRules.Session {
    let folder = root.appendingPathComponent(name)
    return .init(folder: folder, started: RecordingRules.startDate(ofFolderNamed: name) ?? .distantFuture,
                 hasTranscript: transcript,
                 audio: [folder.appendingPathComponent("microphone.caf"),
                         folder.appendingPathComponent("system-audio.caf")])
}
let old = session("2026-09-01 10.00.00")
let fresh = session("2026-10-04 10.00.00")
let untranscribed = session("2026-08-01 10.00.00", transcript: false)

check(RecordingRules.startDate(ofFolderNamed: "2026-09-23 05.04.30") != nil
        && RecordingRules.startDate(ofFolderNamed: "Notes") == nil,
      rule: "a recording folder's start time is read from its name, and other folders are not recordings",
      meaning: "age decides what is deleted; reading it from anything less fixed would let a copied or touched folder look new or old",
      saw: "date parsing disagreed")

check(RecordingRules.audioToDelete([old, fresh], olderThanDays: 0, now: now, active: nil).isEmpty,
      rule: "a limit of 0 keeps all audio",
      meaning: "0 is Never, the default — an update must not start deleting anybody's recordings",
      saw: "something was selected with the limit at 0")

let week = RecordingRules.audioToDelete([old, fresh], olderThanDays: 7, now: now, active: nil)
check(Set(week) == Set(old.audio),
      rule: "audio older than the limit is selected, newer audio is not",
      meaning: "this is the feature — and only the old recording's two audio files",
      saw: "\(week.map(\.path))")

check(RecordingRules.audioToDelete([untranscribed], olderThanDays: 1, now: now, active: nil).isEmpty,
      rule: "audio of a recording with no finished transcript is never selected, however old",
      meaning: "for a recording whose transcription failed or never ran, the audio is the only copy of the meeting there is",
      saw: "untranscribed audio was selected")

check(RecordingRules.audioToDelete([old], olderThanDays: 1, now: now, active: old.folder).isEmpty,
      rule: "the recording in progress is never touched",
      meaning: "a long recording can be older than the limit while it is still being written",
      saw: "the active recording's audio was selected")

var mixed = old
mixed.audio += [old.folder.appendingPathComponent("meeting-transcript.md"),
                old.folder.appendingPathComponent("transcript-raw.txt")]
let onlyAudio = RecordingRules.audioToDelete([mixed], olderThanDays: 1, now: now, active: nil)
check(onlyAudio.allSatisfy { $0.pathExtension == "caf" } && onlyAudio.count == 2,
      rule: "only audio files are ever selected",
      meaning: "the transcript and notes are what is being kept; a stray text file in the list would delete them",
      saw: "\(onlyAudio.map(\.lastPathComponent))")

let undated = RecordingRules.Session(folder: root.appendingPathComponent("odd"), started: .distantFuture,
                                     hasTranscript: true, audio: [root.appendingPathComponent("odd/a.caf")])
check(RecordingRules.audioToDelete([undated], olderThanDays: 1, now: now, active: nil).isEmpty,
      rule: "a folder whose age cannot be told is never old enough",
      meaning: "not knowing the date must end in keeping the file, not in deleting it",
      saw: "undatable audio was selected")

let project = URL(fileURLWithPath: "/tmp/Projects/Checkout")
check(RecordingRules.home(ofSessionNamed: "2026-09-01 10.00.00", byProject: true, projectFolder: project,
                          recordingsRoot: root).path == "/tmp/Projects/Checkout/Recordings/2026-09-01 10.00.00"
        && RecordingRules.home(ofSessionNamed: "2026-09-01 10.00.00", byProject: false, projectFolder: project,
                               recordingsRoot: root).path == "/tmp/rec/2026-09-01 10.00.00",
      rule: "with project folders on, a recording lives beside its project's notes; off, where it always has",
      meaning: "the setting has to be reversible to exactly the old layout",
      saw: "home() put a recording somewhere else")

let movedTo = "/tmp/Projects/Checkout/Recordings/2026-09-01 10.00.00/meeting-transcript.md"
let found = RecordingRules.relocate("/tmp/rec/2026-09-01 10.00.00/meeting-transcript.md",
                                    recordingsRoot: root, projectsRoot: URL(fileURLWithPath: "/tmp/Projects"),
                                    exists: { $0 == movedTo },
                                    projectFolders: { [URL(fileURLWithPath: "/tmp/Projects/Inbox"), project] })
check(found == movedTo,
      rule: "a recording that moved is found again by its folder's name",
      meaning: "a project renamed or deleted moves its recordings without the history being told; the transcript link must keep working",
      saw: found ?? "nil")

let stays = RecordingRules.relocate("/a/b.md", recordingsRoot: root, projectsRoot: root,
                                    exists: { $0 == "/a/b.md" }, projectFolders: { [] })
let gone = RecordingRules.relocate("/a/b.md", recordingsRoot: root, projectsRoot: root,
                                   exists: { _ in false }, projectFolders: { [] })
check(stays == "/a/b.md" && gone == nil,
      rule: "a path that still exists is left alone, and one found nowhere is not invented",
      meaning: "repairing must never point the history at a file that is not there",
      saw: "stays \(stays ?? "nil"), gone \(gone ?? "nil")")

return failures
}
