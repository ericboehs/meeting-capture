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
[00:00:04] Ada Lovelace: Morning everyone, let's get started.
[00:00:11] Grace Hopper: I pushed the caching fix last night.
[00:00:19] Ada Lovelace: Nice, did the p99 move? ▍
```

The last line updates in place as the sentence is spoken, then scrolls up when
it's final.

**Status:** Microsoft Teams works. Zoom is next.

## Why the Accessibility API

Every other option is worse:

| Approach | Problem |
| --- | --- |
| Microsoft Graph | Post-meeting only, needs recording enabled, no live access |
| Teams CART captions | Send-only. You can push captions in, not read them out |
| OCR the caption panel | Slow, lossy, needs the window visible and unobscured |
| Chrome DevTools protocol | The desktop app opens no debugging port |
| Audio + Whisper | No speaker names, and you still need the audio |

Teams renders its UI in a Chromium WebView, which exposes DOM ids and class
lists to the accessibility tree. That gives stable anchors — caption entries
are `fui-ChatMessageCompact__body` groups holding `[speaker, text]`, chat
messages carry `message-body-<epoch_ms>` ids — and it costs no CPU worth
mentioning, works with the window in the background, and hands you speaker
names for free.

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

### Re-granting after an upgrade

macOS ties an Accessibility grant to the binary's code signature, and ad-hoc
signing produces a new hash on every build. So after changing the source, the
permission silently stops working — the daemon logs `no Accessibility
permission` and exits.

```sh
./bin/meeting-capture-install            # only rebuilds if the source changed
./bin/meeting-capture-install reauthorize # opens the settings pane for you
```

Remove the stale `meeting-capture-daemon` row before adding the new one;
re-adding on top of it just re-registers the dead requirement.

If you have a Developer ID, sign with it instead and the grant survives
rebuilds entirely:

```sh
MEETING_CAPTURE_SIGN_ID="Developer ID Application: You (TEAMID)" ./bin/meeting-capture-install
```

## Usage

Run it with no arguments and it does the useful thing: if the agent is already
recording, it follows along; otherwise it records.

```sh
meeting-capture              # record every meeting, or follow the agent
meeting-capture --once       # just the meeting happening now
meeting-capture --follow     # only watch, never record
meeting-capture --help
```

An `flock` guarantees one recorder at a time, so a terminal copy can never
write a second transcript of the same meeting.

| Flag | Effect |
| --- | --- |
| `--app <name>` | Only watch one app (`teams`) |
| `--auto-captions` | Turn live captions on when a meeting starts |
| `--dir <path>` | Output directory |
| `--interval <ms>` | Poll interval during a meeting (default 250) |
| `--no-captions`, `--no-chat` | Skip one of the two sources |
| `--chat-backlog` | Also record chat that was already on screen |
| `--json` | Emit JSONL on stdout instead of pretty lines |
| `--quiet` | Say nothing |

### Automatic captions

`--auto-captions` (on by default in the agent) presses the app's own captions
shortcut when it finds a meeting without them. The keystroke goes straight to
the process with `CGEvent.postToPid`, which bypasses global event taps — so a
Hammerspoon or Karabiner remap of that shortcut won't intercept it.

It checks the captions panel chrome rather than whether captions are visible,
because apps clear the text after a few seconds of silence, and it stops trying
after two attempts. An earlier version got this wrong and toggled the panel on
and off every eight seconds.

## Output

Transcripts land in `~/.local/share/meeting-capture`, one pair per meeting:

```
20260824_140510-weekly-sync.txt     [00:00:38] Grace Hopper: Mic check 1-2.
20260824_140510-weekly-sync.jsonl
```

```json
{"type":"metadata","app":"Microsoft Teams","meeting":"Weekly Sync","source":"teams-ax","recorded_at":"2026-08-24T14:05:10-05:00"}
{"type":"caption","speaker":"Grace Hopper","text":"Mic check 1-2.","ts":"2026-08-24T14:05:48-05:00","ended_at":"2026-08-24T14:05:53-05:00","elapsed":"00:00:38","node_id":"8046"}
{"type":"chat","speaker":"Ada Lovelace","text":"here's the dashboard","ts":"2026-08-24T14:06:02-05:00","elapsed":"00:00:52","message_id":"1756061162000"}
{"type":"metadata","event":"stopped","stopped_at":"2026-08-24T14:05:53-05:00","duration":"00:00:42"}
```

Files are created on the first line written, so a meeting nobody speaks in
leaves nothing behind. Ctrl-C or leaving the meeting flushes whatever was
mid-sentence.

Wall-clock `ts` and `ended_at` on every caption make this useful beyond reading:
align the timestamps against a Whisper transcript of the same meeting and you
can attribute diarised audio to real names.

## How it works

The daemon polls the accessibility tree of each supported app:

1. **Is there a meeting?** Teams shows a Leave button (`hangup-button`) only
   during a call. Its absence for ten consecutive seconds ends the session —
   the button also disappears briefly during UI transitions, hence the debounce.
2. **Read the captions.** Each on-screen utterance has a stable node id. When an
   id disappears, that utterance is finished and gets written out.
3. **Read the chat.** Message ids are epoch milliseconds, which double as
   timestamps. Anything already on screen when you join is treated as seen.

A finished utterance is often re-rendered under a fresh node id, so identical
text from the same speaker is dropped if an active node already carries it as a
prefix, or if it was written in the last thirty seconds.

### Adding an app

Implement `MeetingApp` — roughly a dozen small methods over the accessibility
tree — and add it to `supportedApps`. Everything else (sessions, files, the
terminal view, the daemon) is app-agnostic.

## Privacy

Everything stays on your machine: transcripts are plain files under
`~/.local/share/meeting-capture` and nothing is sent anywhere. It reads only
the caption and chat panels of a meeting you are already in.

Recording people has laws and manners attached to it, both of which vary by
where you live. Tell your colleagues.

## License

MIT
