// Unit tests for meeting-capture. Run with tests/run.sh.
//
// This is the only file in the test build with top-level code; everything below
// "// MARK: - Main" in bin/meeting-capture is stripped by tests/run.sh.
// Covers pure logic plus filesystem helpers (state-file reads/removals,
// transcript tailing) via temp files; AX/processes/real time are not exercised.
import Foundation
import ApplicationServices // AXUIElement appears in the StubMeetingApp signature

var count = 0
var failures = 0

func expectTrue(_ condition: Bool, _ name: String) {
    count += 1
    if condition { print("ok \(count) - \(name)") }
    else { failures += 1; print("not ok \(count) - \(name)") }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    count += 1
    if got == want { print("ok \(count) - \(name)") }
    else {
        failures += 1
        print("not ok \(count) - \(name)\n     got:  \(got)\n     want: \(want)")
    }
}

// --- parseMeetingClock --------------------------------------------------

// Strictness is the point: malformed input must fail rather than quietly
// become some other duration (the old compactMap turned "1::30" into 1m30s).
expectEqual(parseMeetingClock("31:01"), TimeInterval(1861), "clock parses mm:ss")
expectEqual(parseMeetingClock("1:34:50"), TimeInterval(5690), "clock parses h:mm:ss")
expectEqual(parseMeetingClock("Elapsed time 21:54"), TimeInterval(1314), "clock parses from a label")
expectEqual(parseMeetingClock("My connected time is 34:50"), TimeInterval(2090), "clock parses Zoom's description")
expectEqual(parseMeetingClock(""), nil, "empty string is no clock")
expectEqual(parseMeetingClock("no clock here"), nil, "prose is no clock")
expectEqual(parseMeetingClock("1::30"), nil, "empty component rejected")
expectEqual(parseMeetingClock("1a:30"), nil, "non-numeric component rejected")
expectEqual(parseMeetingClock("99:99"), nil, "minutes >= 60 rejected")
expectEqual(parseMeetingClock("1:99:00"), nil, "seconds >= 60 rejected")
expectEqual(parseMeetingClock("4:59"), TimeInterval(299), "minute 59 fine")
expectEqual(parseMeetingClock("0:00"), TimeInterval(0), "zero clock parses")

// --- elapsedString / TimestampMode --------------------------------------

let epoch = Date(timeIntervalSince1970: 0)
expectEqual(elapsedString(from: epoch, to: Date(timeIntervalSince1970: 3733)), "01:02:13", "elapsed formats h:mm:ss")
expectEqual(elapsedString(from: Date(timeIntervalSince1970: 100), to: epoch), "00:00:00", "negative spans clamp to zero")

expectEqual(TimestampMode.elapsed(from: epoch).stamp(Date(timeIntervalSince1970: 61)), "00:01:01", "elapsed mode counts from its start")

// The recorder's wall-clock formatter is private by design; verify its output
// against independently computed wall-clock components instead.
do {
    let date = Date(timeIntervalSince1970: 12 * 3600 + 34 * 60 + 56)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let c = cal.dateComponents([.hour, .minute, .second], from: date)
    let want = String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
    expectEqual(TimestampMode.timeOfDay.stamp(date), want, "time-of-day mode stamps HH:mm:ss in the local zone")
}

// --- Recorder.slugify ---------------------------------------------------

expectEqual(Recorder.slugify("Weekly Sync | Microsoft Teams"), "weekly-sync", "slug drops app suffix and spaces")
expectEqual(Recorder.slugify("!!!"), "meeting", "all-punctuation title falls back to 'meeting'")
expectEqual(Recorder.slugify("Ada's 2nd standup!"), "ada-s-2nd-standup", "slug keeps letters and digits")

// --- SegmentHistory -----------------------------------------------------
// Caption surfaces without ids (Meet blocks, Slack overlay events) get their
// identity from position in the conversation. Repeated utterances must stay
// distinct — a single "Yeah." said twice was the bug that produced this class.

do {
    let h = SegmentHistory()
    expectEqual(h.absorb([SegmentKey(speaker: "Grace", text: "Yeah.")]), 0, "first segment sits at position 0")
    // Same words again: the window now shows two settled segments, both new.
    let keys = [SegmentKey(speaker: "Grace", text: "Yeah."), SegmentKey(speaker: "Grace", text: "Yeah.")]
    expectEqual(h.absorb(keys), 0, "repeated utterance extends the history")
    // Window slides: only the newest ("second") segment remains visible.
    expectEqual(h.absorb([SegmentKey(speaker: "Grace", text: "Yeah.")]), 1, "window slide keeps absolute positions")
}

