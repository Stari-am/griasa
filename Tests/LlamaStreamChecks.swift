import Foundation

// Checks for reading the local engine's event stream. A wrong reading either
// loses part of a meeting summary or hides the server's own error message.

func runLlamaStreamChecks() -> Int {
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

func chunk(_ content: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
    return "data: " + String(data: data, encoding: .utf8)!
}

var s = LlamaStream()
for line in [chunk("Hel"), "", chunk("lo "), ": keep-alive", chunk("world"), "data: [DONE]"] { try? s.feed(line: line) }
check(s.text == "Hello world" && s.done,
      rule: "content is joined across chunks, blanks and comments are ignored, [DONE] ends the stream",
      meaning: "a dropped chunk is a hole in the meeting summary",
      saw: "\(s.text) done=\(s.done)")

var p = LlamaStream()
try? p.feed(line: #"data: {"choices":[{"delta":{}}],"prompt_progress":{"total":11715,"cache":0,"processed":2048,"time_ms":1500.5}}"#)
check(p.text.isEmpty && p.progress == LlamaStream.Progress(total: 11715, cache: 0, processed: 2048, timeMs: 1500.5),
      rule: "a progress-only line adds no text and records the progress",
      meaning: "progress is what proves the model is still working; it must never leak into the answer",
      saw: "\(p.text.debugDescription) \(String(describing: p.progress))")

var e = LlamaStream()
var message: String?
do { try e.feed(line: #"data: {"error":{"code":500,"message":"slot unavailable","type":"server_error"}}"#) }
catch { message = error.localizedDescription }
check(message == "slot unavailable",
      rule: "an error line surfaces the server's message",
      meaning: "the person should read why, not a generic failure",
      saw: String(describing: message))

var f = LlamaStream()
try? f.feed(line: chunk("cut o"))
try? f.feed(line: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
check(f.finishReason == "length" && f.text == "cut o",
      rule: "a finish reason of length is reported and the text so far is kept",
      meaning: "a truncated reply is returned as before, not thrown away",
      saw: "\(String(describing: f.finishReason)) \(f.text)")

var g = LlamaStream()
try? g.feed(line: "data:" + #"{"choices":[{"delta":{"content":"x"}}]}"#)
try? g.feed(line: "event: ping")
try? g.feed(line: "data: not json")
check(g.text == "x",
      rule: "a data line without a space, other fields and unreadable data are tolerated",
      meaning: "a stray line must not abort a summary that took ten minutes",
      saw: g.text)

var cut = LlamaStream()
try? cut.feed(line: chunk("half a summ"))
check(!cut.complete,
      rule: "a stream with text but no [DONE] and no finish reason is not complete",
      meaning: "a connection dropped mid-reply must not be saved as a finished summary",
      saw: "complete=\(cut.complete)")
check(s.complete && f.complete && !p.complete,
      rule: "[DONE] or a finish reason completes a stream; progress alone does not",
      meaning: "completeness is the only proof the reply is whole",
      saw: "\(s.complete) \(f.complete) \(p.complete)")

var ev = LlamaStream()
var evMessage: String?
do { try ev.feed(line: #"error: {"message":"out of memory"}"#) } catch { evMessage = error.localizedDescription }
check(evMessage == "out of memory",
      rule: "an SSE error: field line surfaces the server's message like a data error line",
      meaning: "which form the server uses differs by version; either must be read",
      saw: String(describing: evMessage))

check(LocalFailure.kind(of: URLError(.timedOut)) == .slow
          && LocalFailure.kind(of: URLError(.cannotConnectToHost)) == .unreachable
          && LocalFailure.kind(of: URLError(.networkConnectionLost)) == .unreachable
          && LocalFailure.kind(of: NSError(domain: "Griasa", code: 6)) == .unreachable
          && LocalFailure.kind(of: NSError(domain: "Griasa", code: 4)) == .other,
      rule: "a timeout is slow, never unreachable; a refused or lost connection is unreachable",
      meaning: "unreachable triggers a refresh and a second wait; doing that to a slow model doubles the wait",
      saw: "\(LocalFailure.kind(of: URLError(.timedOut)))")

return failures
}
