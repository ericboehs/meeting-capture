# People snapshot — probe notes (2026-08-31)

Findings from the live "2026 VA Daily IT Stand-Up Briefing" (Teams, pid 42892),
taken while building `people-snapshot`. The meeting ended before the "More"
control could be found, so this is what to re-check next meeting. No participant
names are recorded here beyond the three that happened to appear in probe
output; structure only.

## How the roster panel is reached

- Meeting window: `AXStandardWindow` containing `hangup-button` (as everywhere).
- People button: `roster-button`, `AXButton`, desc `People` — **no count in the
  AX tree**. The participant count is NOT on the button as the UX suggests; the
  authoritative count lives in the panel's title row (see below). If the count
  must be confirmed against the button, that will need the rendered label, not
  AX — or the title row alone.
- The panel does NOT exist in the tree until opened. Opened with a real HID
  click on `roster-button` (activate Teams first, save/restore pointer +
  frontmost app — same machinery as `popOutCaptions`). First attempt worked;
  a retry a minute later needed a longer wait before the panel appeared, so
  poll for the panel for ~3s rather than sleeping a fixed 1.2s.

## Panel structure (desc-keyed, since most nodes have no DOM id)

```
AXGroup desc=Participants            <- panel
  AXHeading  "Participants"          (header)
  AXButton  desc=|Close participants pane|   (y=392, right side of header)
  AXButton  desc=||(empty)           279x32, full panel width, y=462
  AXGroup (search/whatever the wide control is)
  AXGroup
    AXOutline desc=|Attendees|       <- the list
      AXRow → AXGroup domid=roster-title-section-2
        desc=|In this meeting, 293 total|
        AXStaticText val=|In this meeting (293)|   <- THE COUNT
      AXRow
        AXGroup domid=calling-roster-item-8:orgid:<uuid>
          desc=|<Name>, [Organizer,] Muted|
          AXGroup  domid=roster-avatar-img-8:...   → AXStaticText val=<Name>
          AXImage/AXGroup domid=roster-mic-button-8:... desc=|Muted|
```

- Names: `AXStaticText` inside `roster-avatar-img-*`. Also in the
  `calling-roster-item-*` description, suffixed with state ("Muted",
  "Organizer, Muted") — prefer the avatar's StaticText, it is the bare name.
- `8:` prefix in the dom id keys looks like a shard/instance number; match
  `calling-roster-item-` by prefix, parse the key after it for dedup.
- DOM ids are otherwise absent in this panel — anchor on descriptions.

## Virtualization / the "More" question (UNRESOLVED)

- 293 people, only **19 AXRows** rendered — rows from y=537 down to y=1332,
  i.e. the visible pane of a ~1440px window. This is a virtualized list:
  more rows must be materialized somehow before a snapshot can count them.
- The bottom of the visible list coincided with the window's bottom edge;
  no "More"/"Load more" button was found **below** the last row at that
  moment. Candidate: the wide (279x32) empty-desc button at y=462 — but
  clicking it CLOSED the panel (rows 19 → 0). Possibly the close affordance
  re-rendered between probe and click; treat that button as unknown until
  re-probed: dump its subtree (`AXDOMClassList`, value, children) BEFORE
  clicking anything near it.
- Scrolling: wheel events do nothing unless the pointer is moved into the
  panel first (CGEvent scroll acts at the pointer). The scroll probe to the
  bottom of the list never ran to completion — meeting ended first. Next
  meeting: move pointer into the panel, scroll to the bottom, then look for
  a "More" affordance and dump it before clicking.

## Planned shape of the command

`meeting-capture people-snapshot [--app teams] [--json]`:
1. Find the meeting window (hangup-button), read count from
   `roster-title-section-*` if the panel is already open.
2. If closed: HID-click `roster-button` (restore pointer + front app).
3. Materialize the whole list (More / scrolling — TBD).
4. Collect names from `roster-avatar-img-*` StaticTexts, dedup by the
   `calling-roster-item-*` key.
5. Report loaded rows vs the title-row count; only a full match is a clean
   snapshot — partial output must say how many are missing.
6. Close the panel again the same way it was opened (or leave open if it
   already was), and restore pointer + frontmost app.

## Afternoon 8-person call (2026-08-31, live-verified)

- `people-snapshot` shipped and ran clean on a small meeting: count read
  from the title row, all 8 names, confirmed, panel closed, pointer and
  frontmost app restored. Subcommand committed at ef96e84.
- Confirmed the list is virtualized by COUNT, not window height: 9 AXRows
  (8 people + title row) with the pane less than half full, so materializing
  the rest is not a matter of scrolling a rendered pane — rows must be
  ADDED by the "More" control (or something equivalent).
- The daemon restart after install logged "Microsoft Teams, Slack is
  running, waiting for a meeting" — the decayed-snapshot guards are in.
