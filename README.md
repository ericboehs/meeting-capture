# meeting-capture

Live transcripts of your macOS video meetings, written to disk as they happen.

Conferencing apps show live captions but throw them away — Teams keeps roughly
three lines on screen and drops the rest. Microsoft Graph will sell you a
transcript, but only after the meeting ends, only if the organiser enabled
recording, and never in real time. `meeting-capture` reads the captions off the
screen through the macOS Accessibility API and appends them to a file, so the
transcript exists the moment the words are spoken.

It runs as a launchd agent: join a meeting and it starts recording, leave and it
closes the file. Nothing to remember, no button to press.

```
$ meeting-capture
[2026-08-24T14:40:24-05:00] meeting-capture: joined "Weekly Sync" in Microsoft Teams (pid 32731)
[14:40:28] Ada Lovelace: Morning everyone, let's get started.
[14:40:35] Grace Hopper: I pushed the caching fix last night.
[14:40:43] Ada Lovelace: Nice, did the p99 move? ▍
```

The last line updates in place as the sentence is spoken, then scrolls up when
it's final.

**Supported:** Microsoft Teams, Zoom, Slack huddles, and Google Meet installed
as a Safari web app (alpha — tried only in a one-person call).

## Install

Requires macOS and the Swift toolchain (`xcode-select --install`).

```sh
git clone https://github.com/ericboehs/meeting-capture
cd meeting-capture
./bin/meeting-capture-install
```

This compiles `bin/meeting-capture` to `~/.local/bin/meeting-capture-daemon`,
installs a launchd agent, and starts it. It will then tell you to grant
Accessibility permission, which you have to do by hand:

**System Settings → Privacy & Security → Accessibility → `+` →
`~/.local/bin/meeting-capture-daemon`** (⇧⌘G in the picker to type the path)

```sh
launchctl kickstart -k gui/$UID/com.ericboehs.meeting-capture
tail -f ~/.local/state/meeting-capture/launchd.log
```

Uninstall with `./bin/meeting-capture-install uninstall`.

### Granting once instead of after every build

macOS ties an Accessibility grant to the binary's code signature. Ad-hoc signing
produces a new signature on every build, so each rebuild silently revokes the
permission and the daemon exits with `no Accessibility permission`.

Making a signing identity once fixes that for good:

```sh
./bin/meeting-capture-install signing-cert   # asks for your login password
./bin/meeting-capture-install                # rebuild, signed with it
```

It creates a self-signed certificate trusted for code signing only, which turns
the requirement macOS remembers into something stable:

```
designated => identifier "meeting-capture-daemon" and certificate leaf = H"bbab…"
```

The same binary keeps satisfying that no matter how often you rebuild. A
Developer ID does the job too, via `MEETING_CAPTURE_SIGN_ID`.

You still have to grant permission once after switching (the stored requirement
changed): run `./bin/meeting-capture-install reauthorize`, **remove** the
existing `meeting-capture-daemon` row, then drag the revealed binary in.
Re-adding on top of the old row just re-registers the dead requirement.

## Usage

Run it with no arguments and it does the useful thing: if the agent is already
recording, it follows along; otherwise it records.

```sh
meeting-capture              # record every meeting, or follow the agent
meeting-capture --once       # just the meeting happening now
meeting-capture --follow     # only watch, never record
meeting-capture people-snapshot  # Teams: list and confirm everyone present
meeting-capture --help
```

An `flock` guarantees one recorder at a time, so a terminal copy can never
write a second transcript of the same meeting.

| Flag | Effect |
| --- | --- |
| `--app <name>` | Only watch one app (`teams`, `zoom`, `slack`, `meet`) |
| `--auto-captions` | Turn live captions on when a meeting starts |
| `--popout-captions` | Teams: move captions into their own window, which a covered window can't pause |
| `--popout-chat` | Open the meeting chat so it is recorded unattended; in Teams it also gets its own window |
| `--dir <path>` | Output directory |
| `--follow`, `--watch` | Watch whatever the running daemon is recording, never record |
| `--interval <ms>` | Poll interval during a meeting (default 250) |
| `--no-captions`, `--no-chat` | Skip one of the two sources |
| `--chat-backlog` | Also record chat that was already on screen |
| `--json` | Emit JSONL on stdout instead of pretty lines |
| `--quiet` | Say nothing |

### People snapshot

