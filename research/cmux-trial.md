# Archived copied-app trial

A separately named cmux bundle was prepared to test the per-app injection prototype without changing the installed original. Its bundle identity and local socket were separated from the original for the experiment. Raw process IDs, hashes of installed files, and workstation-specific paths are not retained here.

## Reproduce with an installed cmux copy

```sh
python3 scripts/prepare-trial.py /Applications/cmux.app \
  --bundle-id com.cmuxterm.app.cmdtabo \
  --display-name 'cmux CmdTabo' \
  --env CMUX_TAG=cmdtabo \
  --env CMUX_SOCKET_PATH=/tmp/cmux-cmdtabo.sock
open -n build/Trials/cmux.app
```

The different bundle ID isolates standard preferences, and the separate socket avoids sending trial commands to the original app. Host-specific files in shared locations may still be shared.

## Observed behavior

| Action | Result |
| --- | --- |
| Launch with a normal window | `Foreground`; library loaded |
| Minimize the only visible window | `UIElement` |
| Reopen the same trial copy | Same window restored; `Foreground` |
| Create another window | Menu worked; second window created |
| Minimize only one of two windows | Still `Foreground` |
| Minimize the last visible window | `UIElement` |
| Reopen the copy again | Window restored; `Foreground` |

Original executable and plist contents were unchanged. The checks covered activation policy, menu operation, and window restoration, not SSH, extensions, Keychain, updates, or full native-switcher visual behavior.

Quit the trial copy and use the original app to stop using the injected module. This affects the Dock as well as ⌘Tab. The standalone CmdTabo app does not load this module, and trial bundles are not committed or included in releases.
