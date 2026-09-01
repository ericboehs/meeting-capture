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

// --- Reading Google Meet's chat -----------------------------------------
// Meet gives chat messages no ids and no per-message grouping: the panel is a
// flat run of lines reading author, time, text, time, text, with the author
// named once however many messages they send in a row, and furniture mixed in.
do {
    let lines = [
        "Ken Hughes", "3:02 PM", "first message",
        "3:03 PM", "second message from the same person",
        "Ada Lovelace", "3:04 PM", "a reply",
        "Hover over a message to pin it",
    ]
    let messages = MeetApp.parseChat(lines)
    expectEqual(messages.count, 3, "three messages, however the names are laid out")
    expectEqual(messages.map { $0.author }, ["Ken Hughes", "Ken Hughes", "Ada Lovelace"],
                "a name carries to every message under it")
    expectEqual(messages.map { $0.text },
                ["first message", "second message from the same person", "a reply"],
                "timestamps and trailing furniture are not messages")
    expectTrue(Set(messages.map { $0.id }).count == 3, "ids distinguish the messages")

    expectEqual(MeetApp.parseChat(["Ken", "3:02 PM", "same words"]).first?.id,
                MeetApp.parseChat(["Ken", "3:02 PM", "same words"]).first?.id,
                "ids are stable across runs, so a restart mid-meeting does not repeat chat")
    expectTrue(MeetApp.parseChat(["Ken", "3:02 PM", "same words"]).first?.id
                 != MeetApp.parseChat(["Ken", "3:03 PM", "same words"]).first?.id,
               "the same words a minute later is a new message")
    expectEqual(MeetApp.parseChat(["3:02 PM", "no name yet"]).first?.author, "Unknown",
                "a message with no name above it still gets recorded")

    expectTrue(MeetApp.isTimestamp("3:02 PM"), "12-hour clock")
    expectTrue(MeetApp.isTimestamp("15:02"), "24-hour clock")
    expectTrue(MeetApp.isTimestamp("3:02\u{202f}PM"), "narrow no-break space, which macOS uses")
    expectTrue(MeetApp.isTimestamp("12:00 a.m."), "lowercase suffix with stops")
    expectTrue(!MeetApp.isTimestamp("Ken Hughes"), "a name is not a clock")
    expectTrue(!MeetApp.isTimestamp("4:03 is an oddly specific time"),
               "a sentence that opens with a clock is not a clock")
    expectTrue(!MeetApp.isTimestamp("Hover over a message to pin it"), "furniture is not a clock")
}

// --- Tucking the popped-out captions window ------------------------------
// The window has to stay OPEN (minimized, it receives nothing at all) but it
// does not have to be visible, so it is pushed off the outside edge of the
// second display with a nub left on screen. Display rects are in the global
// top-left space AX and CGDisplayBounds share; the primary is at the origin.
do {
    let primary = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let onTheLeft = CGRect(x: -1920, y: 252, width: 1920, height: 1080)
    let onTheRight = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
    let panel = CGSize(width: 620, height: 360)

    expectEqual(tuckOrigin(windowSize: panel, displays: [primary, onTheLeft]),
                CGPoint(x: -2500, y: 1292),
                "a display on the left: push off ITS left edge, away from the primary")
    expectEqual(tuckOrigin(windowSize: panel, displays: [onTheLeft, primary]),
                CGPoint(x: -2500, y: 1292),
                "which display is listed first does not matter; the origin decides")
    expectEqual(tuckOrigin(windowSize: panel, displays: [primary, onTheRight]),
                CGPoint(x: 4440, y: 1040),
                "a display on the right: push off its right edge, or it lands on the primary")
    expectEqual(tuckOrigin(windowSize: panel, displays: [primary]),
                CGPoint(x: -580, y: 1400),
                "one display: still tuck it, there is nowhere else to put it")
    expectTrue(tuckOrigin(windowSize: panel, displays: []) == nil,
               "no displays, nowhere to tuck")
    expectEqual(tuckOrigin(windowSize: panel, displays: [primary, onTheLeft], showing: 0),
                CGPoint(x: -2540, y: 1332),
                "showing is how much of the window is left on screen")
}

