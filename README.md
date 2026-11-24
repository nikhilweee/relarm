# Relarm

A minimal menu bar app for repeating alarms on macOS.

- Click the bell for the next alarms, to open the alarms window, or to quit.
  The bell carries a dot while an alarm is enabled; click an alarm to edit it.
- The alarms window lists what you have scheduled, with a switch on each row.
  Add from the toolbar; Return, Delete and right-click edit, duplicate or remove a row.
- An alarm has a name, a first alert time, a repeat interval (`5m`, `90s`,
  `1h 30m`) and a sound, and repeats until you disable or delete it.
- Alerts arrive as macOS notifications and ring until you click Stop, the
  notification, or its close button. Alarms missed while the app was closed are skipped, not replayed.
- Settings… sets the sound and interval that new alarms start with.

## Install

```sh
brew install --cask nikhilweee/tap/relarm
```

Then launch Relarm from /Applications. The app is ad-hoc signed (no Apple
Developer account); the cask clears the quarantine flag after install so
Gatekeeper doesn't block the first launch.

## Build from source

```sh
./build.sh
open Relarm.app
```

Produces `Relarm.app` and a `Relarm.zip` for distribution, universal when full
Xcode is installed.
