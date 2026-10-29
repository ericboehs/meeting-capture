# Canvas contract

What meeting-capture writes for the canvas **Meeting** card and `/meeting` page
in [pi-boehsline](https://github.com/ericboehs/pi-boehsline)
(`extensions/canvas/`). The canvas only reads these files. meeting-capture
writes them, and the shape is versioned by `state.json`'s `v`.

Everything stays on this Mac. The files name private meetings, so the state
files are mode 600 and the canvas serves slides only from loopback.

## Where

The state directory is `$XDG_STATE_HOME/meeting-capture`, by default
`~/.local/state/meeting-capture`. The canvas may override it with
`MEETING_CAPTURE_STATE_DIR`, which is how `tests/fake-meeting` is pointed at.

## `state.json`: the one file to watch

Written atomically (temp file plus rename), mode 600. It's written when a
meeting is detected, again when its transcript is first created, and again when
the meeting ends.

```json
{
  "v": 1,
  "pid": 12345,
  "app": "Microsoft Teams",
  "app_id": "teams",
  "meeting": "Platform Weekly Sync",
  "started_at": "2026-10-28T14:00:00-05:00",
  "jsonl": "/Users/me/.local/share/meeting-capture/20261028_140000-teams-platform-weekly-sync.jsonl",
  "txt":   "/Users/me/.local/share/meeting-capture/20261028_140000-teams-platform-weekly-sync.txt",
  "slides_dir": "/Users/me/.local/share/meeting-capture/20261028_140000-teams-platform-weekly-sync.slides",
  "live": "/Users/me/.local/state/meeting-capture/live.json",
  "ended": false
}
```

- `pid` is the daemon's. If `ended` is false and the pid is dead, the daemon
  crashed mid-meeting, so treat the meeting as over.
- `jsonl` and `txt` are `null` until the first line is written. A meeting with
  no captions yet has no transcript.
- `slides_dir` is `null` when slides are off (no `--slides`) or the app has no
  share window that can be captured (only Teams has one today). When it's set,
  the folder may not exist until the first slide is saved.
- When the meeting ends, `state.json` is rewritten with `"ended": true`,
  `"ended_at"` and `"duration"` (`"1:02:03"`). It stays until the next meeting
  starts, so the card can show "Ended · 1:02:03".

## `live.json`: words being spoken now

Written atomically, mode 600, and only when it changes. It's removed when the
meeting ends.

```json
{"lines": [{"speaker": "Ada Lovelace", "text": "Did we get the alert", "ts": "2026-10-28T14:12:03-05:00"}]}
```

These are the in-progress caption lines, oldest first. The last one is the line
being spoken now. `{"lines": []}` means no one is mid-sentence. Each line's text
grows until it's final. Then it disappears from here and shows up as a
`caption` event in the transcript.

## Transcript (`jsonl`): append-only and final

One JSON object per line. Lines are only ever appended, and each event is final
once written (captions are written when they settle), so tail it by byte
offset. The first line is the metadata; a `stopped` metadata line ends a
finished meeting.

| `type` | Fields | Transcript line (`txt`) |
|---|---|---|
| `metadata` | `app`, `meeting`, `recorded_at`, `timestamps`; at the end: `event: "stopped"`, `stopped_at`, `duration` | header comments |
| `caption` | `speaker`, `text`, `ts`, `elapsed` | `[14:12:05] Ada Lovelace: text` |
| `chat` | `speaker`, `text`, `ts` | `[14:12:09] (chat) Edsger Dijkstra: text` |
| `people` | `text` (summary), `people` (names), `count`, `confirmed`, `ts` | `[..] (people) 5 in the meeting: …` |
| `slide` | `text`, `slide` (number), `file` (absolute path), `reason`, `ts` | `[14:12:10] ▣ slide 3  <base>.slides/0003-141210.jpg` |
| `revisit` | `text`, `slide` (the earlier slide's number), `file` (its image), `reason: "revisit"`, `ts` | `[14:15:02] ▣ back to slide 2  <base>.slides/0002-141030.jpg` |

`ts` is ISO 8601 with offset. The `txt` stamps are the time of day of `ts`.

### Revisits

A `revisit` means the screen went back to something already saved: an earlier
slide, or a tab shown before. It matches one of the last 10 saved frames
(`--repeat`, under 5% new). Nothing new is written to `slides_dir`. `slide` and
`file` point at the frame saved the first time, which is already in
`index.jsonl`. Revisits are their own type so that counting `slide` events
still counts distinct frames. Ways to show one:

- **Current slide:** a revisit makes slide `slide` current again, until the
  next `slide` or `revisit`.
- **Transcript:** a marker like a slide's ("▣ back to slide 2"), linked to that
  slide.
- **Thumbnail strip:** no new thumbnail. Optionally mark that slide as shown
  again at `ts`, or treat its click target as the latest showing.

Slide numbers are the helper's save order (`NNNN` in the file name), not the
deck's own page numbers, which it can't see.

## Slides (`slides_dir`)

```
NNNN-HHMMSS.jpg        the frame (Retina, e.g. 2880×2560, ~1 MB)
NNNN-HHMMSS.thumb.jpg  the same frame 480 px wide
NNNN-HHMMSS.txt        on-device OCR of the frame (the daemon always asks for it)
index.jsonl            one line per frame
```

`index.jsonl` (one line per saved frame; revisits don't add lines):

```json
{"n": 3, "at": "2026-10-28T14:12:10-05:00", "file": "0003-141210.jpg", "thumb": "0003-141210.thumb.jpg",
 "reason": "change", "change": 0.41, "masked": 0, "width": 2880, "height": 2560}
```

The order of writes guarantees a reader never sees a partial image:

1. The jpg is written as `.tmp` and renamed into place.
2. The thumbnail, the same way.
3. The line is added to `index.jsonl`.
4. The `slide` event is added to the transcript.

So anything named in `index.jsonl` or a `slide` event is complete.

The OCR `.txt` comes **after** all that, on a background queue, and is written
atomically. Expect it a second or two after the slide event. The first slide of
a session can take up to a minute while Vision loads its model. A missing
`.txt` means "not yet", not "no text". Lines are in reading order: a
two-column slide reads the left column, then the right, between full-width
lines such as the title. The window's own text (the Teams title bar, the
presenter's name) can appear in it too. `HHMMSS` is
the time of day, the same clock as the transcript's `[hh:mm:ss]`. `reason` is
`first frame` (the share started), `change` (new slide) or `heartbeat`.

## Legacy files

`current` (path of the live `.txt`) and `live` (rendered in-progress lines
ending in ` ▍`) are still written for `meeting-capture --follow`. New readers
should use `state.json` and `live.json`.

## Testing without a meeting

```sh
tests/fake-meeting                 # ~2 min meeting under /tmp/meeting-capture-fake
tests/fake-meeting --speed 4       # faster
tests/fake-meeting --no-slides     # nobody shares
MEETING_CAPTURE_STATE_DIR=/tmp/meeting-capture-fake/state   # point the canvas here
```

It writes the same files in the same order as a real meeting: captions that
grow word by word in `live.json`, chat, a people list, four synthetic slides
with thumbnails, two revisits (back to slide 2, then to slide 4), then
`ended: true`. Ctrl-C ends it early the same way.