// --- Naming a Teams meeting ---------------------------------------------
// Teams' side windows put a label in FRONT of the meeting's own title. When
// the meeting window is covered, the meeting is found in the compact view,
// and the label would otherwise end up naming the transcript. The label is
// localized, so it is spotted structurally: the meeting window titles itself
// with the bare name, so the shortest sibling title that is a suffix wins.
do {
    let meeting = "Standup | Microsoft Teams"
    let compact = "Meeting compact view | Standup | Microsoft Teams"
    let captions = "Captions | Standup | Microsoft Teams"

    expectEqual(TeamsApp.stripChrome(compact, siblings: [meeting, compact, captions]), "Standup",
                "the compact view's label does not become the meeting's name")
    expectEqual(TeamsApp.stripChrome(captions, siblings: [meeting, compact, captions]), "Standup",
                "nor does the captions window's")
    expectEqual(TeamsApp.stripChrome(meeting, siblings: [meeting, compact, captions]), "Standup",
                "the meeting window's own title is already right")
    expectEqual(TeamsApp.stripChrome(compact, siblings: [compact]), "Meeting compact view | Standup",
                "with no meeting window to compare against, keep every word: a\n"
                + "      label cannot be told from a name by punctuation alone")
    expectEqual(TeamsApp.stripChrome("Meeting compact view | Roadmap | Q3 | Microsoft Teams",
                                     siblings: ["Roadmap | Q3 | Microsoft Teams"]),
                "Roadmap | Q3",
                "a meeting whose name contains a pipe survives")
    expectEqual(TeamsApp.stripChrome("Standup | Microsoft Teams", siblings: ["Chat | Microsoft Teams"]),
                "Standup",
                "a sibling that is not a suffix is not a chrome label")
}

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
    // A window that GROWS past what is retained. Meet's caption panel
    // accumulates as a call goes on, and overlap matching compares the
    // window's prefix against history's suffix — so the moment history holds
    // less than a window, the two can never line up again. Every poll then
    // looks entirely new and rewrites the whole panel at fresh positions.
    //
    // A 29-minute Meet call did exactly this: 882,307 caption events for 734
    // distinct lines, a 199 MB transcript of the same sentences over and over.
    let h = SegmentHistory()
    var all = (0..<900).map { SegmentKey(speaker: "Speaker\($0 % 7)", text: "sentence \($0)") }
    var anchored = true
    for count in 1...all.count where h.absorb(Array(all.prefix(count))) != 0 { anchored = false }
    expectTrue(anchored, "a window growing past the retained history keeps its anchor")

    // Once it is that wide, the panel starts dropping its oldest blocks: the
    // anchor has to move by exactly what left, not by a whole window.
    expectEqual(h.absorb(Array(all.dropFirst(40))), 40, "dropping the oldest blocks shifts by what left")
    all.append(SegmentKey(speaker: "Speaker0", text: "one more"))
    expectEqual(h.absorb(Array(all.dropFirst(40))), 40, "and a new segment after that still appends")
}

do {
    // Speech recognition revises what it already put on screen. Meet was
    // caught correcting a segment 33 places back — 43 characters becoming 45 —
    // and an exact prefix match cannot survive that: every segment around the
    // change looked new, and a six-minute call wrote 128 utterances as 2,110
    // lines.
    let h = SegmentHistory()
    let window = (0..<20).map { SegmentKey(speaker: "Speaker\($0 % 3)", text: "sentence \($0)") }
    let base = h.absorb(window)
    var revised = window
    revised[7] = SegmentKey(speaker: revised[7].speaker, text: "sentence 7, corrected")
    expectEqual(h.absorb(revised), base, "a corrected segment keeps the position it was written at")
    expectEqual(h.absorb(revised), base, "and the correction is what is remembered from then on")

    // A correction and a new sentence in the same poll: still one new position.
    var grown = revised
    grown[7] = SegmentKey(speaker: grown[7].speaker, text: "sentence 7, corrected again")
    grown.append(SegmentKey(speaker: "Speaker1", text: "sentence 20"))
    expectEqual(h.absorb(grown), base, "a correction alongside a new segment still anchors")
    expectEqual(h.absorb(Array(grown.dropFirst(3))), base + 3, "and scrolling after that shifts by what left")
}