do {
    let h = SegmentHistory()
    _ = h.absorb([SegmentKey(speaker: "S", text: "a")])
    expectEqual(h.absorb([SegmentKey(speaker: "S", text: "a"), SegmentKey(speaker: "T", text: "b")]), 0, "append after tail overlap")
    expectEqual(h.absorb([SegmentKey(speaker: "T", text: "b"), SegmentKey(speaker: "U", text: "c")]), 1, "oldest falling off-screen shifts nothing")
    expectEqual(h.absorb([]), 3, "empty poll reports where the live slot goes")
    // Nothing in common at all: re-anchor rather than restart numbering.
    expectEqual(h.absorb([SegmentKey(speaker: "V", text: "x"), SegmentKey(speaker: "W", text: "y")]), 3, "disjoint window keeps counting up")
}

do {
    // Struct keys mean a speaker whose name contains any delimiter-like
    // character can never collide with a different utterance.
    let h = SegmentHistory()
    _ = h.absorb([SegmentKey(speaker: "Grace\u{1}x", text: "a|b")])
    expectEqual(h.absorb([SegmentKey(speaker: "Grace", text: "x\u{1}a|b")]), 1, "lookalike strings stay distinct utterances")
}

do {
    // Positions must stay monotonic even as old segments are trimmed away.
    let h = SegmentHistory()
    var lastBase = -1
    var monotonic = true
    for i in 0..<600 {
        let base = h.absorb([SegmentKey(speaker: "Speaker\(i % 3)", text: "line \(i)")])
        if base <= lastBase { monotonic = false }
        lastBase = base
    }
    expectTrue(monotonic && lastBase == 599, "trimming never rewinds positions")
}

do {
    let h = SegmentHistory()
    _ = h.absorb([
        SegmentKey(speaker: "A", text: "a"),
        SegmentKey(speaker: "B", text: "b"),
        SegmentKey(speaker: "C", text: "c")])
    h.reset()
    expectEqual(h.absorb([SegmentKey(speaker: "D", text: "fresh")]), 0, "reset returns to a fresh conversation")
}

// --- LiveView.wrap / layout ---------------------------------------------

expectEqual(LiveView.wrap("hello world", width: 8), ["hello", "world"], "wrap breaks at spaces")
expectEqual(LiveView.wrap("short", width: 80), ["short"], "short lines pass through")
// Character preservation is what matters, not where the row boundaries land:
let broken = LiveView.wrap("extraordinarily", width: 10)
expectTrue(broken.count > 1, "overlong words are broken across rows")
expectEqual(broken.joined(), "extraordinarily", "broken words keep every character")
let prose = "several ordinary words that will need wrapping across several rows"
expectEqual(LiveView.wrap(prose, width: 12).joined(separator: " "), prose, "wrap preserves every word at word width")
expectEqual(LiveView.layout(["one", "two"]), ["one", "two"], "layout renders rows unchanged when they fit")

// --- State-file helpers -------------------------------------------------

let dir = NSTemporaryDirectory() + "/meeting-capture-tests\(UUID().uuidString)"
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let statePath = dir + "/state"

func isAbsent(_ path: String) -> Bool {
    if case .absent = readFile(path) { return true }
    return false
}
expectTrue(isAbsent(statePath), "readFile reports absent for a missing file")
try "hello".write(toFile: statePath, atomically: true, encoding: .utf8)
switch readFile(statePath) {
case .data("hello"): expectTrue(true, "readFile returns contents")
default: expectTrue(false, "readFile returns contents")
}
removeStateFile(statePath)
expectTrue(isAbsent(statePath), "removeStateFile removes the file")

// --- drainFileTail ------------------------------------------------------

let tailPath = dir + "/transcript.txt"
try "first\n".write(toFile: tailPath, atomically: true, encoding: .utf8)
var warnedCount = 0

