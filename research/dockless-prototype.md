# Archived per-app injection prototype

This Objective-C library loads into an AppKit app through `DYLD_INSERT_LIBRARIES`, using the approach demonstrated by [Dockless](https://github.com/michaelmitchell-bit/dockless).

- All normal windows minimized: set the host's activation policy to `Accessory`.
- Restore or create a visible normal window: return to `Regular`.
- Another window still visible: keep `Regular`.
- Hidden or windowless apps: keep their ordinary policy.
- Ignore auxiliary panels, attached windows, and apps originally launched as agents.

It affects **both the Dock and ⌘Tab**, must run inside each chosen app, and is not used by the standalone CmdTabo app.

## Validation

Ten disposable-app checks passed with direct injection and LaunchServices `LSEnvironment` loading: visible windows, partial and total minimization, attempted host promotion while minimized, restoration, repeated minimization, new windows, closed windows, hiding, and unhiding. AppKit policy and LaunchServices type were checked, and a menu action remained functional.

A copied cmux bundle also switched to `UIElement` after total minimization and back to `Foreground` after restoration, while partial minimization preserved `Foreground`. These checks do not establish complete visual compatibility with the native switcher or every host app.

## Reproduce

```sh
zsh scripts/build.sh
zsh scripts/test-injection.sh
zsh scripts/test-injection.sh --launch-services
open -n --env CMDTABO_MANUAL=1 build/CmdTaboTrial.app
```

To prepare an explicitly selected app copy:

```sh
python3 scripts/prepare-trial.py '/Applications/Example.app'
open -n 'build/Trials/Example.app'
```

The preparation script refuses to overwrite an existing trial copy and leaves the original unchanged. The copy keeps its original bundle ID unless `--bundle-id` is supplied, so app-specific data can still be shared. A separate bundle ID isolates standard preferences, not every host-specific file. Re-signing may affect protected entitlements, Keychain access, or sandbox behavior.

The library reconciles every 250 ms as well as observing window notifications. Apps managing their own activation policy may need adaptation. This prototype does not install services, change SIP, or modify Dock.app. Generated copies, libraries, and logs are ignored by Git and excluded from the standalone release.
