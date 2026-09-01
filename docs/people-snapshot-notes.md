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