`meeting-capture people-snapshot` is a one-shot Teams roster, independent of
the recorder lock: it opens People, expands every page, walks the virtualized
list in overlapping viewports, and prints names alphabetically. `--json` adds
Teams' participant keys for machine use. A clean result says it was confirmed
against the panel's own count; a changing meeting or an expansion failure says
exactly how many were loaded instead of presenting a partial list as complete.
The People button's visible badge is not exposed to AX, so the title row —
`In this meeting (311)` — is the authoritative count available to the command.
The panel, meeting-window size, pointer and frontmost app are restored when it
finishes.

### Automatic captions

`--auto-captions` (on by default in the agent) turns captions on when it finds
a meeting without them. Zoom exposes a pressable captions button, so it just
presses it. Teams doesn't, so its meeting window is made genuinely frontmost
and its shortcut (⇧⌘A) goes straight to the process with `CGEvent.postToPid`,
which bypasses global event taps — a Hammerspoon or Karabiner remap of that
shortcut won't intercept it. Fronting is load-bearing: macOS can refuse
`NSRunningApplication.activate()` while another app is active, leaving Teams'
shortcut and every HID click aimed at the wrong window. Slack has a captions tab
in the huddle's side panel, pressed only if no captions are anywhere on screen,
so a huddle already captioning is left alone — but the press does switch the
side panel to captions, which is worth knowing if you were reading another tab
in it. Meet's button says which way it goes
("Turn on captions" against "Turn off captions"), so it is never a guess.

Zoom takes two extra steps. Unless you've pinned it, its captions control lives
in the **More** overflow, so the button gets opened first and put back if the
item isn't there. And Zoom drops its whole toolbar out of the accessibility tree
whenever the pointer leaves the window — there's no menu item or preference to
reach it another way, and a synthetic mouse-move doesn't fool it. So for Zoom
this is opportunistic: it waits and acts the moment the toolbar next appears.
Moving your mouse over the window once is enough. Turning captions on yourself
works just as well; capture doesn't depend on any of this.

It checks the captions panel chrome rather than whether captions are visible,
because apps clear the text after a few seconds of silence, and it stops trying
after two attempts. An earlier version got this wrong and toggled the panel on
and off every eight seconds. Slack has no such chrome — its captions exist only
while someone is speaking — so once its overlay has been seen it is never asked
again, since every pause would otherwise look like captions being switched off.

### Teams stops transcribing when its window is covered

Cover the Teams meeting window *completely* — one full-screen window over it is
enough — and the transcript stops. macOS reports the window as occluded, Teams
parks it and puts up the small "compact view" instead, and everything in the
parked window freezes: the call timer stops ticking, no new caption rows
arrive. The accessibility tree still holds the whole captions panel, so nothing
looks wrong; it is just a photograph of the last live moment. Leave one pixel
showing and it never happens, and the window resumes the instant any of it is
visible again — even moving it is enough.

`--popout-captions` (on by default in the agent) sidesteps it. Teams' captions
panel can be popped out into its own window, and that window is not subject to
any of this: it goes on receiving captions while completely covered, even with
the meeting window parked at the same time — measured on a live call, 36
seconds under an opaque window, captions arriving throughout. The text does not
come from the meeting window's renderer. So at the start of a Teams meeting the
panel is popped out, and captions are read from there in preference to the
panel in the meeting window, which may be a frozen copy of itself.

The window is tucked off the outside edge of your second display with a small
nub of it left on screen, which is as close to out of sight as it can get: it
does not need to be visible (a 620x360 window showing a 40x40 corner produced
captions without a gap for the length of a test), but it does need to be OPEN.
Minimizing it is the one thing that really stops it — measured on a live call,
the rows sat frozen for 30 seconds and jumped from 4 to 12 the instant the
window came back — so a minimized captions window is reopened, with a line in
the log saying why. Drag it somewhere you like and it stays there; it is only
placed once per meeting.

Teams pops it out pinned above every other window, which is in the way for no
gain, so the pin comes off. Pinning is read from the window server's layer
rather than the button's label, which is localized; a window it can't report on
— one on another Space — is left alone, since the control is a toggle and a
wrong guess would pin what you unpinned.

`--popout-chat` does the same for the meeting chat, which has a second problem
besides: the panel has to be OPEN to exist at all, so an unattended meeting
records no chat whatever the window is doing. The panel is opened and given its
own window, which is read from in preference to the panel inside the meeting
window. Its pop-out control carries no id and its label is localized, so it is
found structurally: the chat panel header has exactly two buttons, and the one
that is not `rail-header-close-button` is it.

That window is left in plain sight rather than tucked away — chat is something
you read and reply to — so put it where you like. It is only reopened if
minimized, since a minimized window receives nothing. Whether Teams parks a
completely covered chat window the way it parks the meeting window has not been
measured (it needs someone to post while it is buried); if chat ever goes quiet
in a transcript while the window was covered, that is the first thing to
suspect.

