// Tests for bin/screen-capture-prototype's change detection. Run by
// tests/run.sh, which compiles the prototype without its entry point beside
// this file.
//
// Frames are drawn here, not captured: a browser-like window (a fixed toolbar
// and sidebar around a scrolling page of text) at known scroll offsets, and
// slides sharing one template. So scroll and novelty numbers are checked
// against what really moved, with nothing on screen touched.

import AppKit
import CoreGraphics
import Foundation

var count = 0
var failures = 0

func expectTrue(_ condition: Bool, _ name: String) {
    count += 1
    if condition { print("ok \(count) - \(name)") }
    else { failures += 1; print("not ok \(count) - \(name)") }
}

let width = 1440, height = 1280
let toolbar = 110, sidebar = 260

/// A long document of text lines, different per `seed`.
func documentLines(seed: Int, count: Int = 400) -> [String] {
    let words = ["platform", "deploy", "incident", "latency", "service", "budget", "review", "canary",
                 "metrics", "alert", "certificate", "rollout", "pipeline", "queue", "cache", "region",
                 "owner", "runbook", "error", "threshold", "migration", "database", "replica", "token"]
    var rng = UInt64(bitPattern: Int64(seed)) &* 6364136223846793005 &+ 1442695040888963407
    func next() -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int(rng >> 33) }
    return (0..<count).map { line in
        if line % 9 == 0 { return "" }
        let n = 4 + next() % 9
        return (0..<n).map { _ in words[next() % words.count] }.joined(separator: " ")
    }
}

/// A browser-ish window scrolled `scroll` points down a document.
func page(seed: Int, scroll: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // AppKit's flipped flag doesn't flip the context; do it, so y runs down.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let lineHeight: CGFloat = 30
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
    for (i, line) in documentLines(seed: seed).enumerated() {
        let y = CGFloat(toolbar) + 20 + CGFloat(i) * lineHeight - CGFloat(scroll)
        guard y > CGFloat(toolbar) - lineHeight, y < CGFloat(height) else { continue }
        (line as NSString).draw(at: NSPoint(x: CGFloat(sidebar) + 40, y: y), withAttributes: attributes)
    }
    // Chrome drawn last, over the page: it never scrolls.
    NSColor(white: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: toolbar).fill()
    NSRect(x: 0, y: 0, width: sidebar, height: height).fill()
    ("https://example.test/runbook" as NSString).draw(at: NSPoint(x: 300, y: 40), withAttributes: attributes)
    for i in 0..<12 {
        ("Section \(i + 1)" as NSString).draw(at: NSPoint(x: 30, y: CGFloat(toolbar) + 30 + CGFloat(i) * 50),
                                              withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

/// A slide in a shared template: same banner and footer, different words.
func slide(_ title: String, _ bullets: [String]) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // AppKit's flipped flag doesn't flip the context; do it, so y runs down.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor.white.setFill()
    NSRect(x: 0, y: 200, width: width, height: 880).fill()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 200, width: width, height: 20).fill()
    NSRect(x: 0, y: 1060, width: width, height: 20).fill()
    (title as NSString).draw(at: NSPoint(x: 60, y: 260), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.systemBlue])
    for (i, bullet) in bullets.enumerated() {
        ("•  " + bullet as NSString).draw(at: NSPoint(x: 90, y: 400 + CGFloat(i) * 80),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 36),
                                                           .foregroundColor: NSColor.darkGray])
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

/// Through the same path as a live capture: a 320 px probe, then the grid.
func grid(_ image: CGImage) -> Frame { frame(scaled(image, width: Int(probeWidth))!) }

let bar = Options().newContent // --new
let allLive = [Bool](repeating: true, count: thumbWidth * thumbHeight)
func judge(_ a: CGImage, _ b: CGImage) -> Novelty {
    novelty(grid(b), against: grid(a), live: allLive, delta: Options().delta)
}
func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

// --- novelty: one comparison --------------------------------------------

let top = page(seed: 1, scroll: 0)
let same = judge(top, page(seed: 1, scroll: 0))
expectTrue(same.fraction == 0, "an unchanged window is nothing new")