// A real sink lets us verify ORDERING, not just that beforeWrite ran: the
// erase marker must precede the tailed bytes in the same stream.
let sinkPath = dir + "/sink.txt"
FileManager.default.createFile(atPath: sinkPath, contents: nil)
let orderedSink = FileHandle(forWritingAtPath: sinkPath)!
try drainFileTail(tailPath, from: 0, into: orderedSink,
    beforeWrite: {
        try? orderedSink.write(contentsOf: Data("[erase]".utf8))
    },
    warn: { _ in warnedCount += 1 })
try orderedSink.close()
let sunk = (try String(contentsOfFile: sinkPath, encoding: .utf8))
expectEqual(sunk, "[erase]first\n", "live-region erase lands BEFORE the printed bytes — and only once")

// Remaining drains use /dev/null.
let nullSink = FileHandle(forWritingAtPath: "/dev/null")!
var off = try drainFileTail(tailPath, from: 0, into: nullSink,
    beforeWrite: {},
    warn: { _ in warnedCount += 1 })
expectEqual(off, UInt64("first\n".utf8.count), "drain consumes new bytes and advances offset")

let appendHandle = FileHandle(forWritingAtPath: tailPath)!
try appendHandle.seekToEnd()
try appendHandle.write(contentsOf: Data("second\n".utf8))
try appendHandle.close()
off = try drainFileTail(tailPath, from: off, into: nullSink,
    beforeWrite: {}, warn: { _ in warnedCount += 1 })
expectEqual(off, UInt64("first\nsecond\n".utf8.count), "drain resumes from its previous offset")
expectEqual(warnedCount, 0, "healthy drains never warn")

// A missing file is absence, not a failure — no warning, offset untouched.
off = try drainFileTail(dir + "/missing", from: off, into: nullSink,
    beforeWrite: {}, warn: { _ in warnedCount += 1 })
expectEqual(warnedCount, 0, "missing files are absent, not failures")

// --- isMissingFileError classification ----------------------------------

func cocoaError(_ code: Int, underlyingPOSIX: Int32? = nil) -> NSError {
    var userInfo: [String: Any] = [:]
    if let posix = underlyingPOSIX {
        userInfo[NSUnderlyingErrorKey] = NSError(
            domain: NSPOSIXErrorDomain, code: Int(posix), userInfo: nil)
    }
    return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: userInfo)
}
// Sanity: the Cocoa constants are easy to flip mentally — pin their values.
expectEqual(NSFileNoSuchFileError, 4, "NSFileNoSuchFileError is 4")
expectEqual(NSFileReadUnknownError, 256, "NSFileReadUnknownError is 256 (generic read failure)")
expectEqual(NSFileReadNoSuchFileError, 260, "NSFileReadNoSuchFileError is 260 (definitive missing file)")

expectTrue(isMissingFileError(cocoaError(NSFileNoSuchFileError)), "code 4 (no such file) is missing")
expectTrue(isMissingFileError(cocoaError(NSFileReadNoSuchFileError)), "code 260 (read no-such-file) is missing")
expectTrue(isMissingFileError(cocoaError(NSFileReadUnknownError, underlyingPOSIX: ENOENT)),
           "generic 256 wrapped around ENOENT is missing")
expectTrue(isMissingFileError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)),
           "raw POSIX ENOENT is missing")
expectTrue(!isMissingFileError(cocoaError(NSFileReadUnknownError)),
           "generic 256 WITHOUT ENOENT underneath is a real failure (EIO/ESTALE surface as 256)")
expectTrue(!isMissingFileError(cocoaError(NSFileReadNoPermissionError)), "EACCES is a failure, not idle")
expectTrue(!isMissingFileError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)),
           "raw POSIX EACCES is a failure, not idle")

// --- Recorder fault injection (TranscriptSink seam) ---------------------

// In-memory sink that records everything it's given.
final class MemorySink: TranscriptSink {
    let path: String
    private(set) var data = Data()
    init(path: String) { self.path = path }
    func append(_ data: Data) throws { self.data.append(data) }
    var string: String { String(data: data, encoding: .utf8) ?? "" }
}

// Fails every append with the error a closed descriptor would produce —
// FileHandle itself raises ObjC exceptions in-process and can't be tested.
struct ClosedSink: TranscriptSink {
    let path: String
    func append(_ data: Data) throws {
        throw cocoaError(NSFileWriteUnknownError)
    }
}

