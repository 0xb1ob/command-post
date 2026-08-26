# Slack steering plane — install (the human step)

Everything before this document is merged and inert. This repo ships the
relay, the thread ledger, and `share/slack-app-manifest.yml`, and it **does
not** create a Slack app, run an OAuth flow, or hold credentials. Until you do
the four steps below, `bin/cp relay post` exits `3` (not configured) and posts
nothing, and `bin/cp doctor` stays green.

Design: [command-post#83](https://github.com/0xb1ob/command-post/pull/83) for
origin scoping, `reports/origin-scoping.md` for the redaction rule.

## What is already true after merge

- `state/jobs.tsv` carries an `origin` column; `bin/cp dispatch --origin` stamps
  it (default `terminal`, which posts nowhere).
- `state/threads.tsv` maps an origin id to one Slack thread
  (`bin/cp threads bind`).
- `bin/cp relay render` renders one templated job event from the ledger.
  `bin/cp relay post` would post it — and refuses, fail-closed, with no tokens.
- `bin/cp threads events` / `bin/cp threads status ID` show a thread exactly
  what it may see: its own origin, cross-origin blockers redacted.
- The parent never writes to Slack. The STATUS BLOCK is terminal-only.

## What is not built yet

**Inbound.** Nothing here listens to Slack. Receiving a mention and turning it
into a dispatch needs an installed app (a Socket Mode app token), so it lands
in the slice after this one, together with the local authorization file that
gates it (steer tier vs owner-only mutate tier). Sequencing note, not a
promise: assume nothing about inbound until it exists.

Also deferred, deliberately: the scoped composer for prose replies, PR-URL
enrichment on `closed` events, and the always-on parent login item
(`launchd` plist is yours to load; this repo will never `launchctl load`
anything on your machine).

## Install

### 1. Create your own app from the manifest

One app **per human**, not per workspace. Socket Mode delivers each event to
one connected client per app, so two people sharing an app steal each other's
events.

1. Open <https://api.slack.com/apps> → **Create New App** → **From an app
   manifest**.
2. Pick the workspace, paste `share/slack-app-manifest.yml`, review the scopes.
3. Change `display_information.name` and `features.bot_user.display_name` from
   `cp-you` to `cp-<your-name>`.

If your workspace admin will not approve one app per person, stop here and say
so: the honest alternatives are per-user apps or nothing. A single shared app
with several Socket Mode connections is not a workaround — the events go to
whoever happens to be connected. There is no inbound HTTP option either; a
laptop should not expose an endpoint.

### 2. Install it and collect two tokens

- **Install App** → *Install to Workspace* → copy the **Bot User OAuth Token**
  (`xoxb-…`).
- **Basic Information** → *App-Level Tokens* → generate one with
  `connections:write` → copy it (`xapp-…`). Only inbound needs it; save it now
  so you do not repeat this step.

### 3. Put the tokens where the relay looks

```bash
mkdir -p "$CP_HOME/state/slack"
cat > "$CP_HOME/state/slack/tokens.env" <<'TOKENS'
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
TOKENS
chmod 600 "$CP_HOME/state/slack/tokens.env"
```

`state/` is gitignored, so this file is never committed. The relay **refuses to
post** (exit 1) if the file is group- or world-readable, if `SLACK_BOT_TOKEN`
is missing, or if it is not an `xoxb-` token. Override the path with
`CP_SLACK_TOKENS` if you keep secrets elsewhere.

Confirm:

```bash
bin/cp relay status      # slack: configured
bin/cp doctor            # Slack relay: tokens: configured
```

### 4. Bind a thread and post one event

Invite the app to the channel (`/invite @cp-<your-name>`), then take the
thread's channel id and parent-message `ts` (Slack **Copy link** gives
`…/archives/C0123ABCDEF/p1712345678000100` — the ts is `1712345678.000100`):

```bash
bin/cp threads bind acme-launch channel=C0123ABCDEF thread_ts=1712345678.000100
bin/cp dispatch --project acme --br-id acme-42 --origin acme-launch -- ...
bin/cp relay render --br-id acme-42 --kind dispatched   # read it before posting
bin/cp relay post   --br-id acme-42 --kind dispatched
```

Then read back what the machine said, which is the point of the outbound log:

```bash
cat "$(bin/cp threads log acme-launch)"
```

## Where the relay runs

The relay is a muxa **child of the parent** (or a subprocess of that child), so
it costs no muxa change: children cannot message each other, and the parent
keeps its one-root shape. Command-post never calls `tmux`, so making that pane
is a `muxa` spawn from the parent, not something `bin/cp` does for you. For the
parent itself, see [always-on-parent.md](always-on-parent.md).

## Identity

GitHub stays **per human**: the parent and its workers push with your own `gh`
auth. No shared bot — a shared identity makes CODEOWNERS and "author cannot
approve own PR" theatre, and gives every agent the union of everyone's
permissions. When a thread's request produces a PR, the PR body carries a
`Co-authored-by:` trailer and the originating Slack permalink: attribution to
the accountable human, disclosure that an agent typed it, and a link back to
who asked.

So: whoever's laptop runs the parent is the GitHub author, even when a
colleague asked in the thread. The thread and `state/threads.tsv` are the only
record that the request was theirs — which is exactly why the requester can
steer and only the owner can mutate.

## What each audience sees

| Viewer | Sees | Rendered by |
|---|---|---|
| Operator (terminal) | Everything: full STATUS BLOCK, all origins, parent prose | The parent's turn |
| A bound thread | Templated events + status for its own origin only | `bin/cp relay`, from the ledger |
| Other parents | Whatever a human posts in a thread they are in | Slack itself |

A thread whose job is `br dep`-blocked by another origin's job sees `blocked`
with no reason, forever, until the blocker shares its origin or closes. That is
the redaction rule working, not a bug: br ids are paired with plain-language
labels by contract, so naming the blocker would leak the other origin's work.

## Uninstall

Revoke the tokens in the Slack app settings, `rm -rf "$CP_HOME/state/slack"`,
and `bin/cp threads unbind <origin>` for each bound thread. Outbound logs under
`state/threads/` are kept on unbind — they are your audit trail; delete them
yourself when you are done with them.
