# Relarm

Minimal macOS menu bar app for repeating alarms. Swift + AppKit, built with SPM
(no Xcode project). `build.sh` wraps the binary into `Relarm.app` (ad-hoc
signed) and zips it.

## Layout

- `Sources/RelarmCore` : schedule math, duration parsing, the `AlarmConfiguration`
  model. No AppKit, so it is the only part covered by `Tests/`.
- `Sources/Relarm` : the app. `main.swift` holds `AppDelegate` (status item,
  timers, notifications); `AlarmList.swift` the alarms window (toolbar +
  `NSTableView`); `AlarmForm.swift` and `Settings.swift` the two sheets;
  `UIHelpers.swift` shared metrics and window helpers.
- `scripts/icon.swift` generates `Resources/AppIcon.icns`. Run it with
  `swift scripts/icon.swift` from the repo root after editing.

Windows are built from stock AppKit controls and sized to fit their content.
Prefer an existing control over a custom view, and `Metrics` in `UIHelpers.swift`
over new hardcoded numbers.

`swift test` needs full Xcode. Under CommandLineTools it fails with
`no such module 'XCTest'`; CI has Xcode, so the tests run there.

## Releasing

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` and `version`
   in `Casks/relarm.rb`.
2. Tag and push: `git tag v0.3.0 && git push origin v0.3.0`. The GitHub
   Actions workflow (`.github/workflows/release.yml`) builds a universal
   `Relarm.app` and creates a GitHub Release with `Relarm.zip`.
3. Update the `sha256` in `Casks/relarm.rb`, then copy the cask to
   https://github.com/nikhilweee/homebrew-tap as `Casks/relarm.rb` and push.

Take the `sha256` from the released asset, not a local build:
`gh release download v0.3.0 && shasum -a 256 Relarm.zip`. CI builds universal
(arm64 + x86_64) while a local `./build.sh` under CommandLineTools builds only
the host arch, so the two zips do not hash the same.

Push the tag. A `Release x.y.z` commit on its own does nothing: the workflow
triggers on `v*` tags only, which is how v0.2.0 sat unreleased until v0.3.0.

The cask exists in two places: `Casks/relarm.rb` here (canonical copy) and the
`homebrew-tap` repo (the copy `brew` installs from). Step 3 keeps them in sync.
Because the app is ad-hoc signed, the cask needs its `postflight_steps` block to clear
the quarantine flag, or the first launch hits Gatekeeper.
