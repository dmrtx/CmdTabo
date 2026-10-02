# Standalone switcher validation

Validation was performed on macOS 27, Apple Silicon. Session output, application inventories, process IDs, display names, and workstation paths are deliberately excluded from this document.

- SwiftPM: **24 tests passed**, covering partial/total minimization, restoration with stale tags, helper windows, closed-but-retained windows, unknown states, independent hidden/minimized filters, negative display coordinates, multi-display geometry, and live selection updates.
- Real own-window probe: **9 checks passed** for visible, partially minimized, fully minimized, minimized-filter-disabled, restored, hidden-filter-enabled, hidden-filter-disabled, unhidden, and closed-window states. Hidden state was checked with `NSRunningApplication.current.isHidden`.
- SkyLight symbols and minimization tags were available. Visible-window history handles nonuniform user-window markers. Closed-but-retained NSWindows do not incorrectly keep minimized apps in the selector.
- The single-row panel, neutral highlight, selected-app label, English settings, and three independent checkboxes were inspected in the UI. Clicking a preview icon activated the target and closed the panel. Filter values were saved independently.
- Accessibility enabled the session event tap. Replacing an ad hoc signed build required removing and re-adding the current bundle; reopening the same build retained permission.
- `--native-status` reported both native shortcuts disabled while CmdTabo was active and enabled after pausing.
- A forced termination of the main process caused the temporary guardian to restore both native shortcuts and exit. Reopening CmdTabo disabled them again.
- Package signature and plist validation passed. Only the standalone app is included in release archives; the injection prototype is not loaded.

## Remaining runtime verification

Physical-keyboard confirmation of ⌘Tab, ⌘⇧Tab, release-to-activate, and Esc is pending. Computer-use synthetic key presses did not reach the global event tap and cannot substitute for that check.

Multi-display geometry is covered by unit tests; verification with a second physical display is pending. Compatibility outside the tested macOS version and architecture is unverified. The initial release is experimental and is not notarized.

The app does not change installed applications, Dock.app, SIP, or the symbolic-hotkey preferences file. Native shortcut changes are temporary and are restored when the app is paused, quits, or the main process is force-quit.