do {
    // The anchor must not be so eager that a repeated line is stapled onto the
    // one before it — people do say the same short thing twice.
    let h = SegmentHistory()
    _ = h.absorb([SegmentKey(speaker: "Grace", text: "Yeah."),
                  SegmentKey(speaker: "Alan", text: "Right.")])
    expectEqual(h.absorb([SegmentKey(speaker: "Grace", text: "Yeah."),
                          SegmentKey(speaker: "Bo", text: "Different.")]), 2,
                "a window that only agrees on its first line counts as new")
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
    // .elapsed keeps the jsonl `elapsed` field deterministic (00:00:00 from the
    // epoch start). Transcript stamps are wall-clock and therefore timezone
    // dependent, so tests compare against clockText rather than a literal.
    // URLs are unique per call so a future real-sink test can't collide.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    return Recorder(options: opts, startedAt: epoch, mode: .elapsed(from: epoch),
                    jsonlURL: dir.appendingPathComponent("mc-injected-\(UUID().uuidString).jsonl"),
                    textURL: dir.appendingPathComponent("mc-injected-\(UUID().uuidString).txt"),
                    jsonl: jsonl, text: text)
}

/// The wall-clock stamp the transcript uses for `date`.
func clockStamp(_ date: Date) -> String { Recorder.clockText(from: date) }

// The two files stamp the same instant differently on purpose: the jsonl keeps
// meeting-relative `elapsed`, the transcript carries the time of day.
//
// The offset is deliberately over 24h. elapsedString does not wrap hours, so
// "30:01:01" cannot collide with a wall-clock stamp in ANY timezone — whereas
// a 1h offset from the epoch renders as "01:01:01" both ways under UTC, which
// is exactly how the first version of this test passed locally and failed CI.
do {
    let jsonl = MemorySink(path: "/tmp/j.jsonl"), text = MemorySink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    let at = epoch.addingTimeInterval(30 * 3600 + 61)
    _ = r.record(kind: "caption", speaker: "A", body: "split", at: at)
    expectTrue(jsonl.string.contains("\"elapsed\":\"30:01:01\""),
               "jsonl keeps the meeting-relative elapsed field")
    expectTrue(text.string.contains("[\(clockStamp(at))] A: split"),
               "transcript stamps the time of day, not the elapsed offset")
    expectTrue(!text.string.contains("30:01:01"),
               "transcript does not carry the elapsed offset at all")
}

