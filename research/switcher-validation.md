# Standalone switcher validation

Validation was performed on macOS 27, Apple Silicon. Session output, application inventories, process IDs, display names, and workstation paths are deliberately excluded from this document.

- SwiftPM: **39 tests passed**, covering partial/total minimization, restoration with stale tags, helper windows, closed-but-retained windows, unknown states, independent hidden/minimized filters, negative display coordinates, multi-display geometry, and live selection updates. New regressions cover hidden windows without visibility history, keyboard recovery failure and retry, and preview conversion for both keyboard directions and Command release using in-memory events.
- The same SwiftPM suite passed on a mounted **case-sensitive APFS** volume, verifying the exact lowercase test-target paths.
- Shortcut ownership regressions use file-backed fake shortcut states and real child processes. They cover both exit orders, denied ownership, guardian startup failure, unexpected guardian exit, and SIGKILL of a disposable owner. A delayed guardian verifies that another owner cannot acquire until fallback restoration finishes. No real system shortcuts are changed by these tests.
- Publication auditor: **10 tests passed** with synthetic index paths, empty ZIP directories, renamed and deleted historical paths sharing blobs, redacted error output, and content detection.
- Real own-window probe: **11 checks passed** for visible, partially minimized, fully minimized, minimized-filter-disabled, restored, hidden-filter-enabled, hidden-filter-disabled, unhidden, closed-window states, and cold-start hidden with one/all windows minimized. Hidden state was checked with `NSRunningApplication.current.isHidden`.
- SkyLight symbols and minimization tags were available. Visible-window history handles nonuniform user-window markers. Closed-but-retained NSWindows do not incorrectly keep minimized apps in the selector.
- The single-row panel, neutral highlight, selected-app label, English settings, and three independent checkboxes were inspected in the UI. Clicking a preview icon activated the target and closed the panel. Filter values were saved independently.
- Accessibility enabled the session event tap. Replacing an ad hoc signed build required removing and re-adding the current bundle; reopening the same build retained permission.
- `--native-status` reported both native shortcuts disabled while CmdTabo was active and enabled after pausing.
- A forced termination of the main process caused the temporary guardian to restore both native shortcuts and exit. Reopening CmdTabo disabled them again.
- Package signature, plist, archive and publication validation passed. The archived injection prototype's trial also passed with zero failures. Only the standalone app is included in release archives; the injection prototype is not loaded.

## Remaining runtime verification

Physical-keyboard confirmation of ⌘Tab, ⌘⇧Tab, release-to-activate, and Esc is pending. Computer-use synthetic key presses did not reach the global event tap and cannot substitute for that check.

Multi-display geometry is covered by unit tests; verification with a second physical display is pending. Compatibility outside the tested macOS version and architecture is unverified. The release is experimental and is not notarized.

Window tags can retain a hidden marker after closing a window while the app is hidden. Such ambiguous metadata remains eligible until it resolves; the cold-start policy favors keeping an app reachable. Ordinary closed-window markers and invisible helpers remain excluded.

The app does not change installed applications, Dock.app, SIP, or the symbolic-hotkey preferences file. Native shortcut changes are temporary and are restored when the app is paused, quits, or the main process is force-quit.
