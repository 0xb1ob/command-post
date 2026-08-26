# Always-on parent

A Slack mention that arrives when no parent is running must not be queued and
executed later — that is a one-element command queue, and the human who typed it
is no longer there. So "no parent" should mean "the laptop is off", not "nobody
started it": start the parent at login and leave it running.

Two artifacts, both inert until you act:

- `scripts/cp-parent-start.sh` — checks the home, runs `bin/cp doctor`
  advisorily, and execs the agent CLI **in the pane it is already in**.
- `share/launchd/com.command-post.parent.plist.example` — an example login item
  that makes that pane.

## Why the split

`AGENTS.md` says command-post may never call `tmux` directly, and muxa has no
"start a root" primitive (adding one would be a muxa change, which this slice
does not make). So the `tmux new-session` call lives in **your** login item, and
the start script refuses to run outside a pane. Nothing in this repo loads the
plist; `launchctl load` is yours to run.

## Install

```bash
cp share/launchd/com.command-post.parent.plist.example \
   ~/Library/LaunchAgents/com.command-post.parent.plist
# replace /Users/YOU/command-post with your CP_HOME, and check the tmux path
launchctl load ~/Library/LaunchAgents/com.command-post.parent.plist
tmux attach -t command-post
```

`CP_PARENT_CMD` picks the agent CLI (default `claude`); it is split on spaces, so
`CP_PARENT_CMD="claude --model opus"` works.

## What you are agreeing to

- **A standing capability.** An always-on parent holds your `gh` auth all day.
  That is the reason authorization is local and owner-only: a colleague can
  steer a thread, only you can mutate.
- **Context rot.** A long-lived session fills with old envelopes and eventually
  needs a restart. Thread bindings live in `state/threads.tsv`, so they outlive
  it — restart freely.
- **Idle means idle.** The parent must not poll (`AGENTS.md`). Its only wake
  sources are your keystrokes and `[muxa]` mail.
- **No respawn loop.** The example plist deliberately omits `KeepAlive`: a
  parent respawned mid-job comes back with a fresh context and no idea what it
  was doing. Restart it yourself and read the ledger.

## Sleep and reconnect

A laptop asleep receives nothing: Socket Mode delivers only to connected
clients, and missed events are gone. When inbound lands, the intended behaviour
is to announce once per bound thread on reconnect ("back online; anything sent
while offline was not received — repeat if still wanted") and execute nothing.
Replaying stale events after a wake is the thing this design refuses.

A laptop that sleeps mid-job orphans its workers exactly as it does today;
`bin/cp status` and `treehouse` recovery are unchanged.
