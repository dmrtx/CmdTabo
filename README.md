# CmdTabo

A small macOS app switcher with the familiar ⌘Tab interaction: one icon per app, a translucent single-row panel, and the selected app's name underneath. It keeps applications in the Dock.

Three independent filters are enabled by default:

- **Apps with all windows minimized** disappear until a window is restored.
- **Hidden apps (⌘H)** disappear until the app is unhidden. Hiding and minimizing are handled separately.
- **Apps with windows only on other displays** are excluded from the display under the pointer when switching starts.

An app with eligible windows on both displays appears on both. Windows spanning displays belong to the display containing the largest portion of the window. With the minimized-app filter disabled, minimized windows also count toward display membership. Windowless apps and unknown window states remain available unless the hidden-app filter excludes them.

## Download and use

Get the Apple Silicon build from [Releases](https://github.com/dmrtx/CmdTabo/releases), extract the ZIP, and move **CmdTabo.app** to a stable location such as Applications.

The release is experimental, ad hoc signed, and not notarized. macOS may require approving the app in System Settings → Privacy & Security before it opens. The deployment target is macOS 13; runtime validation has been performed on macOS 27, Apple Silicon. Compatibility with other macOS versions is not yet verified.

1. Open CmdTabo and click **Grant Accessibility**. Enable it in System Settings → Privacy & Security → Accessibility. On macOS 27 this pane is named **Device Control and Data Access**.
2. Hold ⌘ and press Tab to move forward; ⌘⇧Tab moves backward.
3. Release ⌘ to activate the selected app. Esc cancels; clicking an icon also switches apps.

The menu bar icon opens **CmdTabo Settings…**, **Preview switcher**, **Pause / resume**, and **Quit CmdTabo**. Preview works with the mouse before granting Accessibility. Unchecking **Use CmdTabo for ⌘Tab**, pausing, or quitting restores the original macOS shortcuts.

All three filter settings are saved independently. Rebuilding or replacing an ad hoc signed app may require removing and re-adding it in Accessibility.

## Permissions and privacy

CmdTabo requests **Accessibility only**, to intercept the switcher shortcut. It does not request Screen Recording or Input Monitoring, capture window pixels, read window titles, record keystrokes, or send telemetry. It has no network client, automatic updater, or login-item installer.

It reads app visibility and window metadata locally. The optional `--diagnose` command prints app names, window metadata, and display information; diagnostic output is for local inspection and is not part of published releases. See [publication checks](PRIVACY.md).

AltTab's current [FAQ](https://alt-tab.app/faq) also allows skipping Screen Recording, without thumbnails. CmdTabo contains no thumbnail capture implementation.

## Build and test

Requires Xcode or Swift command-line tools and the macOS SDK. There are no external package dependencies or Xcode project.

```sh
swift test
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/package-app.sh release
open build/CmdTabo.app
build/CmdTabo.app/Contents/MacOS/CmdTabo --self-test-windows
build/CmdTabo.app/Contents/MacOS/CmdTabo --native-status
```

The window probe creates only its own disposable windows and checks real WindowServer states. `--native-status` reads the two original switcher shortcut states without changing them. `--diagnose` is a separate, opt-in local diagnostic.

```sh
bash scripts/package-release.sh
python3 scripts/audit-publication.py --history --archive build/releases/CmdTabo-0.1.1-macos-arm64.zip
```

Release packaging remaps source paths, strips debug information, removes extended attributes, and archives only the app. It generates a SHA-256 checksum file alongside the ZIP. Build output and diagnostic data are ignored by Git.

## How it works

- AppKit presents a nonactivating panel and reuses its views while the app list stays unchanged. Changing selection updates the highlight and label.
- `NSRunningApplication.isHidden` and workspace notifications track hidden apps without another permission.
- A session event tap consumes ⌘Tab. After the tap starts, the private `CGSSetSymbolicHotKeyEnabled` API disables symbolic hotkeys 1 and 2, preserving their previous values. It does not change ⌘` or other shortcuts.
- An exclusive file lock prevents another instance from reading or changing the shortcuts while they are owned. A temporary child process inherits the lock and restores the original values if the main process crashes or is force-quit. The lock remains held until restoration finishes. The child exits on normal restoration and is not installed as a service. Failed keyboard recovery also restores the native shortcuts.
- SkyLight is loaded dynamically to query window tags in a batch. Bit 60 indicates minimization; user-window markers and visible-window history distinguish user windows from invisible helpers. Hidden apps' normal-window markers also count at startup, before any visible-window history exists. Closed-window markers remain excluded; unknown states keep apps available.
- CoreGraphics supplies window bounds and display geometry. Being on another Space does not by itself mean a window is minimized.
- Window metadata refreshes approximately every 400 ms in the background. Ordering starts from window order and then follows app activations during the session.

Private APIs can change between macOS releases. Missing tags or unknown positions keep apps available. Only normal-layer windows of regular apps are considered; apps using floating main windows may need adaptation. Secure Input or other keyboard utilities can affect shortcut capture. Activation follows macOS app activation behavior.

See [validation](research/switcher-validation.md) for completed checks and outstanding physical-keyboard and multi-display verification. The archived [LaunchServices investigation](research/README.md), [injection prototype](research/dockless-prototype.md), and [copied-app trial](research/cmux-trial.md) are not used by the standalone app or included in its release bundle.

Window-tag research is credited to [Switcher](https://github.com/fad1/Switcher/blob/main/Sources/SwitcherKernels/MinimizedStateSpecs.md). The shortcut API is also referenced by [AltTab](https://github.com/lwouis/alt-tab-macos/blob/master/src/experimentations/PrivateApis.swift). Packaging was adapted from the macos-spm-app-packaging template.
