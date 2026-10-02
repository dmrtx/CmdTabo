# Archived native-switcher investigation

The standalone CmdTabo app supersedes this investigation. These notes retain technical findings and reproduction instructions; local paths, process IDs, device names, and raw session output are intentionally omitted.

## LaunchServices

Private LaunchServices symbols and `applicationSerialNumber` were available. Calling `_LSSetApplicationInformationItem` from another process returned success but did not change the disposable app's observed type from `Foreground`. Repeating with an initialized AppKit controller and using `lsappinfo` did not change the outcome.

The same private setter worked when called by the disposable app itself. AppKit activation policy changes also switched that app between `Foreground` and `UIElement`. Mixing private changes with AppKit may leave inconsistent internal state, so these are not evidence of a general external-app filter.

```sh
zsh research/run-probes.sh
```

The script creates, signs, tests, and closes only its own temporary bundle. Exit code 5 in the cross-process check means the mutation/readback assertion failed even if the setter returned success. Generated bundles and logs stay outside Git.

## Dock and injection approaches

Static inspection of Dock exposed an `ASAppSwitcher` class, a `_processes` field, and selector navigation methods. This suggests an investigation point, not a validated filter. No Dock injection or SIP change was performed.

An in-process library can change its host app to `Accessory` when every normal window is minimized and back to `Regular` when a window is restored. This removes the app from both the Dock and ⌘Tab and requires modifying each selected app. CmdTabo's standalone switcher avoids those requirements.

The [injection prototype](dockless-prototype.md) and [copied-app trial](cmux-trial.md) retain the reproducible experiments. They do not modify installed originals and are not packaged in the standalone release.

## Sources

- [Original LaunchServices example](https://gist.github.com/0xced/2044955)
- [WebKit LaunchServices declarations](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/cocoa/LaunchServicesSPI.h)
- [Apple: AXMinimized](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute)
- [Apple: window restoration notification](https://developer.apple.com/documentation/applicationservices/kaxwindowdeminiaturizednotification)
- [yabai: Dock injection requirements](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)
- [Dockless](https://github.com/michaelmitchell-bit/dockless)