// Succeeds every time except the `failAt`-th append (transient-failure shape:
// one lost write, recovery on the next attempt).
final class FailOnceSink: TranscriptSink {
    let path: String
    let failAt: Int
    private(set) var appends = 0
    init(path: String, failAt: Int) { self.path = path; self.failAt = failAt }
    func append(_ data: Data) throws {
        defer { appends += 1 }
        if appends + 1 == failAt { throw cocoaError(NSFileWriteUnknownError) }
    }
}

func injectedRecorder(jsonl: TranscriptSink, text: TranscriptSink) -> Recorder {
    var opts = Options()
    opts.quiet = true
    // .elapsed makes stamps deterministic ([00:00:00] from the epoch start).
    // URLs are unique per call so a future real-sink test can't collide.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    return Recorder(options: opts, startedAt: epoch, mode: .elapsed(from: epoch),
                    jsonlURL: dir.appendingPathComponent("mc-injected-\(UUID().uuidString).jsonl"),
                    textURL: dir.appendingPathComponent("mc-injected-\(UUID().uuidString).txt"),
                    jsonl: jsonl, text: text)
}

// All-paths-succeed: both files carry the line.
do {
    let jsonl = MemorySink(path: "/tmp/j.jsonl"), text = MemorySink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    expectEqual(r.record(kind: "caption", speaker: "A", body: "hello", at: epoch),
                WriteOutcome.written("[00:00:00] A: hello"),
                "record returns .written when both sinks accept")
    expectTrue(jsonl.string.contains("\"text\":\"hello\""), "jsonl sink got the event JSON")
    expectTrue(text.string.contains("A: hello"), "text sink got the transcript line")
}

// jsonl fails: nothing anywhere, not even the text half.
do {
    let jsonl = ClosedSink(path: "/tmp/j.jsonl"), text = MemorySink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    expectEqual(r.record(kind: "caption", speaker: "A", body: "hi", at: epoch),
                WriteOutcome.failed, "record returns .failed when the jsonl sink rejects")
    expectTrue(text.string.isEmpty, "text sink untouched when jsonl fails first")
    expectTrue(!r.writeJSON(["type": "metadata"]), "writeJSON reports failure via closed sink")
}

// text fails after jsonl succeeded: .jsonOnly debt, exactly once in jsonl.
do {
    let jsonl = MemorySink(path: "/tmp/j.jsonl"), text = ClosedSink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    expectEqual(r.record(kind: "caption", speaker: "B", body: "owed", at: epoch),
                WriteOutcome.jsonOnly("[00:00:00] B: owed"),
                "record returns .jsonOnly when only the text sink rejects")
    expectEqual(jsonl.string.components(separatedBy: "\n").filter { $0.contains("\"owed\"") }.count,
                1, "jsonl carries the event exactly once despite the text failure")
    let threw = { () -> Bool in do { try r.appendText("[00:00:00] retry"); return false } catch { return true } }()
    expectTrue(threw, "appendText surfaces failure via thrown error")
}

// Transient failure then recovery: a flaky jsonl accepts the retry.
do {
    let jsonl = FailOnceSink(path: "/tmp/j.jsonl", failAt: 2), text = MemorySink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    expectEqual(r.record(kind: "caption", speaker: "C", body: "one", at: epoch),
                WriteOutcome.written("[00:00:00] C: one"), "first write lands")
    expectEqual(r.record(kind: "caption", speaker: "C", body: "two", at: epoch),
                WriteOutcome.failed, "flaky sink rejects the second event")
    expectEqual(r.writeJSON(["type": "retry"]), true, "third attempt succeeds after transient failure")
}

// Header loss is downgraded to a warning, never a crash.
do {
    let r = injectedRecorder(jsonl: MemorySink(path: "/tmp/j.jsonl"), text: ClosedSink(path: "/tmp/t.txt"))
    r.writeHeader(["Meeting: test"]) // must complete without throwing/exiting
    expectTrue(true, "writeHeader survives a failing text sink")
}

// FileSink open-failure semantics: nil for an unwritable path, no process exit.
expectTrue(FileSink(url: URL(fileURLWithPath: "/nonexistent-dir-xyz/a.jsonl")) == nil,
           "FileSink is nil for unopenable paths (callers decide fatality)")

