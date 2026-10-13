import Foundation

// Checks for continuing an interrupted model download. Stitching the wrong
// bytes together hands a corrupt model to the engine (the checksum refuses it,
// and the person waits for 37 GB again); giving up too early throws away an
// hour of download over a Wi-Fi blip.

func runResumeChecks() -> Int {
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

// What is on disk before the request
check(DownloadResume.existing(partSize: nil, expectedSize: 100) == .requestFrom(0)
        && DownloadResume.existing(partSize: 0, expectedSize: 100) == .requestFrom(0),
      rule: "no part (or an empty one) → ask from byte 0, without a Range",
      meaning: "a first download must not send a Range header at all",
      saw: "\(DownloadResume.existing(partSize: nil, expectedSize: 100))")
check(DownloadResume.existing(partSize: 40, expectedSize: 100) == .requestFrom(40),
      rule: "a part shorter than the model → ask for the rest from its end",
      meaning: "this is the whole point: an interrupted download continues",
      saw: "\(DownloadResume.existing(partSize: 40, expectedSize: 100))")
check(DownloadResume.existing(partSize: 100, expectedSize: 100) == .verifyNow,
      rule: "a part of the full size → check it, ask for nothing",
      meaning: "a download cut between the last byte and the move must not ask for an empty range (416)",
      saw: "\(DownloadResume.existing(partSize: 100, expectedSize: 100))")
check(DownloadResume.existing(partSize: 101, expectedSize: 100) == .discard,
      rule: "a part larger than the model → delete it",
      meaning: "it cannot be a prefix of the pinned file",
      saw: "\(DownloadResume.existing(partSize: 101, expectedSize: 100))")

// The server's answer
check(DownloadResume.response(status: 206, requestedFrom: 40, contentRangeStart: 40) == .append,
      rule: "206 starting where the part ends → append",
      meaning: "the resumed bytes go after the ones already on disk",
      saw: "\(DownloadResume.response(status: 206, requestedFrom: 40, contentRangeStart: 40))")
check(DownloadResume.response(status: 206, requestedFrom: 40, contentRangeStart: 0) == .discardAndRetry
        && DownloadResume.response(status: 206, requestedFrom: 40, contentRangeStart: nil) == .discardAndRetry,
      rule: "206 starting anywhere else, or unreadable → start over",
      meaning: "appending a range that does not line up stitches together a file nobody published",
      saw: "\(DownloadResume.response(status: 206, requestedFrom: 40, contentRangeStart: 0))")
check(DownloadResume.response(status: 200, requestedFrom: 40, contentRangeStart: nil) == .restartFromZero
        && DownloadResume.response(status: 200, requestedFrom: 0, contentRangeStart: nil) == .append,
      rule: "200 to a Range request → empty the part and write the whole body; 200 from 0 → write",
      meaning: "a server that ignores Range sends the file from byte 0; appending it would double the start",
      saw: "\(DownloadResume.response(status: 200, requestedFrom: 40, contentRangeStart: nil))")
check(DownloadResume.response(status: 416, requestedFrom: 40, contentRangeStart: nil) == .discardAndRetry,
      rule: "416 → delete the part and start over",
      meaning: "the part does not fit the file the server has",
      saw: "\(DownloadResume.response(status: 416, requestedFrom: 40, contentRangeStart: nil))")
check(DownloadResume.response(status: 404, requestedFrom: 40, contentRangeStart: nil) == .fail(status: 404)
        && DownloadResume.response(status: 500, requestedFrom: 0, contentRangeStart: nil) == .fail(status: 500),
      rule: "any other status fails as before",
      meaning: "an error page must never be written into the model",
      saw: "\(DownloadResume.response(status: 404, requestedFrom: 40, contentRangeStart: nil))")
check(DownloadResume.contentRangeStart("bytes 1000-2023/2740937888") == 1000
        && DownloadResume.contentRangeStart("Bytes 0-9/10") == 0
        && DownloadResume.contentRangeStart("bytes */100") == nil
        && DownloadResume.contentRangeStart(nil) == nil,
      rule: "Content-Range's start is read; anything else is nil",
      meaning: "the start decides whether the bytes line up",
      saw: "\(String(describing: DownloadResume.contentRangeStart("bytes 1000-2023/2740937888")))")

// Which errors are waited out
check(DownloadResume.isNetworkError(URLError(.networkConnectionLost))
        && DownloadResume.isNetworkError(URLError(.notConnectedToInternet))
        && DownloadResume.isNetworkError(URLError(.timedOut))
        && DownloadResume.isNetworkError(URLError(.cannotConnectToHost)),
      rule: "a lost, absent, timed-out or unreachable network is waited out",
      meaning: "a Wi-Fi drop or a sleep must not end a 20 GB download",
      saw: "connectionLost → \(DownloadResume.isNetworkError(URLError(.networkConnectionLost)))")
check(!DownloadResume.isNetworkError(URLError(.serverCertificateUntrusted))
        && !DownloadResume.isNetworkError(URLError(.cancelled))
        && !DownloadResume.isNetworkError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        && !DownloadResume.isNetworkError(NSError(domain: "Griasa", code: 8)),
      rule: "a bad certificate, a cancel, a full disk or an HTTP error fails at once",
      meaning: "waiting half an hour on something the network will not fix only hides it",
      saw: "certificate → \(DownloadResume.isNetworkError(URLError(.serverCertificateUntrusted)))")

// How long to wait
let first = (1...4).map { DownloadResume.delay(afterFailures: $0, waited: 0) }
check(first == [5, 15, 60, 120] && DownloadResume.delay(afterFailures: 9, waited: 600) == 120,
      rule: "waits 5 s, 15 s, 60 s, then every two minutes",
      meaning: "a short blip resumes almost at once; a long outage is not polled every second",
      saw: "\(first)")
var waited: TimeInterval = 0
var tries = 0
while let next = DownloadResume.delay(afterFailures: tries + 1, waited: waited) { waited += next; tries += 1 }
check(waited <= DownloadResume.maxWait && waited > DownloadResume.maxWait - 120,
      rule: "gives up after about half an hour of waiting, never more",
      meaning: "a network that is gone for good ends in the usual failure, not a download that waits forever",
      saw: "waited \(waited) s over \(tries) tries")

// Continuing after a relaunch without asking twice
check(DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: "m", entryID: "m", autoDownload: false)
        && DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: nil, entryID: "m", autoDownload: true),
      rule: "a part on disk plus a yes for this model (or automatic downloads) → continue without asking",
      meaning: "the person said Download once; a quit must not make them say it again",
      saw: "\(DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: "m", entryID: "m", autoDownload: false))")
check(!DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: nil, entryID: "m", autoDownload: false)
        && !DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: "other", entryID: "m", autoDownload: false)
        && !DownloadResume.resumesWithoutAsking(partSize: nil, consentedID: "m", entryID: "m", autoDownload: false)
        && !DownloadResume.resumesWithoutAsking(partSize: 0, consentedID: "m", entryID: "m", autoDownload: false),
      rule: "no yes (or a Not now since), a yes for another model, or no part → ask as before",
      meaning: "a multi-gigabyte download never starts on a yes that was taken back or given for something else",
      saw: "no consent → \(DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: nil, entryID: "m", autoDownload: false))")

// Progress counts what was already there
check(DownloadResume.percent(have: 50, of: 200) == 25
        && DownloadResume.percent(have: 300, of: 200) == 100
        && DownloadResume.percent(have: 5, of: 0) == 0,
      rule: "percent is over the whole file, capped at 100",
      meaning: "a resumed download shows where it really is, not 0% again",
      saw: "\(DownloadResume.percent(have: 50, of: 200))")

return failures
}
