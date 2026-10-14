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


// The answer for a 1000-byte model, with the body's length and type when given.
func resp(status: Int, requestedFrom: Int64, contentRangeStart: Int64?,
          length: Int64? = nil, type: String? = "application/octet-stream") -> DownloadResume.Response {
    DownloadResume.response(status: status, requestedFrom: requestedFrom, contentRangeStart: contentRangeStart,
                            contentLength: length, mimeType: type, expectedSize: 1000)
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

check(DownloadResume.existing(partSize: 100 << 20, expectedSize: 1 << 40, rewind: DownloadResume.syncEvery) == .requestFrom(36 << 20)
        && DownloadResume.existing(partSize: 10 << 20, expectedSize: 1 << 40, rewind: DownloadResume.syncEvery) == .requestFrom(0)
        && DownloadResume.existing(partSize: 1 << 40, expectedSize: 1 << 40, rewind: DownloadResume.syncEvery) == .verifyNow,
      rule: "after a launch, the part is cut back by one flush interval (not below 0) before resuming",
      meaning: "a power cut can leave zeros in the unflushed tail; resuming after them fails the checksum after the whole download",
      saw: "\(DownloadResume.existing(partSize: 100 << 20, expectedSize: 1 << 40, rewind: DownloadResume.syncEvery))")

// The server's answer
check(resp(status: 206, requestedFrom: 40, contentRangeStart: 40) == .append,
      rule: "206 starting where the part ends → append",
      meaning: "the resumed bytes go after the ones already on disk",
      saw: "\(resp(status: 206, requestedFrom: 40, contentRangeStart: 40))")
check(resp(status: 206, requestedFrom: 40, contentRangeStart: 0) == .discardAndRetry
        && resp(status: 206, requestedFrom: 40, contentRangeStart: nil) == .discardAndRetry,
      rule: "206 starting anywhere else, or unreadable → start over",
      meaning: "appending a range that does not line up stitches together a file nobody published",
      saw: "\(resp(status: 206, requestedFrom: 40, contentRangeStart: 0))")
check(resp(status: 200, requestedFrom: 40, contentRangeStart: nil, length: 1000) == .restartFromZero
        && resp(status: 200, requestedFrom: 0, contentRangeStart: nil, length: 1000) == .append
        && resp(status: 200, requestedFrom: 0, contentRangeStart: nil, length: nil) == .append,
      rule: "200 of the model's exact length to a Range request → empty the part and write it; 200 from 0 → write",
      meaning: "a server that ignores Range sends the file from byte 0; appending it would double the start",
      saw: "\(resp(status: 200, requestedFrom: 40, contentRangeStart: nil, length: 1000))")
check(resp(status: 200, requestedFrom: 40, contentRangeStart: nil, length: 5120) == .retryLater
        && resp(status: 200, requestedFrom: 40, contentRangeStart: nil, length: nil) == .retryLater
        && resp(status: 200, requestedFrom: 40, contentRangeStart: nil, length: 1000, type: "text/html; charset=utf-8") == .retryLater,
      rule: "200 to a Range request of another or unknown length, or a web page → keep the part, try again later",
      meaning: "a hotel login page answering 200 must not erase 30 GB already on disk",
      saw: "other length → \(resp(status: 200, requestedFrom: 40, contentRangeStart: nil, length: 5120))")
check(resp(status: 200, requestedFrom: 0, contentRangeStart: nil, length: 5120) == .retryLater
        && resp(status: 200, requestedFrom: 0, contentRangeStart: nil, length: nil, type: "text/html") == .retryLater
        && resp(status: 206, requestedFrom: 40, contentRangeStart: 40, type: "text/html") == .retryLater,
      rule: "a first answer of the wrong length, or any web page → not written, try again later",
      meaning: "a portal page written as the model's first bytes would be resumed onto and fail its checksum after the whole download",
      saw: "from 0, wrong length → \(resp(status: 200, requestedFrom: 0, contentRangeStart: nil, length: 5120))")
check(resp(status: 503, requestedFrom: 40, contentRangeStart: nil) == .retryLater
        && resp(status: 500, requestedFrom: 0, contentRangeStart: nil) == .retryLater
        && resp(status: 502, requestedFrom: 0, contentRangeStart: nil) == .retryLater
        && resp(status: 504, requestedFrom: 0, contentRangeStart: nil) == .retryLater
        && DownloadResume.isNetworkError(DownloadResume.retryableError),
      rule: "a server error (500, 502, 503, 504) is waited out like a network drop",
      meaning: "a CDN's bad minute must not end a download a dropped connection would survive",
      saw: "503 → \(resp(status: 503, requestedFrom: 40, contentRangeStart: nil))")
check(resp(status: 416, requestedFrom: 40, contentRangeStart: nil) == .discardAndRetry,
      rule: "416 → delete the part and start over",
      meaning: "the part does not fit the file the server has",
      saw: "\(resp(status: 416, requestedFrom: 40, contentRangeStart: nil))")
check(resp(status: 404, requestedFrom: 40, contentRangeStart: nil) == .fail(status: 404)
        && resp(status: 403, requestedFrom: 0, contentRangeStart: nil) == .fail(status: 403),
      rule: "any other status fails as before",
      meaning: "an error page must never be written into the model",
      saw: "\(resp(status: 404, requestedFrom: 40, contentRangeStart: nil))")
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

check(!DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: "m", entryID: "m", autoDownload: false,
                                           resumedThisLaunch: true, lastFailureWasNetwork: false)
        && DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: "m", entryID: "m", autoDownload: true,
                                               resumedThisLaunch: true, lastFailureWasNetwork: true),
      rule: "continued without asking once this launch → not again, unless the last try ended on the network",
      meaning: "a pulled file or a full disk would otherwise restart and fail at every refresh",
      saw: "again after a non-network failure → \(DownloadResume.resumesWithoutAsking(partSize: 40, consentedID: "m", entryID: "m", autoDownload: false, resumedThisLaunch: true, lastFailureWasNetwork: false))")

// A pick in Settings while a download runs
check(DownloadResume.keepsDownload(downloadingID: "m", resolvedID: "m", preferred: nil)
        && DownloadResume.keepsDownload(downloadingID: "m", resolvedID: "m", preferred: .griasa),
      rule: "a pick that still comes to the model downloading, on Griasa's engine → the download goes on",
      meaning: "stopping it would make the person wait for the same file again",
      saw: "\(DownloadResume.keepsDownload(downloadingID: "m", resolvedID: "m", preferred: nil))")
check(!DownloadResume.keepsDownload(downloadingID: "m", resolvedID: "other", preferred: nil)
        && !DownloadResume.keepsDownload(downloadingID: "m", resolvedID: "m", preferred: .ollama)
        && !DownloadResume.keepsDownload(downloadingID: nil, resolvedID: "m", preferred: nil),
      rule: "another model, or another engine preferred → the download stops",
      meaning: "a finished download of a model nobody wants any more would be installed and announced",
      saw: "other model → \(DownloadResume.keepsDownload(downloadingID: "m", resolvedID: "other", preferred: nil))")

// Progress counts what was already there
check(DownloadResume.percent(have: 50, of: 200) == 25
        && DownloadResume.percent(have: 300, of: 200) == 100
        && DownloadResume.percent(have: 5, of: 0) == 0,
      rule: "percent is over the whole file, capped at 100",
      meaning: "a resumed download shows where it really is, not 0% again",
      saw: "\(DownloadResume.percent(have: 50, of: 200))")

return failures
}