do {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mc-test-\(UUID().uuidString).txt")
    // FileHandle(forWritingAtPath:) does NOT create files — same reason the
    // real Recorder pre-creates them before opening.
    expectTrue(FileManager.default.createFile(atPath: url.path, contents: nil),
               "test fixture creates the sink target")
    guard let sink = FileSink(url: url) else {
        expectTrue(false, "FileSink opens a real writable file")
        exit(failures == 0 ? 0 : 1)
    }
    try? sink.append(Data("first\n".utf8))
    guard let reopened = FileSink(url: url) else {
        expectTrue(false, "FileSink reopens an existing file")
        exit(failures == 0 ? 0 : 1)
    }
    try? reopened.append(Data("second\n".utf8))
    let contents = try? String(contentsOf: url, encoding: .utf8)
    expectEqual(contents, "first\nsecond\n", "reopened FileSink appends at EOF without clobbering")
    try? FileManager.default.removeItem(at: url)
}

// --- Clock seam: finish-time recovery + backoff (issue #14 case 1) ------

final class FakeClock: TimeSource {
    private(set) var fakeNow: Date
    /// Advance per now() call — the finish drain loop terminates once its
    /// deadline check sees time pass, without any real sleeping.
    let step: TimeInterval
    init(start: Date, step: TimeInterval) { fakeNow = start; self.step = step }
    func now() -> Date { defer { fakeNow = fakeNow.addingTimeInterval(step) }; return fakeNow }
}

final class StubMeetingApp: MeetingApp {
    let id = "stub"
    let displayName = "Stub"
    let processPattern = "stub"
    let captionPressToggles = false
    let finalizesWhenSuperseded = false
    let idleFinalizeSeconds: TimeInterval? = nil
    let reportsMeetingClock = false
    let captionsSurfaceIsTransient = false
    let rendersWebContent = false
    func meetingAnchor(_ app: AXUIElement) -> AXUIElement? { nil }
    func meetingTitle(_ app: AXUIElement, anchor: AXUIElement?) -> String { "" }
    func captionsContainer(_ app: AXUIElement) -> AXUIElement? { nil }
    func meetingElapsed(_ app: AXUIElement) -> TimeInterval? { nil }
    func captionEntries(in container: AXUIElement) -> [CaptionEntry] { [] }
    func captionsPanelOpen(_ app: AXUIElement) -> Bool { false }
    func requestCaptions(pid: pid_t) -> CaptionRequest { .unreachable }
    func chatContainer(_ app: AXUIElement) -> AXUIElement? { nil }
    func chatMessages(in container: AXUIElement) -> [ChatMessage] { [] }
    func resetCaptureState() {}
    func hasStableIdentity(_ id: String) -> Bool { false }
    func treeIsReadable(_ app: AXUIElement) -> Bool { true }
}

func injectedSession(clock: FakeClock) -> Session {
    var opts = Options()
    opts.quiet = true // LiveView goes non-interactive; status() still stderr
    // Never touch the real user state directory from tests.
    opts.stateDirectory = NSTemporaryDirectory() + "/mc-state-\(UUID().uuidString)"
    return Session(options: opts, live: LiveView(options: opts),
                   meetingApp: StubMeetingApp(), title: "Test Meeting", clock: clock)
}

// Persistent failure: both sinks reject everything. finish() must burn
// through its deadline via the injected clock (no real sleeping), keep every
// item queued as lost, and stay silent about success.
do {
    let clock = FakeClock(start: epoch, step: 0.5)
    let s = injectedSession(clock: clock)
    // A pre-injected recorder with dead sinks = "metadata era is over, nothing
    // gets through" — and crucially, recorderForWriting() never tries to open
    // REAL files under the user's data directory mid-test.
    let dead = ClosedSink(path: "/tmp/dead")
    s.recorder = Recorder(options: Options(), startedAt: epoch, mode: .elapsed(from: epoch),
                          jsonlURL: URL(fileURLWithPath: dead.path),
                          textURL: URL(fileURLWithPath: dead.path),
                          jsonl: dead, text: dead)
    s.pendingWrites = [
        .event(kind: "caption", speaker: "A", body: "lost", at: epoch, extra: [:]),
        .text("[00:00:00] B: also lost")
    ]
    var slept: [UInt32] = []
    s.sleepFn = { slept.append($0) } // count pauses instead of taking them
    s.finish(at: epoch)
    expectTrue(s.finished, "finish marks the session finished even on total failure")
    expectEqual(s.pendingWrites.count, 2, "persistent failure leaves all queued items lost")
    expectTrue(!slept.isEmpty, "drain loop paused between attempts")
    expectTrue(slept.count >= 2, "multiple pauses: the loop actually retried, not spun once")
    expectTrue(clock.fakeNow > epoch.addingTimeInterval(5), "fake clock advanced past the finish deadline")
}