let nudge = judge(top, page(seed: 1, scroll: 90)) // three lines
print("# three-line scroll: shift \(nudge.shift) rows, new \(pct(nudge.fraction))")
expectTrue(nudge.shift > 0, "a scroll down is seen as one")
expectTrue(abs(nudge.shift - 10) <= 1, "by about the 90 pt it moved (\(nudge.shift) rows ≈ 10)")
expectTrue(nudge.fraction < bar, "a three-line scroll is under --new (\(pct(nudge.fraction)))")

let half = judge(top, page(seed: 1, scroll: 500))
print("# 500 pt scroll: shift \(half.shift) rows, new \(pct(half.fraction))")
expectTrue(half.shift > 0, "a long scroll is still seen as a scroll")
expectTrue(abs(half.shift - 56) <= 1, "by about the 500 pt it moved (\(half.shift) rows ≈ 56)")
expectTrue(half.fraction > bar * 2, "a scroll of under half the page clears --new easily (\(pct(half.fraction)))")

let up = judge(page(seed: 1, scroll: 600), page(seed: 1, scroll: 450))
print("# scroll up 150 pt: shift \(up.shift) rows, new \(pct(up.fraction))")
expectTrue(up.shift < 0, "a scroll up is a negative shift")
expectTrue(up.fraction < bar, "a short scroll up is under --new (\(pct(up.fraction)))")

let far = judge(top, page(seed: 1, scroll: 1400))
print("# scrolled past a whole page: shift \(far.shift), new \(pct(far.fraction))")
expectTrue(far.fraction > bar * 2, "scrolling past a whole page clears --new easily (\(pct(far.fraction)))")

let otherTab = judge(top, page(seed: 2, scroll: 0))
print("# another page, same chrome: shift \(otherTab.shift), new \(pct(otherTab.fraction))")
expectTrue(otherTab.fraction > bar * 2, "another page under the same toolbar clears --new easily (\(pct(otherTab.fraction)))")

let deck1 = slide("Deploy Pipeline", ["Median deploy 14m → 9m", "Flaky tests quarantined: 12", "Canary on by default"])
let deck2 = slide("Incident Review", ["Auth failures 9/18", "Root cause: vendor cert chain", "Fix: alert on auth errors"])
let slides = judge(deck1, deck2)
print("# next slide, same template: shift \(slides.shift), new \(pct(slides.fraction))")
expectTrue(slides.fraction >= bar,
           "the next slide in a shared template clears --new (\(pct(slides.fraction)))")

// --- Detector: what gets saved over time --------------------------------

/// Feed frames as a settled screen each: enough identical ticks to settle.
struct Run {
    var detector = Detector(options: Options())
    var clock = Date(timeIntervalSince1970: 0)
    var saved: [Int] = []
    var revisits: [Int] = []
    var n = 0

    mutating func show(_ image: CGImage) {
        let thumb = grid(image)
        for _ in 0..<4 {
            clock += 1
            let reading = detector.feed(thumb, at: clock, lastSave: nil)
            if reading.save {
                n += 1
                saved.append(n)
                detector.didSave(thumb, number: n)
            }
            if let earlier = reading.revisited { revisits.append(earlier) }
        }
    }
}

do {
    var run = Run()
    run.show(top)
    for step in 1...3 { run.show(page(seed: 1, scroll: step * 60)) }
    expectTrue(run.saved == [1], "a few small scrolls don't save a frame each (saved \(run.saved))")
    for step in 4...12 { run.show(page(seed: 1, scroll: step * 60)) }
    // 720 pt in twelve nudges: a frame every few, not one per nudge.
    expectTrue(run.saved.count >= 2 && run.saved.count <= 5,
               "but they add up to a frame every so often (saved \(run.saved) over 12 nudges)")
}
do {
    var run = Run()
    run.show(page(seed: 1, scroll: 0))
    run.show(page(seed: 2, scroll: 0))
    run.show(page(seed: 1, scroll: 0))
    expectTrue(run.saved == [1, 2], "going back to an earlier tab saves nothing new (saved \(run.saved))")
    expectTrue(run.revisits == [1], "and is reported as a revisit of frame 1 (\(run.revisits))")
    run.show(page(seed: 2, scroll: 0))
    expectTrue(run.saved == [1, 2] && run.revisits == [1, 2], "and back again is frame 2 (\(run.revisits))")
}
do {
    var run = Run()
    run.show(deck1)
    run.show(deck2)
    run.show(slide("Next Steps", ["Legacy services onto canary", "Retire old agents", "Review thresholds"]))
    expectTrue(run.saved == [1, 2, 3], "every new slide is saved (saved \(run.saved))")
}