The same flag opens Google Meet's chat panel, which has the same all-or-nothing
problem: closed, it is not in the accessibility tree at all, so an unattended
meeting records no chat. Meet answers `AXPress`, so there is no clicking, no
activating its window and no stealing of focus — and no pop-out either, since
Meet has nothing to pop out to. Either panel is only opened twice, a minute
apart: closing it again is an answer, and reopening it forever would be an
argument.

Popping out costs a couple of seconds of focus: Teams' WebView ignores both
`AXPress` and mouse events posted to the process — they report success and do
nothing — so it takes a real click through the window server, which means
bringing Teams to the front. The pointer and the previously frontmost app are
put back afterwards. If the window is too narrow, Teams folds the pop-out
control into an overflow menu that can't be opened through accessibility, so
the window is widened for the click and set back to its old width.

Without the flag, a stalled call timer is reported in the log rather than left
to look like a quiet meeting.

## Output

Transcripts land in `~/.local/share/meeting-capture`, one pair per meeting.
Filenames carry when capture began (not when the meeting did), where it
happened, and what it was called:

```
20260824_140510-teams-weekly-sync.txt
20260824_140510-teams-weekly-sync.jsonl
20260824_185316-zoom-personal-meeting-room.jsonl
20260824_185849-slack-eng-standup.txt
```

The text file opens with what the bracketed times mean, so a transcript is
still readable years later on its own:

```
# Weekly Sync (Microsoft Teams)
# recording started 2026-08-24T14:05:10-05:00
# meeting started   2026-08-24T13:28:15-05:00
# [hh:mm:ss] is the time of day

[14:05:48] Grace Hopper: Mic check 1-2.
```

Transcript stamps are always the time of day, so a quote can be lined up
against a calendar entry, a chat message, or someone else's recording without
arithmetic. The header supplies the date, and — where the app publishes a call
clock — when the meeting was already running.
(One naming caveat: the header line "meeting started" and the jsonl field
`meeting_started_at` are historical names — they record when this *participant*
connected per the app's own clock, not when the meeting was convened.)

```json
{"type":"metadata","app":"Microsoft Teams","meeting":"Weekly Sync","source":"teams-ax","recorded_at":"2026-08-24T14:05:10-05:00","meeting_started_at":"2026-08-24T13:28:15-05:00","timestamps":"elapsed"}
{"type":"caption","speaker":"Grace Hopper","text":"Mic check 1-2.","ts":"2026-08-24T14:05:48-05:00","ended_at":"2026-08-24T14:05:53-05:00","elapsed":"00:37:33","node_id":"8046"}
{"type":"chat","speaker":"Ada Lovelace","text":"here's the dashboard","ts":"2026-08-24T14:06:02-05:00","elapsed":"00:37:47","message_id":"1756061162000"}
{"type":"metadata","event":"stopped","stopped_at":"2026-08-24T14:06:20-05:00","duration":"00:01:10"}
```

Files are created on the first line written, so a meeting nobody speaks in
leaves nothing behind. Ctrl-C or leaving the meeting flushes whatever was
mid-sentence.

The jsonl keeps a meeting-relative `elapsed` field for reasoning about position
within a call. It counts from the app's own clock (when this participant
connected), not from when recording began,
where the app will say how long the call has been running. Zoom keeps such a
clock in its title bar — though note it reads "My connected time", so it is
when *you* joined the call rather than when the meeting was convened; Teams'
call timer behaves likewise. That is still far better than counting from zero:
attach an hour in and `elapsed` reads `00:36:41` instead of `00:00:00`, with
`meeting_started_at` recording what it was measured against. The reference is
picked once, before the first line is written, so a file never changes its
story halfway through; if the clock only becomes visible after capture has
begun writing, `elapsed` counts from when recording began instead.

Slack publishes no such clock, so a huddle's `elapsed` counts from when the
capture attached and `timestamps` reads `time-of-day`. Either way the .txt is
unaffected — it is wall-clock in every app.

Wall-clock `ts` and `ended_at` on every caption make this useful beyond reading:
align the timestamps against a Whisper transcript of the same meeting and you
can attribute diarised audio to real names.

### Merging a split meeting

The daemon opens a new transcript every time it starts, so restarting it
mid-meeting (a rebuild, a crash, launchd relaunching it) leaves one
conversation spread over two files. The seam repeats itself, too: the app's
caption panel still shows the last few utterances, and the fresh session reads
them as new.

