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

## 2026-09-01, Google Meet

Meet's roster is everything Teams' is not, and the reader shares nothing with
it but the plumbing. Measured live on a call that grew from 52 to 61 people:

- The side panel holds `AXList` described **"Participants"**, whose children
  ARE the people: each row's AXDescription is the name. A dial-in participant's
  name is their phone number.
- `AXButton` titled **"Contributors 59"** is the head count. Below the list sits
  **"Also invited 104"** and a second `AXList` described "Guests" — people who
  were invited and did not come. Reading only the Participants list's children
  keeps them out.
- Rows matched the count exactly at 59, 60 and 61, so there is no pagination to
  expand. Scrolling is kept as a fallback for a call big enough that Meet drops
  offscreen rows, because a shortfall would otherwise be silent.
- **AXPress works.** Opening the panel, closing it and restoring chat are all
  presses. Nothing comes forward, nothing is clicked, no window is resized, and
  the politeness gate is skipped (`rosterSnapshotIsQuiet`).

Restoring the panel needs structure, not labels. The side panel shows one thing
at a time, so reading the roster closes whatever was there — including the chat
panel the daemon reads. What it was showing:

| Showing | How to tell |
| --- | --- |
| People | the Participants list is present |
| Chat | an `AXWebArea` described "Chat" (it is an iframe) |
| Closed | the side panel landmark has no children |

The obvious signal lies: with chat open, the first `AXHeading` inside the side
panel is **"Today"** — a date separator in the message list, not the panel's
name. The chat button toggles, so restoring chat is one press.

Live verification, 61-person call:

- on demand: 61/61 confirmed in ~3s; panel state identical before and after,
  tested from both chat-open and closed
- automatic: `recorded the participant list: 61 in the meeting (confirmed)`,
  one `people` event, 61 unique names, alongside 378 captions and 3 chat
  messages recorded in the same minute

## The snapshot that never ran (2026-09-01)

The Meet snapshot worked on demand and in a bare daemon (`--people-snapshot`),
then recorded nothing at all in the real one — no roster line, no failure, no
warning, for 33 minutes of a live call.

Nothing was wrong with the snapshot. The daemon runs it on a background thread
and takes a global lock first, because fronting, clicking and key posting are
all global state and two of them at once land in each other's windows. The poll
loop takes the same lock for its surface upkeep — turning captions on, reopening
chat — and both of those search the whole tree *before* they conclude they have
nothing to do. Against a caption panel of thousands of nodes, four times a
second, the lock was essentially never free.

So the loser was always the same one: the poll loop asked constantly and the
snapshot asked once every 20 seconds, and lost every time. Deferrals are silent
by design (they are not failures and cost no attempt), which is why 20 minutes
of them looked exactly like nothing happening.

Two changes, both needed:

- surface upkeep takes the lock at most once a second rather than at every poll
  — a second is plenty for turning captions back on, and it costs less CPU at
  idle too;
- the snapshot thread *waits* up to 5s for its turn (`UIAutomation.enter(waitingUntil:)`)
  instead of giving up instantly. The poll loop must never block, since it is
  what records captions, but the snapshot was moved onto its own thread
  precisely so it could afford to wait.

Reproduced and fixed against the same live call: with the daemon's exact flags
(`--auto-captions --popout-captions --popout-chat --people-snapshot`), before
the fix zero attempts completed; after it, `recorded the participant list: 60
in the meeting (confirmed)`.

The lesson generalises: a try-lock between a fast poller and a slow, patient
job is not a fair fight, and a silent retry hides the fact that it never was.
