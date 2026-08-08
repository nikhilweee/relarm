# Relarm

Relarm is a minimal macOS menu-bar alarm app. Add named alarms that fire at a
selected time and then repeat until individually disabled or deleted. Choose
one of the built-in intervals (5, 15, or 30 minutes; or one hour) or enter a
custom duration such as `45m` or `1h 30m`.

The app uses standard macOS notifications and the system alert sound. It keeps
the next scheduled occurrence in its preferences, so reopening the app resumes
the next future alarm rather than replaying missed alerts.

## Build

```sh
./build.sh
open Relarm.app
```