// --- OCR reading order --------------------------------------------------

do {
    // Vision's coordinates: origin bottom-left, so a higher midY is higher up.
    func line(_ text: String, x: Double, y: Double, width: Double) -> TextLine {
        TextLine(text: text, box: CGRect(x: x, y: y, width: width, height: 0.03))
    }
    let lines = [
        line("Title across both columns", x: 0.05, y: 0.90, width: 0.80),
        line("L1", x: 0.05, y: 0.80, width: 0.40), line("R1", x: 0.55, y: 0.80, width: 0.40),
        line("L2", x: 0.05, y: 0.75, width: 0.40), line("R2", x: 0.55, y: 0.75, width: 0.40),
        line("L3", x: 0.05, y: 0.70, width: 0.40),
        line("Footer across both", x: 0.05, y: 0.10, width: 0.80),
    ]
    expectTrue(readingOrder(lines) == ["Title across both columns", "L1", "L2", "L3", "R1", "R2", "Footer across both"],
               "two columns read one at a time, between full-width lines (\(readingOrder(lines)))")
    // A real slide's layout (OpStat, placeholder text): columns only 2.2% apart.
    let tight = [
        line("Title", x: 0.015, y: 0.744, width: 0.849),
        line("L heading", x: 0.013, y: 0.705, width: 0.291), line("R heading", x: 0.506, y: 0.705, width: 0.356),
        line("L wide", x: 0.013, y: 0.681, width: 0.471), line("R wide", x: 0.506, y: 0.681, width: 0.443),
        line("L more", x: 0.013, y: 0.638, width: 0.440), line("R more", x: 0.506, y: 0.631, width: 0.092),
    ]
    expectTrue(readingOrder(tight) == ["Title", "L heading", "L wide", "L more", "R heading", "R wide", "R more"],
               "columns 2.2% apart are still two columns (\(readingOrder(tight)))")
    let single = [line("one", x: 0.1, y: 0.8, width: 0.3), line("two", x: 0.1, y: 0.7, width: 0.3)]
    expectTrue(readingOrder(single) == ["one", "two"], "a single column reads top to bottom")
}
do {
    // Real OCR on a drawn two-column slide.
    let context = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.translateBy(x: 0, y: 900)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1440, height: 900).fill()
    let big: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.black]
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
    ("Incident Review" as NSString).draw(at: NSPoint(x: 60, y: 60), withAttributes: big)
    for (i, text) in ["Impact was nationwide", "Root cause was a certificate", "Resolved by the vendor"].enumerated() {
        (text as NSString).draw(at: NSPoint(x: 60, y: 200 + CGFloat(i) * 70), withAttributes: body)
    }
    for (i, text) in ["Next thirty days", "Alerting goes live"].enumerated() {
        (text as NSString).draw(at: NSPoint(x: 800, y: 200 + CGFloat(i) * 70), withAttributes: body)
    }
    NSGraphicsContext.restoreGraphicsState()
    let text = recognizeText(context.makeImage()!)
    let order = ["Incident Review", "Impact was nationwide", "Root cause was a certificate", "Resolved by the vendor",
                 "Next thirty days", "Alerting goes live"]
    let positions = order.map { text.range(of: $0)?.lowerBound }
    expectTrue(!positions.contains(nil) && zip(positions, positions.dropFirst()).allSatisfy { $0! < $1! },
               "OCR of a two-column slide reads the left column before the right (\(text.replacingOccurrences(of: "\n", with: " | ")))")
}

print(failures == 0 ? "all \(count) assertions passed" : "\(failures)/\(count) assertions FAILED")
exit(failures == 0 ? 0 : 1)
