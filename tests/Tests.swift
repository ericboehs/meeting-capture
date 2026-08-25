// Unit tests for meeting-capture. Run with tests/run.sh.
//
// This is the only file in the test build with top-level code; everything below
// "// MARK: - Main" in bin/meeting-capture is stripped by tests/run.sh.
// Covers pure logic plus filesystem helpers (state-file reads/removals,
// transcript tailing) via temp files; AX/processes/real time are not exercised.
import Foundation

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
expectTrue(isMissingFileError(cocoaError(NSFileNoSuchFileError)), "code 4 is missing")
expectTrue(isMissingFileError(cocoaError(NSFileReadNoSuchFileError)), "code 256 is missing")
expectTrue(isMissingFileError(cocoaError(NSFileReadUnknownError, underlyingPOSIX: ENOENT)),
           "generic 260 wrapped around ENOENT is missing")
expectTrue(!isMissingFileError(cocoaError(NSFileReadUnknownError)),
           "generic 260 WITHOUT ENOENT underneath is a real failure (EIO/ESTALE surface as 260)")
expectTrue(!isMissingFileError(cocoaError(NSFileReadNoPermissionError)), "EACCES is a failure, not idle")
expectTrue(!isMissingFileError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)),
           "raw POSIX EACCES is a failure, not idle")

// --- Summary ------------------------------------------------------------

print(failures == 0 ? "\nall \(count) assertions passed" : "\n\(failures)/\(count) assertions FAILED")
exit(failures == 0 ? 0 : 1)