// Transient failure then recovery: a text-debt retry succeeds on a later
// attempt, the stopped event lands, and loss is zero.
do {
    let clock = FakeClock(start: epoch, step: 0.25)
    let s = injectedSession(clock: clock)
    let jsonl = MemorySink(path: "/tmp/recovery.jsonl")
    let text = FailOnceSink(path: "/tmp/recovery.txt", failAt: 1)
    s.recorder = Recorder(options: Options(), startedAt: epoch, mode: .elapsed(from: epoch),
                          jsonlURL: URL(fileURLWithPath: jsonl.path),
                          textURL: URL(fileURLWithPath: text.path),
                          jsonl: jsonl, text: text)
    s.pendingWrites = [.text("[00:00:00] C: recovered line")]
    s.sleepFn = { _ in } // no real pause; the fake clock drives termination
    s.finish(at: epoch)
    expectEqual(s.pendingWrites.count, 0, "transient text failure recovers on retry within the deadline")
    expectTrue(text.appends >= 2, "failed write was actually retried, not dropped")
    expectTrue(jsonl.string.contains("\"event\":\"stopped\""), "stopped event lands after recovery")
    expectTrue(jsonl.string.contains("\"lost_events\":0"), "recovery means zero events reported lost")
}

// Retry backoff is deterministic under the injected clock: doubles from 1s,
// capped at 30s, and won't fire before nextRetry.
do {
    let clock = FakeClock(start: epoch, step: 0)
    let s = injectedSession(clock: clock)
    // Dead sinks keep drainPendingWrites failing deterministically AND keep
    // recorderForWriting() from ever opening real files under the user's data
    // directory mid-test.
    let dead = ClosedSink(path: "/tmp/dead")
    s.recorder = Recorder(options: Options(), startedAt: epoch, mode: .elapsed(from: epoch),
                          jsonlURL: URL(fileURLWithPath: dead.path),
                          textURL: URL(fileURLWithPath: dead.path),
                          jsonl: dead, text: dead)
    s.pendingWrites = [.event(kind: "caption", speaker: "A", body: "x", at: epoch, extra: [:])]
    s.retryPendingWrites(now: clock.now())
    expectEqual(s.retryDelay, TimeInterval(2), "first failed retry backs off to 2s")
    expectTrue(s.nextRetry > epoch, "nextRetry scheduled in the future")
    s.retryPendingWrites(now: s.nextRetry.addingTimeInterval(-1))
    expectEqual(s.retryDelay, TimeInterval(2), "retry before nextRetry is a no-op")
    for want in [4.0, 8.0, 16.0, 30.0, 30.0] {
        s.retryPendingWrites(now: s.nextRetry)
        expectEqual(s.retryDelay, TimeInterval(want), "backoff progression: next step is \(want)s (capped at 30)")
    }
}

// --- TreeWaker rate-limiter (issue #17a) --------------------------------

// pokeDecision is pure: synthetic dates drive cooldown and attempt behavior,
// no AX element involved.
do {
    var waker = TreeWaker(quiet: true)
    let t0 = epoch
    let d1 = waker.pokeDecision(pid: 100, awake: false, now: t0)
    expectTrue(d1.poke && d1.attempt == 1, "hollow tree pokes immediately, attempt 1")

    let d2 = waker.pokeDecision(pid: 100, awake: false, now: t0.addingTimeInterval(4))
    expectTrue(!d2.poke && d2.attempt == 1, "within the 5s cooldown: passthrough count, no second poke")

    let d3 = waker.pokeDecision(pid: 100, awake: false, now: t0.addingTimeInterval(5))
    expectTrue(d3.poke && d3.attempt == 2, "cooldown elapsed: pokes again, attempt increments")

    // Genuine wake clears state — the next hollow period starts over at 1.
    let clear = waker.pokeDecision(pid: 100, awake: true, now: t0.addingTimeInterval(6))
    expectEqual(clear.poke, false, "awake never pokes")
    let afterWake = waker.pokeDecision(pid: 100, awake: false, now: t0.addingTimeInterval(7))
    expectTrue(afterWake.poke && afterWake.attempt == 1, "wake reset re-arms the limiter to attempt 1")

    // Pids are independent.
    let other = waker.pokeDecision(pid: 200, awake: false, now: t0)
    expectTrue(other.poke && other.attempt == 1, "a different pid has its own cooldown and count")
}

