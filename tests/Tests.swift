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

// --- Telling Google Meet's speakers from what they said -------------------
// Meet writes name, sentences, name, sentences... but prunes old captions off
// the front, and the alternation does not even hold end to end: one live list
// had its names on the even indices at the top and the odd ones at the bottom.
// Typography is what holds — the name is set smaller than the caption — so
// every group is judged on its own.
do {
    typealias Shape = MeetApp.CaptionBlockShape
    // The live shape: 16pt names against 25pt captions, some groups holding
    // several sentences.
    let panel = [
        Shape(lines: 1, height: 16),   // name
        Shape(lines: 5, height: 120),  // what they said
        Shape(lines: 1, height: 16),   // name
        Shape(lines: 1, height: 25),   // one sentence
    ]
    expectEqual(MeetApp.nameBlocks(panel), [true, false, true, false],
                "the smaller type is the speaker's name")
    // Pruning one group off the front changes nothing, which is the whole
    // point: this is what silently inverted every line before.
    expectEqual(MeetApp.nameBlocks(Array(panel.dropFirst())), [false, true, false],
                "pruning an odd number no longer swaps speakers with their words")
    // A run that breaks the alternation outright — two names with nothing said
    // between them, then two groups of speech.
    expectEqual(MeetApp.nameBlocks([
        Shape(lines: 1, height: 16), Shape(lines: 1, height: 16),
        Shape(lines: 1, height: 25), Shape(lines: 3, height: 75),
    ]), [true, true, false, false],
                "a broken alternation is read correctly rather than shifted")
    expectEqual(MeetApp.nameBlocks([
        Shape(lines: 1, height: 16), Shape(lines: 1, height: 50),
    ]), [true, false],
                "a caption that wraps to two visual lines is still a caption")
    expectEqual(MeetApp.nameBlocks([Shape(lines: 9, height: 200), Shape(lines: 1, height: 16)]),
                [false, true],
                "a group of sentences gives the caption line height, so the small one is a name")

    // Nothing measurable: fall back to alternation, anchored at the END, since
    // the front is the end Meet prunes.
    expectEqual(MeetApp.nameBlocks([
        Shape(lines: 1, height: 0), Shape(lines: 1, height: 0),
        Shape(lines: 1, height: 0), Shape(lines: 1, height: 0),
    ]), [true, false, true, false],
                "with no type sizes, pair backwards from the newest caption")
    expectEqual(MeetApp.nameBlocks([]), [], "an empty panel yields nothing")
}

