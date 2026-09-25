# Wedge alarm and supervision-dead alert

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
On tmux a digest of the daemon's own left unsent in the composer is not left to wedge: the daemon proves it is its own text and resubmits it (the `/afk` skill's "Submit model"), so the alarm is for stalls it cannot heal, such as captain text in the composer or a pane that stays busy.
On a claude primary the away posture runs no daemon at all, so this alarm belongs to `/quiet` there and to away mode on the harnesses that still run the daemon.
When a stranded digest the daemon cannot resubmit is what blocks delivery, a daemon the harness runs as its own tracked background job (claude's `/quiet`, grok) also hands its undelivered events back to firstmate through its exit, which reaches firstmate without the composer; a daemon launched into its own terminal has no such path, so this alarm is its floor (the `/afk` skill's "Max-defer escape").
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## Channels

`bin/fm-alert-lib.sh` owns these channels, and two alerts use them: this wedge alarm and the [supervision-dead alert](#supervision-dead-alert) below.
`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the caller.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary and title as argv items rather than interpolated source, so their text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Supervision-dead alert

Every supervision model relies on the primary session staying able to re-arm its watcher, so a session that dies quietly - a turn that ends in an API error, a machine that sleeps mid-reply, a closed terminal - leaves nothing inside firstmate that could notice.
`bin/fm-supervision-alert.sh` closes that gap from outside every agent session: a macOS launchd user agent runs its `check` every couple of minutes and alerts through the channels above when this home's watcher beacon has been dead for too long.
It only observes and notifies; it never arms a watcher, touches a lock, drains the wake queue, or types into a pane.

The alert fires once per outage when the home needs supervision, no live away daemon owns supervision (that daemon raises the wedge alarm instead), and `state/.last-watcher-beat` is at least `FM_SUPERVISION_ALERT_AFTER` seconds old (default 900) on two checks at least `FM_SUPERVISION_ALERT_CONFIRM` seconds apart (default 60).
The second sighting keeps a machine waking from sleep from alerting before its healthy watcher beats again.
A sleeping Mac runs no checks, so an outage that began before or during sleep alerts within a couple of checks after it wakes.
Later checks in the same outage stay silent, and the first check that sees a fresh beacon sends one "recovered" notice.
A single handling turn that outlives the threshold on a Claude primary also alerts, because the incident this exists for left the same records behind as a long turn does.
The script's header owns the exact predicate, its records, and every knob.

Install it once per home from that home, and remove it the same way:

```sh
FM_HOME=/path/to/home bin/fm-supervision-alert.sh install [--interval 120] [--after 900]
FM_HOME=/path/to/home bin/fm-supervision-alert.sh uninstall
FM_HOME=/path/to/home bin/fm-supervision-alert.sh status
```

The agent's label is scoped to the home, so each home on the machine carries its own.
Install pins the home, the installing shell's `PATH` (so a `command:` channel finds its tools), and the chosen knobs into the agent; run install again to change them.
Only macOS launchd is supported, and install refuses elsewhere; other schedulers such as systemd user timers or cron are follow-up work.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon or the supervision-dead checker is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
`tests/fm-supervision-alert.test.sh` drives the checker through its clock seam and a recorder: one alert per outage, no repeat, one recovery notice, silence with no live work, with a fresh beacon, or under a live away daemon, and the launchd install and removal against a stub `launchctl`.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