```sh
bin/meeting-capture-merge ~/.local/share/meeting-capture/20260826_11{4653,5435}-zoom-*.jsonl
# merged 2 transcript(s) -> …/20260826_114653-zoom-meeting-40-minutes-merged.txt
#   204 line(s) kept, 94 snapshot(s) collapsed, 0 continuation(s) rejoined
```

It writes a new `.jsonl`/`.txt` pair (`-o BASE` to choose where) and never
touches the originals. Along the way it collapses lines that are snapshots of
one utterance being spoken — where one is a prefix of another from the same
speaker, close by — which also cleans up transcripts recorded before the
growth-flood fixes, and rejoins `"continues": true` tails to the row they
extend. The rule stays local (`--lookback`, `--window`) so that genuine
repetition later in the meeting survives.

## How it works

The daemon polls the accessibility tree of each supported app:

1. **Is there a meeting?** Each app shows a leave control only during a call
   (`hangup-button` in Teams, `AXIdentifier=leave` in Zoom, a `Leave Huddle`
   button in Slack, a `Leave call` button in Meet). Its absence for ten
   consecutive seconds ends the session —
   the control also disappears briefly during UI transitions, hence the
   debounce.
2. **Read the captions**, and decide when an utterance is finished. The apps
   differ here, which is why `MeetingApp` gets a say:

   - **Teams** clears old captions, keeping about three on screen. An utterance
     is done when its node id disappears.
   - **Zoom** appends rows and keeps them, so nothing would ever "disappear". A
     row is done once a newer row appears beneath it; the idle timer is the
     backstop for the newest row (twelve seconds, since a pause mid-speech
     looks just like silence). Every app with such a timer treats its newest
     utterance the same way. Note what this does and does not buy: leaving a
     meeting or stopping the daemon gracefully flushes pending lines via
     finish(), but a crash or SIGKILL writes nothing — the timer only limits
     how long the final words would have sat unwritten in the ordinary case.
   - **Slack** overlays about five events on the video tiles and fades them,
     replacing the element on every revision — so one sentence arrives as a
     succession of elements sharing no id. Faded events are identified by their
     position in the huddle's conversation; the one still being spoken is
     tracked through its revisions.
     The overlay is also absent whenever nobody is talking, which says nothing
     about whether captions are on.
   - **Google Meet** keeps one block per speaker holding a list of sentences,
     appending as each finishes and revising only the last. Nothing carries a
     DOM id, so a sentence is identified by its position in that list rather
     than by its text — people say "Yeah." twice, and hashing would file that
     as one.
3. **Read the chat.** In Teams, message ids are epoch milliseconds, which double
   as timestamps; anything already on screen when you join is treated as seen.
   Google Meet gives chat no ids and no per-message grouping at all — the panel
   is a flat run of lines reading author, time, text, time, text, with a name
   appearing once however many messages that person sends in a row. Timestamps
   are the only part with a recognisable shape, so they are the hinge: the line
   after one is a message, and a line that is neither is a name. Ids are hashed
   (FNV-1a, not `Hasher`, whose seed changes every run) from time, author and
   text, so the same words twice in a minute count once and the same words
   tomorrow count again. A message consisting only of a clock ("3:02") reads as
   furniture and is skipped, which is the price of a panel with no ids. Zoom
   chat is not wired up yet.

Google Meet has no desktop app, so the target here is the Safari web app — Meet
added to the Dock from Safari, which macOS runs as its own process. A Meet tab
in an ordinary browser window is not supported: the browser would be the
process, every other tab would share its tree, and finding the call would mean
searching all of them.

A finished utterance is often re-rendered under a fresh id, so identical text
from the same speaker is dropped if an active entry already carries it as a
prefix, or if it was written in the last thirty seconds.

### Adding an app

Implement `MeetingApp` — roughly a dozen small methods over the accessibility

tree — and add it to `supportedApps`. Everything else (sessions, files, the
terminal view, the daemon) is app-agnostic.

## Tests

The pure logic (clock parsing, timestamps, slugs, wrapping, caption-segment
identity) has unit tests:

```sh
tests/run.sh
```

They compile the daemon with its entry point stripped and drive the rest.
The accessibility-facing code needs a real meeting to reason about, so it is
not covered here. The same run also covers the installer's signing tri-state
and agent restart (`tests/installer.sh`) and the merge tool's collapse rules
(`tests/merge.sh`); both can be run on their own.

## Privacy

Everything stays on your machine: transcripts are plain files under
`~/.local/share/meeting-capture` and nothing is sent anywhere. It reads only
the caption and chat panels of a meeting you are already in.

Recording people has laws and manners attached to it, both of which vary by
where you live. Tell your colleagues.

## License

MIT