// --- Reading Google Meet's chat -----------------------------------------
// Google moved chat into the Chat product's iframe: messages are structured
// rows now, each ending in a relative age ("3 min"), with the sender named
// once however many messages they send in a row.
do {
    typealias Row = MeetApp.MeetChatRow
    let rows = [
        Row(sender: "Ken Hughes", text: "first message", age: "5 min"),
        Row(sender: "", text: "second message from the same person", age: "4 min"),
        Row(sender: "Ada Lovelace", text: "a reply", age: "2 min"),
    ]
    let messages = MeetApp.messages(from: rows)
    expectEqual(messages.count, 3, "three rows are three messages")
    expectEqual(messages.map { $0.author }, ["Ken Hughes", "Ken Hughes", "Ada Lovelace"],
                "a sender carries down to the follow-ups that omit the name")
    expectEqual(messages.map { $0.text },
                ["first message", "second message from the same person", "a reply"],
                "the text is taken verbatim")
    expectTrue(Set(messages.map { $0.id }).count == 3, "ids distinguish the messages")

    expectEqual(MeetApp.messages(from: [Row(sender: "Ken", text: "hi", age: "1 min")]).first?.id,
                MeetApp.messages(from: [Row(sender: "Ken", text: "hi", age: "1 min")]).first?.id,
                "ids are stable across runs, so a restart mid-meeting does not repeat chat")
    // The reason ages are not hashed: a message's age ticks while it sits
    // there, and an id that moved with it would re-record the whole panel
    // every minute.
    expectEqual(MeetApp.messages(from: [Row(sender: "Ken", text: "hi", age: "1 min")]).first?.id,
                MeetApp.messages(from: [Row(sender: "Ken", text: "hi", age: "9 min")]).first?.id,
                "the same message growing older is still the same message")
    // ...  and the price of that: identical words twice are told apart by
    // where they sit rather than by when they were sent.
    let twice = MeetApp.messages(from: [
        Row(sender: "Ken", text: "same words", age: "9 min"),
        Row(sender: "", text: "same words", age: "1 min"),
    ])
    expectEqual(twice.count, 2, "the same words twice are two messages")
    expectTrue(twice[0].id != twice[1].id, "and they are told apart by position")

    expectEqual(MeetApp.messages(from: [Row(sender: "", text: "no name yet", age: "1 min")])
                    .first?.author,
                "Unknown", "a message with no name above it still gets recorded")
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

// --- Teams chat classes ---------------------------------------------------
// Class lists exactly as the live tree exposed them on 2026-10-08.

do {
    expectTrue(TeamsChatClasses.isBody(["fui-ChatMessage__body", "fui-Primitive"]),
               "someone else's message body is chat")
    expectTrue(TeamsChatClasses.isBody(["fui-ChatMyMessage__body"]),
               "your own message body is chat too: Teams draws it with ChatMyMessage")
    expectTrue(TeamsChatClasses.isAuthor(["fui-ChatMyMessage__author"]),
               "and your own message has an author part to read the name from")
    expectTrue(TeamsChatClasses.isAuthor(["fui-ChatMessage__author"]), "as everyone else's does")
    expectTrue(!TeamsChatClasses.isBody(["fui-ChatMessageCompact__body"]),
               "a caption is not a chat message")
    expectTrue(!TeamsChatClasses.isBody(["fui-ChatControlMessage"]),
               "nor is a control message such as someone joining")
    expectTrue(!TeamsChatClasses.isBody(["fui-ChatMyMessage__timestamp", "fui-ChatMessage__author"]),
               "nor any other part of a message")
}

// --- SegmentHistory -----------------------------------------------------
// Caption surfaces without ids (Meet blocks, Slack overlay events) get their
// identity from position in the conversation. Repeated utterances must stay
// distinct — a single "Yeah." said twice was the bug that produced this class.

do {
    // Meet trims old captions off the front of the panel — and not only whole
    // segments: once it is full, about once a minute, the oldest caption still
    // showing loses its opening words. Measured on a 30-minute call, every one
    // of those trims made the whole window look new: 13 bursts of ~85 lines,
    // 1,296 lines for 288 utterances.
    func line(_ i: Int) -> SegmentKey {
        SegmentKey(speaker: i % 2 == 0 ? "Alex Teal" : "You", text: "Sentence one of \(i). Sentence two of \(i).")
    }
    func trimmed(_ i: Int) -> SegmentKey {
        SegmentKey(speaker: line(i).speaker, text: "Sentence two of \(i).")
    }
    let h = SegmentHistory()
    let all = (0..<90).map(line)
    expectEqual(h.absorb(all), 0, "a full panel sits at the start")
    expectEqual(h.absorb([trimmed(0)] + all.dropFirst()), 0,
                "the oldest caption losing its opening words moves nothing")
    expectTrue(h.lastUnaligned == nil, "and is not reported as a window that failed to line up")
    expectEqual(h.absorb([trimmed(0)] + all.dropFirst() + [line(90)]), 0,
                "the trimmed form is what is remembered, so the next poll lines up directly")
    expectEqual(h.absorb([trimmed(6)] + all[7...] + [line(90), line(91)]), 6,
                "a minute later: whole captions gone and the new oldest one trimmed")
    expectEqual(h.absorb([SegmentKey(speaker: line(6).speaker, text: "of 6.")] + all[7...] + [line(90), line(91)]), 6,
                "trimmed again, further")
}

do {
    // A trim is the same speaker's words cut short, nothing looser.
    let h = SegmentHistory()
    let rest = (1...5).map { SegmentKey(speaker: "B", text: "line \($0)") }
    _ = h.absorb([SegmentKey(speaker: "A", text: "Okay. Yeah.")] + rest)
    expectEqual(h.absorb([SegmentKey(speaker: "Z", text: "Yeah.")] + rest), 0,
                "a different speaker's tail still anchors on the rest of the window")
    let short = SegmentHistory()
    _ = short.absorb([SegmentKey(speaker: "A", text: "Okay. Yeah."), SegmentKey(speaker: "B", text: "b")])
    expectEqual(short.absorb([SegmentKey(speaker: "A", text: "Yeah."), SegmentKey(speaker: "C", text: "c")]), 2,
                "in a two-segment window a matching tail alone is not agreement: \"Yeah.\" again is new")
}

do {
    // No single segment can veto a position any more. Whatever makes the
    // oldest visible one unrecognisable — a trim, a garbled speaker — the rest
    // of the window still says where it is.
    let h = SegmentHistory()
    let all = (0..<20).map { SegmentKey(speaker: "S\($0 % 3)", text: "line \($0)") }
    _ = h.absorb(all)
    let garbled = [SegmentKey(speaker: "", text: "???")] + all[4...]
    expectEqual(h.absorb(garbled), 3, "an unrecognisable oldest segment takes the place it sits in")
    expectTrue(h.lastUnaligned == nil, "which is lining up, not writing the window again")
    expectEqual(h.absorb(Array(all[4...]) + [SegmentKey(speaker: "S0", text: "new")]), 4,
                "and the window carries on from there")
}

do {
    // When a window does fail to line up, say how much of it was already
    // recorded: mostly-known means a bug, not a burst of new speech.
    let h = SegmentHistory()
    _ = h.absorb([SegmentKey(speaker: "V", text: "x")])
    _ = h.absorb([SegmentKey(speaker: "W", text: "y"), SegmentKey(speaker: "V", text: "x")])
    expectEqual(h.lastUnaligned, SegmentHistory.Unaligned(window: 2, alreadyRecorded: 1),
                "an unaligned window reports its size and how much was already recorded")
    _ = h.absorb([SegmentKey(speaker: "V", text: "x"), SegmentKey(speaker: "Q", text: "z")])
    expectTrue(h.lastUnaligned == nil, "a window that lines up clears the report")
}

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

// Events that are not someone speaking are tagged by kind, and a roster has
// no speaker at all — "(people) : 3 in the meeting" would read like a bug.
do {
    let jsonl = MemorySink(path: "/tmp/j.jsonl"), text = MemorySink(path: "/tmp/t.txt")
    let r = injectedRecorder(jsonl: jsonl, text: text)
    expectEqual(r.record(kind: "chat", speaker: "Alex Teal", body: "hi", at: epoch),
                WriteOutcome.written("[\(clockStamp(epoch))] (chat) Alex Teal: hi"),
                "chat keeps its tag and its author")
    expectEqual(r.record(kind: "people", speaker: "", body: "3 in the meeting", at: epoch),
                WriteOutcome.written("[\(clockStamp(epoch))] (people) 3 in the meeting"),
                "a speakerless event is written without an empty attribution")
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

func injectedSession(clock: FakeClock, app: MeetingApp = StubMeetingApp()) -> Session {
    var opts = Options()
    opts.quiet = true // LiveView goes non-interactive; status() still stderr
    // Never touch the real user state directory from tests.
    opts.stateDirectory = NSTemporaryDirectory() + "/mc-state-\(UUID().uuidString)"
    return Session(options: opts, live: LiveView(options: opts),
                   meetingApp: app, title: "Test Meeting", clock: clock)
}

/// A Meet-like app whose captions state and press behaviour a test scripts.
final class ScriptedApp: MeetingApp {
    let id = "scripted"
    let displayName = "Scripted"
    let processPattern = "scripted"
    var captionPressToggles = false
    var captionsSurfaceIsTransient = false
    var writesCaptionsBySentence = true
    let finalizesWhenSuperseded = true
    let idleFinalizeSeconds: TimeInterval? = 6
    let reportsMeetingClock = false
    let rendersWebContent = false
    /// Captions state as the app would show it.
    var captionsOn = false
    /// Whether a press actually turns captions on (Meet at join on
    /// 2026-10-22: accepted, and ignored).
    var pressTakes = true
    private(set) var presses: [Date] = []
    var now = Date()
    func meetingAnchor(_ app: AXUIElement) -> AXUIElement? { nil }
    func meetingTitle(_ app: AXUIElement, anchor: AXUIElement?) -> String { "" }
    func captionsContainer(_ app: AXUIElement) -> AXUIElement? { nil }
    func captionEntries(in container: AXUIElement) -> [CaptionEntry] { [] }
    func captionsPanelOpen(_ app: AXUIElement) -> Bool { captionsOn }
    func requestCaptions(pid: pid_t) -> CaptionRequest {
        if captionsOn { return .alreadyOn }
        presses.append(now)
        if pressTakes { captionsOn = true }
        return .pressed
    }
    func hasStableIdentity(_ id: String) -> Bool { true }
    func treeReadiness(_ app: AXUIElement) -> TreeReadiness { .webContent }
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

// Caption history lands before the live captions held back while it was
// read, tagged as history, with the line both sources caught written once.
do {
    let clock = FakeClock(start: epoch, step: 0)
    let s = injectedSession(clock: clock)
    let jsonl = MemorySink(path: "/tmp/history.jsonl")
    let text = MemorySink(path: "/tmp/history.txt")
    s.recorder = Recorder(options: Options(), startedAt: epoch, mode: .elapsed(from: epoch),
                          jsonlURL: URL(fileURLWithPath: jsonl.path),
                          textURL: URL(fileURLWithPath: text.path),
                          jsonl: jsonl, text: text)
    s.heldCaptions = [("T", "I think it's this clustering, yeah, so.", epoch.addingTimeInterval(5), [:]),
                      ("E", "Live after joining.", epoch.addingTimeInterval(9), [:])]
    s.concludeHistory([SegmentKey(speaker: "T", text: "Howdy howdy."),
                       SegmentKey(speaker: "T", text: "I think it's this clustering, yeah, so.")])
    let lines = jsonl.string.split(separator: "\n").filter { $0.contains("\"caption\"") }
    expectEqual(lines.count, 3, "history + held, overlap written once")
    expectTrue(lines.first?.contains("Howdy howdy.") == true && lines.first?.contains("\"history\":true") == true,
               "history comes first and is tagged")
    expectTrue(lines.last?.contains("Live after joining.") == true, "held captions follow history")
    expectTrue(s.heldCaptions.isEmpty, "held captions released")
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

// --- Zoom: sharing your screen is not leaving the meeting -----------------
//
// Regression: sharing swaps Zoom's toolbar, Leave button included, for floating
// share chrome, so the daemon logged `left "…", ending session` ten seconds
// into every share and recorded nothing more. Window titles from Zoom 7.1.9,
// read live mid-share.

do {
    let sharing = [
        "zoom share statusbar window",
        "zoom share toolbar window",
        "zoom annotation entrypoint",
        "Annotation - Zoom",
        "",
        "Zoom Meeting",
    ]
    expectEqual(zoomShareChromeIndex(titles: sharing), 0, "share chrome counts as a meeting")
    expectEqual(zoomShareChromeIndex(titles: ["Zoom Meeting", "zoom share toolbar window"]), 1,
                "share toolbar alone counts")
    expectEqual(zoomShareChromeIndex(titles: ["Zoom Meeting", ""]), nil,
                "a meeting window without share chrome needs its Leave button")
    expectEqual(zoomShareChromeIndex(titles: ["Zoom Workplace", "Settings"]), nil,
                "idle Zoom is no meeting")
    expectEqual(zoomShareChromeIndex(titles: ["Zoom Share Toolbar Window"]), nil,
                "titles match exactly")

    // While sharing, captions float in a window of their own. Recognizing it
    // keeps auto-captions from pressing More on the screen being shared.
    expectTrue(zoomFloatingCaptionsWindow(
                   description: "Closed caption subtitles, 1129 pixels from bottom edge, 2622 pixels from right edge"),
               "floating captions window means captions are on")
    expectTrue(!zoomFloatingCaptionsWindow(description: "Closed caption subtitles"),
               "the docked caption table is not the floating window")
    expectTrue(!zoomFloatingCaptionsWindow(description: ""), "an undescribed window is not captions")

    // Auto-captions keeps its hands off Zoom while you share: the only way to
    // captions then is the share toolbar's More, a menu that would open on the
    // screen being shared.
    expectTrue(!zoomMayRequestCaptions(windowTitles: sharing),
               "no reaching for captions while you share")
    expectTrue(!zoomMayRequestCaptions(windowTitles: ["zoom share statusbar window", "Zoom Meeting"]),
               "the Stop share pill alone still means you are sharing")
    expectTrue(zoomMayRequestCaptions(windowTitles: ["Zoom Meeting"]),
               "captions may be requested once the share ends")
    expectTrue(zoomMayRequestCaptions(windowTitles: []),
               "a hollow window list does not block the request")
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

    // Huddle window: found by its Leave button, so every secondary window is
    // a candidate — a DM huddle reported no "Huddle" in its AX title at all.
    let ws = "VA OIT VA.gov Teams | Platforms | AI | Products"
    expectEqual(slackHuddleCandidates(titles: [
                    "Travis Taylor (DM) - \(ws) - Slack [Main] \u{1F3E0}\u{1F50A}",
                    "- \(ws) - Slack",
                    "Travis Taylor - \(ws) - Slack",
                ]), [1, 2], "DM huddle window is a candidate; main window skipped")
    expectEqual(slackHuddleCandidates(titles: [
                    "general - \(ws) - Slack [Main]",
                    "- \(ws) - Slack",
                    "Huddle: #eert - \(ws) - Slack \u{1F3A4}",
                ]), [2, 1], "Huddle-titled windows are searched first")
    expectEqual(slackHuddleCandidates(titles: ["x - Slack [Main]"]), [],
                "main window alone means no search")

    expectEqual(slackHuddleTitle("Huddle: #eert - \(ws) - Slack \u{1F3A4}"), "#eert",
                "channel huddle title")
    expectEqual(slackHuddleTitle("Huddle with Travis Taylor"), "Travis Taylor",
                "DM huddle title as drawn")
    expectEqual(slackHuddleTitle("Travis Taylor - \(ws) - Slack"), "Travis Taylor",
                "DM huddle title as AX reports it")
    expectEqual(slackHuddleTitle("- \(ws) - Slack"), "Slack huddle",
                "empty name falls back")

    // Caption history: panel rows, page stitching, overlap with live capture.
    let k = { (s: String, t: String) in SegmentKey(speaker: s, text: t) }
    expectEqual(slackPanelRow(["Travis Taylor", "Howdy howdy."]), k("Travis Taylor", "Howdy howdy."),
                "panel row is speaker then text")
    expectEqual(slackPanelRow(["Captions are being generated in English (US).", "Change huddle language"]), nil,
                "panel header is not a row")
    expectEqual(slackPanelRow(["Travis Taylor"]), nil, "speaker alone is not a row")

    let a = k("T", "one"), b = k("E", "two"), c = k("T", "three"), d = k("E", "four"), e = k("T", "five")
    expectEqual(mergeCaptionPages([[a, b, c], [b, c, d], [c, d, e]]), [a, b, c, d, e],
                "overlapping pages stitch in order")
    expectEqual(mergeCaptionPages([[a, b, c, d], [b, c], [d, e]]), [a, b, c, d, e],
                "a page inside what is held adds nothing")
    expectEqual(mergeCaptionPages([[a, b], [d, e]]), [a, b, d, e],
                "a page that jumped past the overlap is still kept")
    expectEqual(mergeCaptionPages([[a, k("E", "Yeah.")], [k("E", "Yeah."), c, k("E", "Yeah.")]]),
                [a, k("E", "Yeah."), c, k("E", "Yeah.")],
                "a repeated short line survives stitching")

    let said = k("T", "I think it's this clustering, yeah, so.")
    expectEqual(trimCaptionHistory([a, b, said], against: [said]), [a, b],
                "history line already held live is dropped")
    expectEqual(trimCaptionHistory([a, k("T", "Older words. I think it's this clustering, yeah, so.")],
                                   against: [said]),
                [a, k("T", "Older words.")],
                "merged panel row keeps the words before the live ones")
    expectEqual(trimCaptionHistory([a, k("E", "Yeah, sure thing"), b], against: [k("E", "Yeah.")]),
                [a, k("E", "Yeah, sure thing"), b],
                "a short live phrase does not match inside an older row")
    expectEqual(trimCaptionHistory([a, b], against: [k("T", "two")]), [a, b],
                "same words from another speaker are not a match")
    expectEqual(trimCaptionHistory([a, b], against: []), [a, b], "nothing live keeps everything")

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

// Long rosters expose two StaticTexts that both read like "more", and only
// one of them is a control. "See more" opens the full attendee list; "+203
// more" is a placeholder for rows the server has not sent, and nothing makes
// it act. Participant row context buttons say "More options" and must never be
// mistaken for either.
do {
    expectTrue(isRosterExpander("See more"), "the control that opens the full list is recognised")
    expectTrue(!isRosterExpander("+203 more"), "the placeholder is not a control")
    expectTrue(!isRosterExpander("More options"), "participant context menus are not the expander")
    expectEqual(rosterBacklog("+203 more"), 203, "the unfetched count parses")
    expectEqual(rosterBacklog("+9 more"), 9, "a one-digit unfetched count parses")
    expectEqual(rosterBacklog("See more"), nil, "the expander carries no count")
    expectEqual(rosterBacklog("+ people"), nil, "a malformed placeholder is rejected")
    expectEqual(rosterBacklog("More options"), nil, "a context menu carries no count")

    // Newer Teams builds moved the total out of roster-title-section and into
    // a heading, so the count has to be read from either shape.
    expectEqual(rosterCount(from: ["In this meeting (284)"]), 284,
                "the heading Teams uses now yields the total")
    expectEqual(rosterCount(from: ["Attendees", "(12)"]), 12,
                "the older section title still yields the total")
    expectEqual(rosterCount(from: ["Participants"]), nil,
                "a heading with no number yields nothing")
}

// A read that runs for a minute has to give the pointer back the moment the
// human wants it. The idle clocks cannot tell — our own scrolling resets them
// — so the test is whether the pointer is still parked where we put it.
do {
    let parked = CGPoint(x: 500, y: 400)
    expectTrue(!pointerTakenBack(now: parked, parked: parked),
               "an unmoved pointer is not a takeback")
    expectTrue(!pointerTakenBack(now: CGPoint(x: 503, y: 396), parked: parked),
               "a few points of settling is not a takeback")
    expectTrue(pointerTakenBack(now: CGPoint(x: 500, y: 409), parked: parked),
               "a real move is a takeback")
    expectTrue(pointerTakenBack(now: CGPoint(x: 520, y: 400), parked: parked),
               "and so is a sideways one")
}

// A roster is only "confirmed" when the names we loaded match the count Teams
// printed above them. Everything else has to say how short it fell.
do {
    let people = [RosterPerson(name: "Ashley", key: "a"),
                  RosterPerson(name: "Eric", key: "b")]
    expectTrue(RosterSnapshot(people: people, expected: 2).confirmed,
               "a roster matching the head count is confirmed")
    expectTrue(!RosterSnapshot(people: people, expected: 311).confirmed,
               "a roster short of the head count is not confirmed")
    expectTrue(!RosterSnapshot(people: people, expected: nil).confirmed,
               "a roster with no head count to check against is never confirmed")
    expectEqual(RosterSnapshot(people: people, expected: 2).headline,
                "2 in the meeting (confirmed)", "a confirmed roster says so")
    expectEqual(RosterSnapshot(people: people, expected: 311).headline,
                "2 in the meeting (roster says 311; 2 loaded)",
                "a short roster reports both numbers rather than implying it is whole")
    expectEqual(RosterSnapshot(people: people, expected: nil).headline,
                "2 in the meeting", "with no head count, only what was read is claimed")
    expectEqual(RosterSnapshot.summary(names: ["Ashley", "Eric"], expected: 2),
                "2 in the meeting (confirmed): Ashley, Eric",
                "the transcript line carries the names after the count")
    expectEqual(RosterSnapshot.summary(names: [], expected: 0),
                "0 in the meeting (confirmed)",
                "an empty roster line does not end in a dangling colon")
}

// Google Meet's roster: the count button, which must never be confused with
// the "Also invited" button sitting directly below the same list.
do {
    expectEqual(meetContributorCount(from: "Contributors 59").map(String.init), "59",
                "the contributors button is the head count")
    expectEqual(meetContributorCount(from: "Contributors 1").map(String.init), "1",
                "a call of one still parses")
    expectTrue(meetContributorCount(from: "Also invited 104") == nil,
               "people who were invited and did not come are not contributors")
    expectTrue(meetContributorCount(from: "Contributors") == nil,
               "a button with no number is not a count")
    expectTrue(meetContributorCount(from: "Contributors many") == nil,
               "a word where the number goes is not a count")
    expectTrue(meetContributorCount(from: "") == nil,
               "an empty title is not a count")
}

// The politeness gate, which decides whether a roster snapshot may take the
// pointer. Measured in a live meeting: keyboard idle 19-25s while mouseMoved
// never once exceeded ~2s, because a hand was resting on the trackpad. The
// first version waited for total input silence and so never fired at all.
do {
    expectTrue(!Session.interruptsUser(typingIdle: 20, pointerIdle: 2),
               "a quiet keyboard and a settled pointer is a lull")
    expectTrue(Session.interruptsUser(typingIdle: 0.5, pointerIdle: 30),
               "typing is never interrupted, however still the mouse is")
    expectTrue(Session.interruptsUser(typingIdle: 30, pointerIdle: 0.2),
               "a click or drag in progress is not interrupted either")
    expectTrue(!Session.interruptsUser(typingIdle: 3, pointerIdle: 1.5),
               "the thresholds themselves count as quiet")
    // The live regression: this exact reading was seen every two seconds for
    // minutes, and must be a lull or no meeting with a resting hand on the
    // trackpad would ever get a roster.
    expectTrue(!Session.interruptsUser(typingIdle: 25.48, pointerIdle: 3.9),
               "a resting hand does not count as the user being busy")
}

// --- on-demand roster requests ------------------------------------------
// The request file is the whole protocol: roster-now drops it, the session
// consumes it next poll. Each file fires exactly once.
do {
    let dir = NSTemporaryDirectory() + "/mc-roster-req-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    expectTrue(!consumeRosterRequest(at: dir), "no file means no request")
    let idle = requestRoster(stateDirectory: dir)
    expectTrue(idle != nil && idle!.contains("no meeting"),
               "an idle request queues for the next meeting")
    expectTrue(FileManager.default.fileExists(atPath: dir + "/roster-now"),
               "the request lands as a bare file in the state directory")
    expectTrue(consumeRosterRequest(at: dir), "the session consumes the pending request")
    expectTrue(!consumeRosterRequest(at: dir), "each request file fires exactly once")
    // A live meeting advertises itself with the `current` pointer.
    FileManager.default.createFile(atPath: dir + "/current", contents: nil)
    let live = requestRoster(stateDirectory: dir)
    expectTrue(live != nil && live!.contains("quiet moment"),
               "a live request promises the next lull, never an interruption")
    _ = consumeRosterRequest(at: dir)
    try? FileManager.default.removeItem(atPath: dir)
}

// --- immediate people-snapshot recording --------------------------------
// renderEvent is the single renderer behind Recorder.record and the
// standalone path: byte-identical by construction, locked by comparison.
do {
    let jsonl = MemorySink(path: "/tmp/j.jsonl"), text = MemorySink(path: "/tmp/t.txt")
    let mode = TimestampMode.elapsed(from: epoch)
    let r = Recorder(options: Options(), startedAt: epoch, mode: mode,
                     jsonlURL: URL(fileURLWithPath: jsonl.path),
                     textURL: URL(fileURLWithPath: text.path),
                     jsonl: jsonl, text: text)
    let extra: [String: Any] = ["people": ["B", "A"], "count": 2, "confirmed": false]
    let outcome = r.record(kind: "people", speaker: "", body: "2 in the meeting: B, A",
                           at: epoch, extra: extra)
    guard let rendered = renderEvent(kind: "people", speaker: "", body: "2 in the meeting: B, A",
                                     at: epoch, mode: mode, extra: extra) else {
        expectTrue(false, "renderEvent renders a people event")
        exit(failures == 0 ? 0 : 1)
    }
    expectEqual(outcome, WriteOutcome.written(rendered.line),
                "record and renderEvent agree on the transcript line")
    expectTrue(jsonl.string.hasSuffix(rendered.json),
               "record and renderEvent agree on the jsonl bytes")
    expectTrue(rendered.json.contains("\"elapsed\":\"00:00:00\""),
               "elapsed mode stamps from the reference date")
    expectEqual(rendered.line, "[\(clockStamp(epoch))] (people) 2 in the meeting: B, A",
                "the standalone line needs no recorder to match")
}

// A handle opened before another writer grew the file must still land at
// EOF. Against the old seek-once FileSink this reads back "a\nc\n" — the
// standalone roster silently eaten by the daemon's next caption.
do {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mc-oappend-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: url.path, contents: Data("a\n".utf8))
    guard let sink = FileSink(url: url) else {
        expectTrue(false, "FileSink opens a real writable file")
        exit(failures == 0 ? 0 : 1)
    }
    try? appendAtomically(Data("b\n".utf8), toFileAtPath: url.path)
    try? sink.append(Data("c\n".utf8))
    expectEqual(try? String(contentsOf: url, encoding: .utf8), "a\nb\nc\n",
                "a retained handle appends at true EOF, never clobbers")
    var threw = false
    do { try appendAtomically(Data("x".utf8), toFileAtPath: url.path + ".missing") } catch { threw = true }
    expectTrue(threw, "atomic append throws on an unopenable path")
    try? FileManager.default.removeItem(at: url)
}

// The full standalone path against a fabricated live session: resolve the
// `current` pointer, recover the mode, stamp like the daemon, mark done.
do {
    let dir = NSTemporaryDirectory() + "/mc-live-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let idle = RosterSnapshot(people: [], expected: nil)
    expectEqual(recordRosterToTranscript(idle, at: epoch, stateDirectory: dir),
                RosterRecordOutcome.noLiveTranscript, "nothing recording means print-only")
    expectTrue(!FileManager.default.fileExists(atPath: dir + "/roster-done"),
               "no transcript, no marker")
    let txt = dir + "/m.txt", jsonl = dir + "/m.jsonl"
    let meta = "{\"type\":\"metadata\",\"timestamps\":\"elapsed\",\"recorded_at\":\"\(Recorder.isoFormatter.string(from: epoch))\"}\n"
    FileManager.default.createFile(atPath: txt, contents: nil)
    FileManager.default.createFile(atPath: jsonl, contents: Data(meta.utf8))
    try? txt.write(toFile: dir + "/current", atomically: true, encoding: .utf8)
    let snap = RosterSnapshot(people: [RosterPerson(name: "A", key: "1"),
                                       RosterPerson(name: "B", key: "2")], expected: 3)
    expectEqual(recordRosterToTranscript(snap, at: epoch, stateDirectory: dir),
                .recorded("[\(clockStamp(epoch))] (people) 2 in the meeting (roster says 3; 2 loaded): A, B"),
                "the roster lands as a daemon-shaped people line")
    let lines = (try? String(contentsOfFile: jsonl, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    let event = lines.last.flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    expectEqual(event?["type"] as? String, "people", "the jsonl event is typed")
    expectEqual(event?["people"] as? [String], ["A", "B"], "names ride along for machines")
    expectEqual(event?["count"] as? Int, 2, "count is the loaded head")
    expectEqual(event?["confirmed"] as? Bool, false, "a short roster is never presented as complete")
    expectEqual(event?["roster_count"] as? Int, 3, "the panel's own head count is kept")
    expectEqual(event?["elapsed"] as? String, "00:00:00", "stamped from the transcript's own start")
    expectTrue(FileManager.default.fileExists(atPath: dir + "/roster-done"),
               "recording marks the join-time capture done")
    expectTrue(consumeRosterDone(at: dir), "the daemon consumes the marker")
    expectTrue(!consumeRosterDone(at: dir), "each marker fires exactly once")
    // A transcript whose mode is unreadable is print-only, never guessed at.
    try? "not json\n".write(toFile: jsonl, atomically: true, encoding: .utf8)
    let bad = recordRosterToTranscript(snap, at: epoch, stateDirectory: dir)
    if case .unreadableTranscript = bad {
        expectTrue(true, "garbage metadata falls back to print-only")
    } else {
        expectTrue(false, "garbage metadata falls back to print-only")
    }
    try? FileManager.default.removeItem(atPath: dir)
}

// --- Where synthetic input lands ---------------------------------------

do {
    let teams: pid_t = 100, other: pid_t = 200
    let meeting = CGRect(x: 100, y: 100, width: 800, height: 600)
    let button = CGPoint(x: 400, y: 650)
    func window(_ pid: pid_t, _ owner: String, _ layer: Int, _ bounds: CGRect,
                alpha: Double = 1) -> ScreenWindow {
        ScreenWindow(pid: pid, owner: owner, layer: layer, alpha: alpha, bounds: bounds)
    }
    // Measured on a locked Mac: these are listed above every app window.
    let shields = [
        window(1, "Window Server", 2147483646, CGRect(x: 0, y: 0, width: 1440, height: 2560)),
        window(2, "loginwindow", 2004, CGRect(x: 0, y: 0, width: 1440, height: 2560)),
        window(2, "loginwindow", 2001, CGRect(x: -15000, y: -15000, width: 30000, height: 30000)),
    ]
    let meetingWindow = window(teams, "Microsoft Teams", 0, meeting)
    func refusal(_ windows: [ScreenWindow], at point: CGPoint = button,
                 frame: CGRect = meeting) -> InputRefusal? {
        inputRefusal(at: point, pid: teams, windowFrame: frame, windows: windows)
    }

    expectEqual(systemWindowLevel, 1000, "system windows start at the screen saver's level")
    expectEqual(windowUnder(button, in: shields + [meetingWindow]), meetingWindow,
                "system shields listed above the apps are not what a click lands on")
    expectEqual(refusal(shields + [meetingWindow]), nil, "the meeting window on top at the point: click")
    expectEqual(windowUnder(button, in: [meetingWindow, window(other, "Slack", 0, meeting)]), meetingWindow,
                "the frontmost window containing the point is the one that counts")

    let slack = window(other, "Slack", 0, CGRect(x: 300, y: 500, width: 400, height: 400))
    expectEqual(refusal([slack, meetingWindow]), .covered("Slack"),
                "another app on top at the point refuses the click, by name")
    let aside = window(other, "Slack", 0, CGRect(x: 1000, y: 100, width: 400, height: 400))
    expectEqual(refusal([aside, meetingWindow]), nil, "a window elsewhere on screen is no obstacle")
    let chat = window(teams, "Microsoft Teams", 0, CGRect(x: 350, y: 600, width: 300, height: 300))
    expectEqual(refusal([chat, meetingWindow]), .covered("another Microsoft Teams window"),
                "the app's own other window on top is still the wrong window")
    let floating = window(other, "Zoom", 3, CGRect(x: 380, y: 630, width: 50, height: 50))
    expectEqual(refusal([floating, meetingWindow]), .covered("Zoom"), "a floating window over the point refuses")
    let pinned = window(teams, "Microsoft Teams", 3, meeting)
    expectEqual(refusal([pinned]), nil, "a pinned (floating) target window is still the target")
    expectEqual(refusal([window(other, "Overlay", 0, meeting, alpha: 0), meetingWindow]), nil,
                "a fully transparent window is not counted")
    expectEqual(refusal([window(other, "Desktop", -20, meeting), meetingWindow]), nil,
                "a negative-layer window is not counted")

    expectEqual(refusal([meetingWindow], at: CGPoint(x: 50, y: 50)), .outsideWindow,
                "a target outside its own window is refused, not clicked through to whatever is there")
    expectEqual(refusal(shields), .offscreen, "a window not on screen here (another Space) is refused")
    expectEqual(refusal([meetingWindow], frame: .zero), .offscreen, "a window with no frame is refused")
    expectEqual(refusal([window(teams, "Microsoft Teams", 0, meeting.offsetBy(dx: 2, dy: -2))]), nil,
                "AX and the window server may disagree by two points")
    expectEqual(refusal([window(teams, "Microsoft Teams", 0, meeting.offsetBy(dx: 3, dy: 0))]),
                .covered("another Microsoft Teams window"), "three points apart is a different window")

    expectEqual("\(InputRefusal.notFrontmost("Ghostty"))", "macOS kept Ghostty in front",
                "a refusal reads as a reason in the log")
    expectEqual("\(InputRefusal.covered("Slack"))", "Slack is on top of it", "covered names the coverer")
}

// --- RepeatFilter -------------------------------------------------------

do {
    var filter = RepeatFilter()
    let t0 = Date(timeIntervalSince1970: 1_000)
    expectTrue(filter.admit("a", at: t0, every: 60), "a first message is admitted")
    expectTrue(!filter.admit("a", at: t0.addingTimeInterval(59), every: 60), "its repeat within the interval is held")
    expectTrue(filter.admit("b", at: t0.addingTimeInterval(1), every: 60), "a different message is its own")
    expectTrue(filter.admit("a", at: t0.addingTimeInterval(60), every: 60), "the same message after the interval")
    expectTrue(filter.admit("once", at: t0, every: .infinity), "an infinite interval admits once")
    expectTrue(!filter.admit("once", at: t0.addingTimeInterval(1e9), every: .infinity), "and never again")
}

// --- Writing a growing caption segment sentence by sentence --------------
//
// Regression (Meet, 2026-10-22): a speaker's whole uninterrupted run is ONE
// growing text element, so a lunch-and-learn talk landed as a single
// 14,400-character line, stamped with when it began, after sitting unwritten
// for the whole stretch.

do {
    typealias CS = CaptionSentences
    func sentences(_ text: String) -> (complete: [String], rest: String) {
        let (complete, rest) = CS.split(text, from: text.startIndex)
        return (complete.map { String(text[$0]).trimmingCharacters(in: .whitespaces) }, String(text[rest]))
    }
    expectEqual(sentences("Hello there. How are you? I'm fine").complete, ["Hello there.", "How are you?"],
                "sentences end at a terminator followed by a space")
    expectEqual(sentences("Hello there. How are you? I'm fine").rest, "I'm fine", "the unfinished sentence is the rest")
    expectEqual(sentences("One. Two.").complete, ["One."],
                "a terminator at the very end does not count yet: recognition may still revise it")
    expectEqual(sentences("I saw Dr. Smith today. Then").complete, ["I saw Dr. Smith today."],
                "an abbreviation does not end a sentence")
    expectEqual(sentences("It costs $2.50 a month. Okay").complete, ["It costs $2.50 a month."],
                "a decimal point does not end a sentence")
    expectEqual(sentences("He said \"stop.\" Then we left. And").complete, ["He said \"stop.\"", "Then we left."],
                "closing quotes stay with their sentence")
    expectEqual(sentences("Wait... what?! Yes. No").complete, ["Wait...", "what?!", "Yes."],
                "runs of terminators end one sentence")

    // While a segment grows, its newest complete sentence is held back:
    // recognition still revises the last words and punctuation.
    let growing = CS.plan(text: "A one. B two. C thr", written: nil, final: false)
    expectEqual(growing.lines.map(\.text), ["A one."], "the newest complete sentence waits")
    expectEqual(growing.through, "A one.", "written through the end of the last line")
    expectEqual(growing.lines.first?.start, 0, "lines know where they start")
    let resumed = CS.plan(text: "A one. B two. C three. D", written: "A one.", final: false)
    expectEqual(resumed.lines.map(\.text), ["B two."], "resumes after what was written")
    expectEqual(resumed.lines.first?.start, 7, "and counts from the segment start")
    let done = CS.plan(text: "A one. B two. C thr", written: "A one.", final: true)
    expectEqual(done.lines.map(\.text), ["B two.", "C thr"], "once done, everything left is written")
    expectTrue(CS.plan(text: "A one. B tw", written: nil, final: false).through == nil,
               "nothing to write means no change")

    // Where to pick up when the segment is no longer a simple extension.
    let text = "so you can submit receipts for care before January. The runout period"
    expectEqual(CS.resumeIndex(in: text, after: "so you can submit").map { text.distance(from: text.startIndex, to: $0) }, 17,
                "a prefix resumes right after it")
    let trimmed = "receipts for care before January. The runout period is ninety days"
    let afterTrim = CS.resumeIndex(in: trimmed, after: "so you can submit receipts for care before January.")
    expectEqual(afterTrim.map { String(trimmed[$0...]) }, " The runout period is ninety days",
                "a front-trimmed segment resumes after the last words written")
    let revised = "so you can submit receipts for care during January, and then"
    let afterRevision = CS.resumeIndex(in: revised, after: "so you can submit receipts for care before January.")
    expectEqual(afterRevision.map { String(revised[$0...]) }, "during January, and then",
                "a revision near the end resumes at the start of the revised word")
    expectTrue(CS.resumeIndex(in: "something else entirely", after: "so you can submit receipts") == nil,
               "replaced text owes all of it")
    expectTrue(CS.resumeIndex(in: "I think that's wrong.", after: "I think so.") == nil,
               "a reused row with a short shared start is new text, not a revision (Zoom rows go by element hash)")

    // Each stretch of text remembers when it appeared.
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    var u = Utterance(speaker: "K", text: "Hello", startedAt: t, changedAt: t, marks: [TextMark(offset: 0, at: t)])
    u.revise(to: "Hello there", at: t.addingTimeInterval(2))
    expectEqual(u.firstSeen(atOffset: 6), t.addingTimeInterval(2), "new words are timed when they appeared")
    expectEqual(u.firstSeen(atOffset: 2), t, "old words keep their time")
    u.revise(to: "Help there", at: t.addingTimeInterval(3))
    expectEqual(u.marks, [TextMark(offset: 0, at: t), TextMark(offset: 3, at: t.addingTimeInterval(3))],
                "a revision re-times only from where it differs")
}

/// Deterministic pseudo-random numbers, so a synthetic talk is the same every run.
struct LCG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// A made-up talk, grown a few words per poll the way live captions arrive,
/// with recognition-style revisions at the tail.
final class TalkGrower {
    static let vocabulary = ["the", "plan", "year", "covers", "eligible", "expenses", "you", "can", "submit",
                             "receipts", "for", "care", "before", "January", "runout", "period", "of", "ninety",
                             "days", "and", "funds", "roll", "over", "up", "to", "a", "limit", "so", "keep",
                             "track", "your", "account", "balance", "every", "month", "because", "reimbursement",
                             "takes", "about", "two", "weeks", "which", "means", "budget", "ahead", "when",
                             "school", "starts", "again"]
    let tokens: [String]
    /// Token index where each sentence begins.
    let sentenceStarts: [Int]
    /// Token index of the last word of each sentence but the final one, ascending.
    let boundaries: [Int]
    private(set) var shown = 0
    /// Token index -> when it first appeared.
    private(set) var firstSeen: [Int: Date] = [:]
    private var rng: LCG

    init(seed: UInt64, length minimum: Int) {
        var rng = LCG(state: seed)
        var tokens: [String] = [], starts: [Int] = []
        while tokens.joined(separator: " ").count < minimum {
            starts.append(tokens.count)
            var words = (0..<(4 + rng.next(27))).map { _ in TalkGrower.vocabulary[rng.next(TalkGrower.vocabulary.count)] }
            if rng.next(10) == 0 { words.insert(contentsOf: ["Dr.", "Lee", "said"], at: min(2, words.count)) }
            if rng.next(10) == 0 { words.insert(contentsOf: ["about", "$2.50"], at: words.count / 2) }
            words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
            words[words.count - 1] += [".", ".", ".", ".", ".", ".", "?", "?", "!"][rng.next(9)]
            tokens += words
        }
        self.tokens = tokens
        sentenceStarts = starts
        boundaries = starts.dropFirst().map { $0 - 1 }
        self.rng = rng
    }

    var text: String { tokens.joined(separator: " ") }
    var sentenceCount: Int { sentenceStarts.count }
    var done: Bool { shown >= tokens.count }
    /// What has been shown so far, read correctly.
    var settled: String { tokens[0..<shown].joined(separator: " ") }

    /// Show a few more words (never past `limit`), as recognition shows them
    /// at first: a sentence break appears as a comma, and the newest word is
    /// sometimes misheard for a poll.
    func step(at now: Date, limit: Int? = nil) -> String {
        let previous = shown
        shown = min(limit ?? tokens.count, shown + 2 + rng.next(4))
        if shown > previous { for index in previous..<shown { firstSeen[index] = now } }
        var display = Array(tokens[0..<shown])
        if let boundary = boundaries.first(where: { $0 >= previous - 1 && $0 < shown - 1 }) {
            display[boundary] = String(display[boundary].dropLast()) + ","
            display[boundary + 1] = display[boundary + 1].lowercased()
        } else if shown > 0, rng.next(4) == 0, !boundaries.contains(shown - 1) {
            display[shown - 1] = "uh"
        }
        return display.joined(separator: " ")
    }

    /// Token count through the end of the first sentence ending at or after `token`.
    func throughSentence(at token: Int) -> Int {
        (boundaries.first { $0 >= token } ?? tokens.count - 1) + 1
    }
}

/// A session recording into memory, with live captions flowing straight through.
func captionSession(_ app: MeetingApp, at t0: Date) -> (Session, MemorySink) {
    let s = injectedSession(clock: FakeClock(start: t0, step: 0.25), app: app)
    try? FileManager.default.createDirectory(atPath: s.options.stateDirectory, withIntermediateDirectories: true)
    let jsonl = MemorySink(path: "/tmp/sentences.jsonl")
    s.recorder = Recorder(options: Options(), startedAt: t0, mode: .timeOfDay,
                          jsonlURL: URL(fileURLWithPath: jsonl.path), textURL: URL(fileURLWithPath: "/tmp/sentences.txt"),
                          jsonl: jsonl, text: MemorySink(path: "/tmp/sentences.txt"))
    s.concludeHistory([]) // nothing to recover
    return (s, jsonl)
}

func captionLines(_ jsonl: MemorySink) -> [[String: Any]] {
    jsonl.string.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }.filter { $0["type"] as? String == "caption" }
}

/// How many lines are stamped more than a second away from when their
/// sentence's first word appeared. A line's real start is `started_at` when
/// the transcript held `ts` back so the clock never runs backwards (two
/// people talking at once).
func offStamps(_ lines: [[String: Any]], _ talk: TalkGrower) -> Int {
    let iso = ISO8601DateFormatter()
    return zip(lines, talk.sentenceStarts).filter { line, start in
        guard let ts = ((line["started_at"] ?? line["ts"]) as? String).flatMap(iso.date(from:)),
              let spoken = talk.firstSeen[start] else { return true }
        return abs(ts.timeIntervalSince(spoken)) > 1.0
    }.count + abs(lines.count - talk.sentenceCount)
}

// The real thing: a 14K-character monologue in one segment, grown a few words
// per poll with recognition-style revisions, then another speaker.
do {
    let monologue = TalkGrower(seed: 42, length: 14_400).text
    let sentenceCount = TalkGrower(seed: 42, length: 14_400).sentenceCount
    let sentenceStarts = TalkGrower(seed: 42, length: 14_400).sentenceStarts

    func run(trimAt trimToken: Int?) -> (lines: [[String: Any]], beforeB: Int, longestLive: Int, firstSeen: [Int: Date]) {
        let talk = TalkGrower(seed: 42, length: 14_400)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (s, jsonl) = captionSession(ScriptedApp(), at: t0)
        var now = t0, longestLive = 0, trimmedChars = 0
        while !talk.done {
            let display = talk.step(at: now)
            if let trimToken, talk.shown > trimToken + 400 {
                // Meet trims old words off the front, mid-sentence.
                trimmedChars = talk.tokens[0..<trimToken].joined(separator: " ").count + 1
            }
            s.ingestCaptions([CaptionEntry(id: "seg:0", speaker: "Kelsey", text: String(display.dropFirst(trimmedChars)))], now: now)
            let live = (try? String(contentsOfFile: s.options.stateDirectory + "/live", encoding: .utf8)) ?? ""
            longestLive = max(longestLive, live.count)
            now = now.addingTimeInterval(0.25)
        }
        // The finished segment, read correctly, then a pause.
        let finalText = String(monologue.dropFirst(trimmedChars))
        for _ in 0..<4 {
            s.ingestCaptions([CaptionEntry(id: "seg:0", speaker: "Kelsey", text: finalText)], now: now)
            now = now.addingTimeInterval(0.25)
        }
        let beforeB = jsonl.string.split(separator: "\n").filter { $0.contains("\"Kelsey\"") }.count
        // Someone else speaks, which settles Kelsey's segment.
        s.ingestCaptions([CaptionEntry(id: "seg:0", speaker: "Kelsey", text: finalText),
                          CaptionEntry(id: "seg:1", speaker: "Justin", text: "Thanks, that helps.")], now: now)
        s.finish(at: now.addingTimeInterval(1))
        return (captionLines(jsonl), beforeB, longestLive, talk.firstSeen)
    }

    let plain = run(trimAt: nil)
    let kelsey = plain.lines.filter { $0["speaker"] as? String == "Kelsey" }
    let texts = kelsey.compactMap { $0["text"] as? String }
    expectTrue(monologue.count >= 14_400, "the synthetic monologue is at least 14K characters (\(monologue.count))")
    expectEqual(texts.joined(separator: " "), monologue, "every word written once, in order: nothing lost, nothing repeated")
    expectEqual(texts.count, sentenceCount, "one line per sentence (\(sentenceCount)), abbreviations and decimals kept whole")
    expectTrue((texts.map(\.count).max() ?? 0) < 400, "no giant line (longest \(texts.map(\.count).max() ?? 0) characters)")
    expectTrue(plain.beforeB >= sentenceCount - 2,
               "sentences are written while the speaker is still talking (\(plain.beforeB) of \(sentenceCount) before anyone else spoke; only the newest two wait)")
    expectTrue(kelsey.allSatisfy { $0["continues"] == nil }, "sentence lines are not continuation tails the merge tool would glue back")
    expectTrue(kelsey.allSatisfy { $0["node_id"] as? String == "seg:0" }, "each carries its segment's node_id")
    expectTrue(plain.lines.last?["speaker"] as? String == "Justin", "the next speaker follows")
    expectTrue(plain.longestLive < 1_000, "the live line holds only what is not written yet (longest \(plain.longestLive) characters)")

    // Each line is stamped with when its first words appeared (to the second
    // the transcript keeps), not with when the segment began.
    let iso = ISO8601DateFormatter()
    var offStamps = 0, endedBeforeStart = 0
    for (index, line) in kelsey.enumerated() where index < sentenceStarts.count {
        guard let ts = (line["ts"] as? String).flatMap(iso.date(from:)),
              let spoken = plain.firstSeen[sentenceStarts[index]] else { offStamps += 1; continue }
        if abs(ts.timeIntervalSince(spoken)) > 1.0 { offStamps += 1 }
        if let ended = (line["ended_at"] as? String).flatMap(iso.date(from:)), ended < ts.addingTimeInterval(-1) {
            endedBeforeStart += 1
        }
    }
    expectEqual(offStamps, 0, "every sentence is stamped within a second of when it was spoken")
    expectEqual(endedBeforeStart, 0, "no sentence ends before it starts")
    let span = (kelsey.first?["ts"] as? String).flatMap(iso.date(from:)).flatMap { first in
        (kelsey.last?["ts"] as? String).flatMap(iso.date(from:)).map { $0.timeIntervalSince(first) }
    } ?? 0
    expectTrue(span > 60, "stamps spread over the talk (\(Int(span))s), not one time for all of it")

    // Meet trims old words off the front of a long segment mid-talk: what was
    // already written must not be written again, and nothing goes missing.
    let trimmedRun = run(trimAt: sentenceStarts[sentenceCount / 3] + 5)
    let trimmedTexts = trimmedRun.lines.filter { $0["speaker"] as? String == "Kelsey" }.compactMap { $0["text"] as? String }
    expectEqual(trimmedTexts.joined(separator: " "), monologue, "a front trim mid-talk loses and repeats nothing")
}

// Zoom: rows are one speaker's run of speech and keep growing. A long row,
// another speaker's row growing alongside it, a quiet spell long enough to
// write both out on idle, and then the long row growing again (Zoom keeps
// extending a row after it went idle).
do {
    let ada = TalkGrower(seed: 7, length: 6_000)
    let grace = TalkGrower(seed: 99, length: 600)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let (s, jsonl) = captionSession(ZoomApp(), at: t0)
    var now = t0
    func poll(_ ada: String, _ grace: String?) {
        var rows = [CaptionEntry(id: "row-ada", speaker: "Ada Lovelace", text: ada)]
        if let grace { rows.append(CaptionEntry(id: "row-grace", speaker: "Grace Hopper", text: grace)) }
        s.ingestCaptions(rows, now: now)
        now = now.addingTimeInterval(0.25)
    }
    func lines(of speaker: String) -> [[String: Any]] { captionLines(jsonl).filter { $0["speaker"] as? String == speaker } }

    let pauseAt = ada.throughSentence(at: ada.tokens.count * 4 / 5)
    let graceFrom = ada.tokens.count / 3
    while ada.shown < pauseAt {
        let adaText = ada.step(at: now, limit: pauseAt)
        let graceText: String? = ada.shown < graceFrom ? nil : (grace.done ? grace.settled : grace.step(at: now))
        poll(adaText, graceText)
    }
    let spokenBeforePause = ada.sentenceStarts.filter { $0 < pauseAt }.count
    let writtenWhileTalking = lines(of: "Ada Lovelace").count
    for _ in 0..<60 { poll(ada.settled, grace.settled) } // 15 quiet seconds: both rows go idle
    let writtenByPause = lines(of: "Ada Lovelace").count
    while !ada.done { poll(ada.step(at: now), grace.settled) }
    for _ in 0..<4 { poll(ada.settled, grace.settled) }
    s.finish(at: now)

    let adaLines = lines(of: "Ada Lovelace"), graceLines = lines(of: "Grace Hopper")
    let adaTexts = adaLines.compactMap { $0["text"] as? String }
    expectEqual(adaTexts.joined(separator: " "), ada.text,
                "Zoom: the long row is written once, in order, across the idle spell and the regrowth")
    expectEqual(graceLines.compactMap { $0["text"] as? String }.joined(separator: " "), grace.text,
                "Zoom: the row growing alongside it is written whole too")
    expectEqual(adaTexts.count, ada.sentenceCount, "Zoom: one line per sentence (\(ada.sentenceCount))")
    expectTrue((adaTexts.map(\.count).max() ?? 0) < 400, "Zoom: no giant line (longest \(adaTexts.map(\.count).max() ?? 0))")
    expectTrue(writtenWhileTalking >= spokenBeforePause - 2,
               "Zoom: sentences are written while the row is still growing (\(writtenWhileTalking) of \(spokenBeforePause))")
    expectEqual(writtenByPause, spokenBeforePause, "Zoom: going idle writes the rest of the row")
    expectEqual(offStamps(adaLines, ada), 0, "Zoom: every sentence is stamped within a second of when it was spoken")
    expectTrue((adaLines + graceLines).allSatisfy { $0["continues"] == nil },
               "Zoom: regrowth after idle arrives as sentences, not a continuation tail")
    let all = captionLines(jsonl).map { $0["speaker"] as? String }
    let firstGrace = all.firstIndex(of: "Grace Hopper") ?? -1, lastAda = all.lastIndex(of: "Ada Lovelace") ?? -1
    expectTrue(firstGrace > 0 && firstGrace < lastAda, "Zoom: two rows growing at once are written side by side")
}

// --- Checking that a captions press took ------------------------------------
//
// Regression (Meet, 2026-10-22): two presses at join were accepted and
// ignored, and the daemon gave up after the second. Captions stayed off until
// they were turned on by hand four minutes later.

do {
    expectTrue(Session.captionPressIsCheckable(pressToggles: false, surfaceIsTransient: false), "Meet's labelled button can be checked")
    expectTrue(!Session.captionPressIsCheckable(pressToggles: true, surfaceIsTransient: false), "Teams' toggle shortcut cannot")
    expectTrue(!Session.captionPressIsCheckable(pressToggles: false, surfaceIsTransient: true), "Slack's speech-only overlay cannot")
    expectEqual(Session.captionAttemptLimit(checkable: false), 2, "blind presses stop at two")
    expectEqual(Session.captionAttemptLimit(checkable: true), 5, "checked presses get the backoff")
    expectEqual(Session.captionRetryDelay(afterAttempt: 1), 10, "first retry soon")
    expectEqual(Session.captionRetryDelay(afterAttempt: 9), 120, "later ones capped")

    let pid: pid_t = 4242
    let element = AXUIElementCreateApplication(pid)
    /// Poll once a second for `seconds`, as the daemon's surface check does.
    func drive(_ s: Session, _ app: ScriptedApp, from start: Int, seconds: Int, each: (Int) -> Void = { _ in }) {
        for second in start..<(start + seconds) {
            each(second)
            app.now = s.startedAt.addingTimeInterval(TimeInterval(second))
            s.ensureCaptionsOn(app: element, pid: pid, now: app.now)
        }
    }
    func gaps(_ presses: [Date]) -> [Int] {
        zip(presses.dropFirst(), presses).map { Int($0.timeIntervalSince($1).rounded()) }
    }

    // Ignored every time: press, check 3s later, back off, and stop at five.
    do {
        let app = ScriptedApp()
        app.pressTakes = false
        let s = injectedSession(clock: FakeClock(start: Date(), step: 0), app: app)
        drive(s, app, from: 4, seconds: 900)
        expectEqual(app.presses.count, 5, "an ignored press is retried, up to five presses")
        expectEqual(gaps(app.presses), [13, 33, 63, 123], "each retry waits for the check, then backs off")
    }
    // Ignored once, then taken: two presses and done.
    do {
        let app = ScriptedApp()
        app.pressTakes = false
        let s = injectedSession(clock: FakeClock(start: Date(), step: 0), app: app)
        drive(s, app, from: 4, seconds: 300) { _ in if app.presses.count == 1 { app.pressTakes = true } }
        expectEqual(app.presses.count, 2, "a retry that takes ends the retries")
        expectTrue(app.captionsOn, "captions end up on")
    }
    // Taken, then turned off again: turned back on.
    do {
        let app = ScriptedApp()
        let s = injectedSession(clock: FakeClock(start: Date(), step: 0), app: app)
        s.ledger.markPopulated(pid: pid)
        drive(s, app, from: 4, seconds: 60) { second in if second == 30 { app.captionsOn = false } }
        expectEqual(app.presses.count, 2, "captions that go off again are turned back on")
        expectTrue(app.captionsOn, "and stay on")
    }
    // A blind toggle is never checked and never pressed more than twice.
    do {
        let app = ScriptedApp()
        app.captionPressToggles = true
        app.pressTakes = false
        let s = injectedSession(clock: FakeClock(start: Date(), step: 0), app: app)
        s.ledger.markPopulated(pid: pid)
        drive(s, app, from: 4, seconds: 600)
        expectEqual(app.presses.count, 2, "a toggle shortcut keeps its two blind tries")
    }
}

// --- Summary ------------------------------------------------------------

print(failures == 0 ? "\nall \(count) assertions passed" : "\n\(failures)/\(count) assertions FAILED")
exit(failures == 0 ? 0 : 1)
