# People snapshot — probe notes

## 2026-08-31, 293-person briefing

- Meeting window: `AXStandardWindow` containing `hangup-button`.
- People button: `roster-button`, `AXButton`, desc `People`; the visible badge
  count is **not exposed** to AX.
- Panel appears only after a real HID click. Root is `AXGroup`
  `desc=Participants`; list is `AXOutline desc=Attendees`.
- Count lives in `roster-title-section-*`: description
  `In this meeting, 293 total`, child StaticText `In this meeting (293)`.
- Participant rows contain `AXGroup domid=calling-roster-item-*`; bare name is
  the StaticText under `roster-avatar-img-*`. Row descriptions add state chips
  such as Organizer/Muted.
- Only ~20 participant rows exist initially. The first paginator was below the
  visible panel and unresolved before the meeting ended.

## 2026-08-31, 8-person call

- `people-snapshot` ran clean: title count 8, all 8 names, confirmed, panel
  closed and UI restored.
- 9 AXRows existed (title + 8 people), with empty space below. This confirmed
  the large list is paginated by count, not merely clipped by window height.

## 2026-09-01, 311-person briefing

### Focus/click root cause

`NSRunningApplication.activate()` was refused while Ghostty was active. The
probe printed `frontmost after activate: Ghostty`; every alleged Teams HID
click landed on the terminal, and Teams' ⇧⌘A shortcut did not take. Setting
`kAXFrontmostAttribute=true` on Teams' application element, followed by
`AXRaise` on the meeting window, reliably made Teams frontmost. Raising then
posting ⇧⌘A restored captions. All Teams click/shortcut paths now use this.

### Pagination + virtualization

1. Initial command result: **20 loaded / 311 in title count**.
2. The 20th row was clipped exactly at the panel/window bottom. Temporarily
   growing the meeting window to the display bottom exposed an
   `AXStaticText value="See more"`.
3. Its clickable ancestor is an `AXRow` (`AXPress`). Pressing it changed the
   list from the initial 20-row page to a virtualized list with ~26 visible.
4. Chromium accepts pixel-wheel deltas, not line-wheel deltas here. Two -350px
   events per overlapping step accumulated 101 distinct participant keys.
5. At each page boundary another clipped paginator appears, now labelled
   `+203 more` / `+N more`. Structure:

```
AXStaticText value="+N more"
  AXGroup class=fui-StyledText (AXPress exposed, may false-succeed)
    AXGroup class=fui-TreeItemLayout__main
      AXRow title="+N more" class=fui-TreeItem (AXPress)
        AXOutline desc=Attendees
```

6. Pager progress must be verified by a disappearing label or a smaller N;
   visible row count remains ~26 because the list is virtualized.
7. Names must be accumulated across overlapping viewports by the stable
   `calling-roster-item-*` key, then walked back to the top to restore/read the
   current title count. A snapshot can still mismatch if people leave during
   the scan; output must remain explicit about that.

The meeting emptied before the final rebuilt command could be run end-to-end,
but each mechanism above was proved independently against the live tree.

## Automatic snapshots (daemon)

`--people-snapshot` records one roster per meeting. Design constraints that
fell out of the probes above:

- **Background thread.** Expanding a 300-person roster is minutes of clicking
  and scrolling. On the poll loop that would drop every caption spoken
  meanwhile, so the reading runs on a utility queue and hands its result back
  through a one-slot `RosterInbox`.
- **One automated interaction at a time.** Fronting, clicking and key posting
  are global state. `UIAutomation` is a process-wide try-lock shared by the
  roster thread and the poll loop's caption/chat/unpin clicking; whoever loses
  skips that tick rather than blocking, because the waiter would be the poll
  loop itself.
- **90 seconds after joining.** Late enough for the joining rush, and after
  the captions/chat pop-out attempts (0s and 60s) have had the pointer.
- **Deferrals are not failures.** Someone typing, or a meeting window on
  another Space, means "not now": retry in 20s, spend no attempt. Only three
  real attempts are allowed, two minutes apart.
- **The lull is a hunt, not a sample.** Live test, Sep 1: the first gate asked
  once every 20s for total input silence and never fired in a 20-minute
  meeting. Probing the event source showed why — `keyDown` idle was 19-25s
  while `mouseMoved` idle never exceeded ~2s, a hand resting on the trackpad.
  The gate now ignores bare pointer movement, asks for 3s without typing and
  1.5s without a click/drag/scroll, and re-checks every 2s. It fired within
  seconds of that change, in the same meeting, with the same user activity.
- **Real hardware only.** Idle is read from `.hidSystemState`, not
  `.combinedSessionState`, so the snapshot's own synthetic clicks and pointer
  restores do not read as the user being busy.
- **Written once.** A confirmed roster is written immediately; an unconfirmed
  one is only written when the last attempt is spent, so a transcript holds
  exactly one roster and a short one says how short.
- **Cheap for small meetings.** The window is only enlarged, and the list only
  scrolled, when the loaded rows fall short of the title count. An 8-person
  call is one panel open, one read, one panel close.

## 2026-09-01, live verification (12-person meeting)

- `people-snapshot` on demand: 12/12, confirmed, ~3s of AX work. Probed the
  window before and after — identical frame `(-1575, 283) 960x1049`, panel
  closed, pointer and front app restored.
- Automatic path, run as a second daemon against the same live meeting with
  the settle time shortened: `recorded the participant list: 12 in the meeting
  (confirmed)`, written as `[14:09:23] (people) 12 in the meeting
  (confirmed): …` in the text half and a `people` event carrying
  `count`/`confirmed`/`roster_count` and a 12-string list in the jsonl.
  Captions kept being recorded throughout (26 lines in the same file).
