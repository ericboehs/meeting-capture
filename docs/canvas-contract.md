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

`ts` is ISO 8601 with offset. The `txt` stamps are the time of day of `ts`.

## Slides (`slides_dir`)

```
NNNN-HHMMSS.jpg        the frame (Retina, e.g. 2880×2560, ~1 MB)
NNNN-HHMMSS.thumb.jpg  the same frame 480 px wide
NNNN-HHMMSS.txt        on-device OCR of the frame (only with --ocr)
index.jsonl            one line per frame
```

`index.jsonl`:

```json
{"n": 3, "at": "2026-10-28T14:12:10-05:00", "file": "0003-141210.jpg", "thumb": "0003-141210.thumb.jpg",
 "reason": "change", "change": 0.41, "masked": 0, "width": 2880, "height": 2560}
```

The order of writes guarantees a reader never sees a partial image:

1. The jpg is written as `.tmp` and renamed into place.
2. The thumbnail, the same way.
3. The line is added to `index.jsonl`.
4. The `slide` event is added to the transcript.

So anything named in `index.jsonl` or a `slide` event is complete. `HHMMSS` is
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
with thumbnails, then `ended: true`. Ctrl-C ends it early the same way.