// All-paths-succeed: both files carry the line.
do {
    let jsonl = MemorySink(path: "/tmp/j.jsonl"), text = MemorySink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    expectEqual(r.record(kind: "caption", speaker: "A", body: "hello", at: epoch),
                WriteOutcome.written("[\(clockStamp(epoch))] A: hello"),
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
                WriteOutcome.jsonOnly("[\(clockStamp(epoch))] B: owed"),
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
                WriteOutcome.written("[\(clockStamp(epoch))] C: one"), "first write lands")
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
    var stubReadiness: TreeReadiness = .webContent
    func treeReadiness(_ app: AXUIElement) -> TreeReadiness { stubReadiness }
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
        func treeReadiness(_ app: AXUIElement) -> TreeReadiness { .webContent }
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

// --- Re-opening a finalized caption row only on genuine growth ----------
//
// Regression: a Teams row frozen mid-revision ("...via CPRS. The") sat on
// screen for four minutes and was written eight times, ~33s apart. The old
// growth check scanned the `written` buffer for anything the current text
// extended, so the row's OWN earlier, shorter write ("...via CPRS.") made it
// look like it was still growing on every poll — re-opening it forever, paced
// only by alreadyWritten's 30s TTL.

do {
    let clock = FakeClock(start: epoch, step: 0.5)
    let s = injectedSession(clock: clock)

    expectEqual(s.reopensAfterGrowth(id: "3570", text: "anything"), false,
                "a row we never finalized is not a re-open candidate")

    // Teams' real sequence: the row is finalized short, then genuinely grows.
    let short = "...enter patient vitals via CPRS."
    let grown = "...enter patient vitals via CPRS. The"
    s.finalizedText["3570"] = short
    expectTrue(s.reopensAfterGrowth(id: "3570", text: grown),
               "a row that genuinely extended its own finalized text re-opens")

    // ...and then freezes there. THIS is the case that used to loop forever:
    // `grown` is still a strict extension of `short`, which remains in the
    // written buffer, but the row itself has not moved since we finalized it.
    s.finalizedText["3570"] = grown
    expectEqual(s.reopensAfterGrowth(id: "3570", text: grown), false,
                "a row frozen at its finalized text never re-opens, however long it lingers")

    // A different sentence under a recycled id is not growth either; that path
    // belongs to the normal new-utterance branch.
    expectEqual(s.reopensAfterGrowth(id: "3570", text: "A completely different sentence."), false,
                "replacement text is not growth")
    expectEqual(s.reopensAfterGrowth(id: "3570", text: short), false,
                "text shrinking back below the finalized form is not growth")

    // Growth is per row: one row's history must not speak for another's.
    expectEqual(s.reopensAfterGrowth(id: "4803", text: grown), false,
                "another row's finalized text cannot re-open this one")
}

// --- alreadyWritten: prefix-aware, and asymmetric on purpose -------------
//
// Exact-equality matching let a partly-rendered re-read of an already-written
// row through. Prefix matching closes that, but only in the safe direction:
// suppress when the transcript already holds a SUPERSET of the incoming text,
// never when the incoming text carries content the file does not have.

func utterance(_ speaker: String, _ text: String) -> Utterance {
    Utterance(speaker: speaker, text: text, startedAt: epoch, changedAt: epoch)
}

do {
    let clock = FakeClock(start: epoch, step: 0)
    let s = injectedSession(clock: clock)
    let now = epoch.addingTimeInterval(10)

    // Real text from the duplicated stand-up row (node 3570), truncated.
    let full  = "users at North Port reported issues entering patient vitals via CPRS."
    let part  = "users at North Port reported issues entering"
    let extra = full + " The"
    s.written = [Session.WrittenLine(speaker: "Dalton, Belinda J.", text: full, at: epoch)]

    expectTrue(s.alreadyWritten(utterance("Dalton, Belinda J.", full), id: "n1", now: now),
               "an identical re-render is still suppressed")
    expectTrue(s.alreadyWritten(utterance("Dalton, Belinda J.", part), id: "n1", now: now),
               "a partly-rendered re-read is suppressed: the file already holds a superset")
    expectEqual(s.alreadyWritten(utterance("Dalton, Belinda J.", extra), id: "n1", now: now), false,
                "text that EXTENDS a written line is never suppressed — the extension is new content")
    expectEqual(s.alreadyWritten(utterance("Krebs, Kendall N.", full), id: "n1", now: now), false,
                "another speaker saying the same words is a real utterance")

    // The window is a heuristic, so genuine repetition survives it.
    let later = epoch.addingTimeInterval(Session.rewriteWindow + 1)
    expectEqual(s.alreadyWritten(utterance("Dalton, Belinda J.", full), id: "n1", now: later), false,
                "past the rewrite window, repeated speech is written again")

    // Suppression is unrelated to how short the incoming text is: a genuinely
    // brief utterance that happens to prefix a longer written one is the
    // acknowledged cost of the safe direction.
    expectTrue(s.alreadyWritten(utterance("Dalton, Belinda J.", "users"), id: "n1", now: now),
               "a short prefix of a written line is treated as a re-read")
}

// --- Node-id churn: the suppressor lives as long as the row is on screen ---
//
// Regression: Teams re-creates a finished caption row with a fresh
// ChromeAXNodeId while it lingers on screen, so every churn reads as a new
// utterance. With the window counted from write time, the row was written
// again the moment 30s lapsed — "All right, so this is sprint planning for
// Sprint 23." landed at 00:04:49 and then AGAIN at 00:05:22, mid-conversation.

do {
    let clock = FakeClock(start: epoch, step: 0)
    let s = injectedSession(clock: clock)
    let speaker = "Dehaan, Jason R."
    let line = "All right, so this is sprint planning for Sprint 23."
    s.written = [Session.WrittenLine(speaker: speaker, text: line, at: epoch)]

    let lapsed = epoch.addingTimeInterval(Session.rewriteWindow + 3)
    expectEqual(s.alreadyWritten(utterance(speaker, line), id: "3570", now: lapsed), false,
                "a row that left the screen may be said again after the window")

    // Same poll, but the row is still up: every poll refreshes the suppressor,
    // so the recycled node never re-emits however long the row lingers.
    for tick in stride(from: 0.0, through: Session.rewriteWindow + 3, by: 5) {
        s.refreshWrittenLines(
            visibleIn: [CaptionEntry(id: "churn-\(tick)", speaker: speaker, text: line)],
            now: epoch.addingTimeInterval(tick))
    }
    expectTrue(s.alreadyWritten(utterance(speaker, line), id: "9901", now: lapsed),
               "a row still on screen keeps suppressing its own re-render under a new node id")

    // Only EXACT text holds a suppressor open. A genuinely short utterance that
    // happens to prefix a lingering longer one must still get through once the
    // window from WRITE time has passed.
    expectEqual(s.alreadyWritten(utterance(speaker, "All right."), id: "9902", now: lapsed), false,
                "a lingering longer line does not swallow a later short utterance")

    // ...and a row that is no longer visible stops being refreshed, so genuine
    // repetition returns to the plain 30s window.
    s.refreshWrittenLines(
        visibleIn: [CaptionEntry(id: "other", speaker: speaker, text: "Something else entirely.")],
        now: lapsed)
    expectEqual(s.alreadyWritten(utterance(speaker, line), id: "9903",
                                 now: lapsed.addingTimeInterval(Session.rewriteWindow + 1)), false,
                "once the row scrolls away the suppressor expires again")
}

// --- Live-region stamps never precede what is already in the transcript ----
//
// Regression: the live block stamped each pending line with when it BEGAN,
// while finished lines are clamped to the transcript's high-water mark. A long
// sentence still being spoken therefore appeared under a later line that had
// already landed, reading as though the clock ran backwards.

do {
    func pending(_ speaker: String, _ text: String, at offset: TimeInterval) -> Utterance {
        let at = epoch.addingTimeInterval(offset)
        return Utterance(speaker: speaker, text: text, startedAt: at, changedAt: at)
    }
    let clockText = { (offset: TimeInterval) in
        Recorder.clockText(from: epoch.addingTimeInterval(offset))
    }

    let lines = Session.liveLines(
        [pending("Dehaan", "All right.", at: 33), pending("Smith", "He's still waiting", at: 37)],
        after: epoch.addingTimeInterval(36))
    expectEqual(lines, ["[\(clockText(36))] Dehaan: All right.",
                        "[\(clockText(37))] Smith: He's still waiting"],
                "a pending line older than the last written one is clamped up to it")

    let unclamped = Session.liveLines([pending("Dehaan", "All right.", at: 33)], after: nil)
    expectEqual(unclamped, ["[\(clockText(33))] Dehaan: All right."],
                "with nothing written yet the line keeps its own start time")

    let cumulative = Session.liveLines(
        [pending("A", "one", at: 50), pending("B", "two", at: 40)], after: nil)
    expectEqual(cumulative, ["[\(clockText(50))] A: one", "[\(clockText(50))] B: two"],
                "the clamp is cumulative, so the pending block reads in order within itself")
}

// --- A row that resumes after being written owes only its new tail --------
//
// Regression (Zoom): with two people talking, Zoom keeps a live, still-growing
// row per speaker. finalizesWhenSuperseded called the older one finished on
// every poll, and since text that EXTENDS a written line is never suppressed,
// the row was written once per second, each line repeating the last:
//   "Yeah, I told him about Wilson. So, like, that's"
//   "Yeah, I told him about Wilson. So, like, that's how this all"
// The app-side half is Zoom finalizing on idle only; this is the general half.

do {
    expectEqual(ZoomApp().finalizesWhenSuperseded, false,
                "Zoom rows are not finished merely because someone else started talking")

    let said = "Yeah, I told him about Wilson."
    expectEqual(Session.unwrittenPart(of: said, alreadyEmitted: nil), said,
                "a row nothing was written for owes all of it")
    expectEqual(Session.unwrittenPart(of: said + " So, like, that's", alreadyEmitted: said),
                "So, like, that's",
                "a row that grew owes only the words added since it was written")
    expectEqual(Session.unwrittenPart(of: said, alreadyEmitted: said), nil,
                "a row frozen at what was already written owes nothing")
    expectEqual(Session.unwrittenPart(of: said + "   ", alreadyEmitted: said), nil,
                "trailing whitespace is not new content")
    expectEqual(Session.unwrittenPart(of: "A completely different sentence.", alreadyEmitted: said),
                "A completely different sentence.",
                "a recycled row holding new text owes the whole thing")
    expectEqual(Session.unwrittenPart(of: "Yeah, I told him", alreadyEmitted: said),
                "Yeah, I told him",
                "text shrinking below what was written is a replacement, not growth")
}

// Apps with stable caption ids opt out of content matching entirely: their ids
// already name one logical utterance, so identical text is genuine repetition.
do {
    let clock = FakeClock(start: epoch, step: 0)
    let s = injectedSession(clock: clock)
    s.written = [Session.WrittenLine(speaker: "A", text: "same words", at: epoch)]
    expectTrue(s.alreadyWritten(utterance("A", "same words"), id: "unstable", now: epoch),
               "unstable ids fall back to content matching")
    expectEqual(StubMeetingApp().hasStableIdentity("seg:1"), false,
                "the stub models an unstable-id app")
}

// --- processMatches -----------------------------------------------------
//
// Replaces pgrep -f. Four process spawns every two seconds were 10% of a
// core all evening with no meeting happening. The patterns are the same
// strings; they now match executable path + bundle path.

do {
    let teams = "Microsoft Teams.app/Contents/MacOS/MSTeams"
    expectTrue(processMatches(pattern: teams,
                              executable: "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams",
                              bundle: "/Applications/Microsoft Teams.app"),
               "Teams main binary matches")
    expectTrue(!processMatches(pattern: teams,
                               executable: "/Library/Audio/Plug-Ins/HAL/MSTeamsAudioDevice.driver/Contents/MacOS/MSTeamsAudioDevice",
                               bundle: ""),
               "Teams audio driver does not steal the pid")

    let slack = "Slack.app/Contents/MacOS/Slack"
    expectTrue(processMatches(pattern: slack,
                              executable: "/Applications/Slack.app/Contents/MacOS/Slack",
                              bundle: "/Applications/Slack.app"),
               "Slack main binary matches")
    expectTrue(!processMatches(pattern: slack,
                               executable: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper",
                               bundle: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app"),
               "Slack Helper is not the meeting UI")

    let zoom = "zoom.us.app/Contents/MacOS/zoom.us"
    expectTrue(processMatches(pattern: zoom,
                              executable: "/Applications/zoom.us.app/Contents/MacOS/zoom.us",
                              bundle: "/Applications/zoom.us.app"),
               "Zoom main binary matches")

    // Safari web apps: executable is "Web App", bundle is "Google Meet.app".
    // Neither half matches the pattern alone the way pgrep -f saw the command
    // line (`Web App --bundlepath .../Google Meet.app`), so both are searched.
    let meet = "Web App .*Google Meet.app"
    expectTrue(processMatches(pattern: meet,
                              executable: "/Users/eric/Applications/Google Meet.app/Contents/MacOS/Web App",
                              bundle: "/Users/eric/Applications/Google Meet.app"),
               "Meet web app matches executable + bundle")
    expectTrue(!processMatches(pattern: meet,
                               executable: "/Applications/Safari.app/Contents/MacOS/Safari",
                               bundle: "/Applications/Safari.app"),
               "Safari itself is not Meet")
    expectTrue(!processMatches(pattern: meet,
                               executable: "/Users/eric/Applications/Some Other.app/Contents/MacOS/Web App",
                               bundle: "/Users/eric/Applications/Some Other.app"),
               "a different Safari web app is not Meet")
}

// --- usableEntry --------------------------------------------------------
//
// A decayed NSWorkspace snapshot serves entries with no name and no path, and
// a daemon that trusts it misses every meeting for as long as it lives —
// three days, once. Any entry LaunchServices can describe proves the list is
// alive; a list that cannot describe even Finder is broken, not empty.

do {
    expectTrue(usableEntry(executable: "/Applications/Slack.app/Contents/MacOS/Slack",
                           bundle: "/Applications/Slack.app",
                           bundleID: "com.tinyspeck.slackmacgap"),
               "a fully described app is usable")
    expectTrue(usableEntry(executable: "", bundle: "", bundleID: "com.apple.finder"),
               "a bundle identifier alone is enough")
    expectTrue(usableEntry(executable: "/usr/bin/pgrep", bundle: "", bundleID: ""),
               "a path alone is enough")
    expectTrue(!usableEntry(executable: "", bundle: "", bundleID: ""),
               "nothing known is not usable — the list has decayed")
}

// --- rosterCount / bareName ---------------------------------------------
//
// The People panel's head count is only available in its title row — the
// People button itself carries no number in the tree. Two shapes were seen
// live: the StaticText value "In this meeting (293)" and the section's own
// description "In this meeting, 293 total".

do {
    expectEqual(rosterCount(from: ["In this meeting (293)"]), 293,
                "the count reads out of the title row's parenthesised text")
    expectEqual(rosterCount(from: ["", "In this meeting (8)"]), 8,
                "candidates are tried in order and blanks are skipped")
    expectEqual(rosterCount(from: ["In this meeting, 293 total"]), 293,
                "the section description's 'N total' also counts")
    expectEqual(rosterCount(from: ["Participants", "Close participants pane"]), nil,
                "a panel without a title row reports no count")
    expectEqual(rosterCount(from: ["In this meeting ()"]), nil,
                "an empty parenthesised group is not a count")
}

// Row descriptions trail state chips: "Allen, Mary Catherine, Organizer,
// Muted". The name is everything before them, and commas INSIDE the name
// ("Last, First") survive because only trailing chips are stripped.
do {
    expectEqual(bareName(from: "Eric Boehs, Muted"), "Eric Boehs",
                "the muted chip is not part of the name")
    expectEqual(bareName(from: "Alvarado, Vicky N., Organizer, Muted"), "Alvarado, Vicky N.",
                "organizer and muted chips strip, name commas survive")
    expectEqual(bareName(from: "Clarkson, Steven A."), "Clarkson, Steven A.",
                "a description with no chips is the bare name")
    expectEqual(bareName(from: "Muted"), "",
                "a description that is only chips leaves nothing")
    expectEqual(bareName(from: "Parker, Dana, Speaking"), "Parker, Dana",
                "other states strip the same way")
}

// Long rosters expose a StaticText paginator, first "See more" and then
// "+203 more" as pages load. Participant row context buttons say "More
// options" and must never be mistaken for the paginator.
do {
    expectTrue(isRosterPager("See more"), "the first roster paginator is recognised")
    expectTrue(isRosterPager("+203 more"), "the numbered roster paginator is recognised")
    expectTrue(isRosterPager("+9 more"), "a one-digit remaining count is recognised")
    expectTrue(!isRosterPager("More options"), "participant context menus are not paginators")
    expectTrue(!isRosterPager("+ people"), "a malformed numbered paginator is rejected")
    expectEqual(rosterPagerRemaining("+203 more"), 203, "the remaining count parses")
    expectEqual(rosterPagerRemaining("See more"), nil, "the first unnumbered page has no remaining count")
}

// --- Summary ------------------------------------------------------------

print(failures == 0 ? "\nall \(count) assertions passed" : "\n\(failures)/\(count) assertions FAILED")
exit(failures == 0 ? 0 : 1)
