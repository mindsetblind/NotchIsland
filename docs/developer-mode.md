# Developer Mode

NotchIsland can show long-running tasks — builds, tests, scripts, local servers — next to the
notch: a spinner with a timer while a task runs, then «готово» or the error when it ends. It works
with any IDE or terminal: tasks are reported with the bundled `notchisland-cli` or with one line of
JSON from any script.

Turn it on in **Settings → Разработка**. It is off by default; while it's off, events are answered
with an error and ignored.

## notchisland-cli

The tool lives inside the app: `/Applications/NotchIsland.app/Contents/MacOS/notchisland-cli`.
Optionally link it into your `PATH`:

```bash
ln -sf /Applications/NotchIsland.app/Contents/MacOS/notchisland-cli /usr/local/bin/notchisland-cli
```

```bash
# Wrap a command: reports start, then success/failure with its exit code; exits with the same code.
notchisland-cli run --category build -- swift build -c release
notchisland-cli run --category test --title "Unit tests" -- npm test

# Or report the steps yourself:
notchisland-cli start deploy --title "Deploy to staging" --category deploy
notchisland-cli progress deploy 40%
notchisland-cli message deploy "uploading assets"
notchisland-cli finish deploy --exit-code $?          # or --status success|failure|cancelled

# Local servers only announce start and stop (they would otherwise occupy the island for hours):
notchisland-cli start api --title "API :8080" --category server
notchisland-cli finish api --status cancelled
```

Options: `--quiet` (no warnings), `--verbose` (print the island's answer).
If NotchIsland isn't running, the tool does nothing and exits 0 (`run` exits with the command's
code), so scripts never break because of it. Ctrl-C during `run` reaches your command as usual and
the task is reported as cancelled.

### In a shell script

```bash
#!/bin/zsh
ni() { /Applications/NotchIsland.app/Contents/MacOS/notchisland-cli --quiet "$@" }

ni start nightly --title "Nightly backup" --category script
if rsync -a ~/Projects /Volumes/Backup/; then
    ni finish nightly --status success
else
    ni finish nightly --status failure --message "rsync failed"
fi
```

### Without the CLI

Any program can write one JSON line to the socket, e.g. with `nc`:

```bash
echo '{"v":1,"type":"task","event":"start","id":"make","title":"make all","category":"build"}' \
  | nc -U "$HOME/Library/Application Support/NotchIsland/claude.sock"
```

## Event format (version 1)

One JSON object per connection, terminated by a newline, at most 8 KB.

| Field | Type | Required | Notes |
|---|---|---|---|
| `v` | number | yes | `1` |
| `type` | string | yes | `"task"` |
| `event` | string | yes | `start`, `progress`, `message`, `finish` |
| `id` | string | yes | 1–64 ASCII characters: letters, digits, `. _ : / -`. Same ID = same task. |
| `title` | string | no | shown in the island; trimmed to 80 characters |
| `category` | string | no | `build`, `test`, `script`, `server`, `deploy`, `other` (unknown → `other`) |
| `message` | string | no | short detail; trimmed to 300 characters |
| `progress` | number | no | 0…1 (clamped) |
| `status` | string | for `finish`* | `success`, `failure`, `cancelled` |
| `exit_code` | number | for `finish`* | 0 = success, anything else = failure |
| `source` | string | no | name of the sender, for display |

\* `finish` needs `status` or `exit_code`.

The island answers with one line: `{"ok":true}` or `{"ok":false,"error":"…"}`.

Behaviour:

- `start` for a finished task starts a new run (the timer restarts); for a running task it only updates it.
- `progress`/`message` for an unknown ID create the task (the sender may have started before the island).
- A second `finish` for the same run is ignored.
- A task running longer than the limit in Settings (10 min by default) is announced once.
- A running task with no events for 6 hours is marked as interrupted. Finished tasks are forgotten after an hour; at most 20 tasks are kept.
- The exact same event repeated within a second is dropped; bursts above ~20 events (then 5 per second) are dropped too.

## Security

- The socket is a Unix domain socket in `~/Library/Application Support/NotchIsland/`, mode `0600`;
  connections from other users are rejected (`getpeereid`). There is no network listener.
- Messages are size-limited, validated field by field; control characters are stripped from text.
- The island never executes, opens or writes anything because of an event — it only displays it.
  (`notchisland-cli run` runs *your* command in *your* terminal; nothing is executed on the island's side.)
- The same socket carries Claude Code hook events (see `Sources/notchisland-hook`).