// Native apps short-circuit before any AX work: ensureReadable answers from
// the app's own readability, never poking (AXEnhancedUserInterface would
// trigger AppKit resize bugs).
do {
    struct NonWebStub: MeetingApp {
        let id = "stub-native"
        var displayName = "Stub"
        let processPattern = "stub"
        func meetingAnchor(_ app: AXUIElement) -> AXUIElement? { nil }
        func meetingTitle(_ app: AXUIElement, anchor: AXUIElement?) -> String { "" }
        func captionsContainer(_ app: AXUIElement) -> AXUIElement? { nil }
        func meetingElapsed(_ app: AXUIElement) -> TimeInterval? { nil }
        func captionEntries(in container: AXUIElement) -> [CaptionEntry] { [] }
        func captionsPanelOpen(_ app: AXUIElement) -> Bool { false }
        func requestCaptions(pid: pid_t) -> CaptionRequest { .unreachable }
        func chatContainer(_ app: AXUIElement) -> AXUIElement? { nil }
        func chatMessages(in container: AXUIElement) -> [ChatMessage] { [] }
        func resetCaptureState() {}
        func hasStableIdentity(_ id: String) -> Bool { false }
        func treeIsReadable(_ app: AXUIElement) -> Bool { true }
    }
    var waker = TreeWaker(quiet: true)
    let attachment = Attachment(meetingApp: NonWebStub(), pid: 42,
                                element: AXUIElementCreateSystemWide())
    expectTrue(waker.ensureReadable(attachment, now: epoch),
               "native readable app reads as readable without any wake attempt")
    // No poke state should have been created for the native pid.
    let d = waker.pokeDecision(pid: 42, awake: false, now: epoch)
    expectTrue(d.poke && d.attempt == 1, "native path left no rate-limit state behind")
}

// --- WakeLedger unification + pruning (issue #18) -----------------------

// Pruning drops only dead pids; counts for live ones survive so the
// "hollow for Ns" attempt math is never reset mid-period.
do {
    var ledger = WakeLedger()
    let d1 = ledger.pokeDecision(pid: 100, awake: false, now: epoch)
    expectTrue(d1.poke && d1.attempt == 1, "first decision pokes as attempt 1")
    let _ = ledger.pokeDecision(pid: 100, awake: false, now: epoch.addingTimeInterval(5))

    ledger.prune(alive: [100, 200])
    let d2 = ledger.pokeDecision(pid: 100, awake: false, now: epoch.addingTimeInterval(10))
    expectTrue(d2.poke && d2.attempt == 3, "live pid keeps its attempt count across prunes")

    ledger.prune(alive: [100])
    let d3 = ledger.pokeDecision(pid: 100, awake: false, now: epoch.addingTimeInterval(15))
    expectTrue(d3.poke && d3.attempt == 4, "surviving pid still accumulates")
}

do {
    var ledger = WakeLedger()
    let _ = ledger.pokeDecision(pid: 300, awake: false, now: epoch)
    ledger.prune(alive: []) // pid gone: everything resets
    let d = ledger.pokeDecision(pid: 300, awake: false, now: epoch.addingTimeInterval(5))
    expectTrue(d.poke && d.attempt == 1, "dead pid's restart starts from attempt 1 with no cooldown debt")
}

// populated membership: marks are per-pid and survive prunes of OTHER pids.
do {
    var ledger = WakeLedger()
    ledger.markPopulated(pid: 10)
    ledger.markPopulated(pid: 20)
    ledger.prune(alive: [10])
    expectTrue(ledger.isPopulated(pid: 10), "populated survives when its pid stays alive")
    expectEqual(ledger.isPopulated(pid: 20), false, "populated drops with its dead pid")
}

// --- Summary ------------------------------------------------------------

print(failures == 0 ? "\nall \(count) assertions passed" : "\n\(failures)/\(count) assertions FAILED")
exit(failures == 0 ? 0 : 1)
