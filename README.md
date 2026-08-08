# Relarm

Relarm is a minimal macOS menu bar app for repeating alarms. Add named alarms
that fire at a chosen time and then repeat on an interval until you disable or
delete them.

## Install

```sh
brew install nikhilweee/tap/relarm
```

Or download `Relarm.zip` from the [latest release](https://github.com/nikhilweee/relarm/releases/latest)
and drag `Relarm.app` to `/Applications`.

## Using it

Relarm lives in the menu bar. Click the bell for the next few alarms, to open
the alarms window, or to quit. The bell shows a dot while at least one alarm is
enabled. Clicking an alarm in that menu opens it for editing.

The alarms window lists everything you have scheduled, with a switch per alarm.
Use the toolbar to add an alarm or open settings, and `Return`, `Delete` or a
right click to edit and remove the selected row. Relarm only takes a Dock icon
and menu bar while this window is open.

Each alarm has a name, a first alert time, a repeat interval and a sound.
Intervals are free-form:

| Input | Means |
| --- | --- |
| `25` | 25 minutes (a bare number is minutes) |
| `5m` | 5 minutes |
| `1h 30m` | 1 hour 30 minutes |
| `90s` | 90 seconds |
| `1:30` | 1 minute 30 seconds (`mm:ss`) |
| `1:02:03` | 1 hour 2 minutes 3 seconds (`hh:mm:ss`) |

The minimum repeat is one minute. Settings sets the sound and interval that new
alarms start with; alarms you already created keep their own.

Alarms ring through standard macOS notifications, with Snooze (10 minutes) and
Stop actions, and play the sound you picked until stopped. Relarm keeps the next
occurrence in its preferences, so reopening it resumes the next future alarm
rather than replaying alerts you missed while it was closed.

## Build

```sh
./build.sh
open Relarm.app
```
