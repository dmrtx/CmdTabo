# Privacy and publication

## Runtime

CmdTabo reads running-app visibility and WindowServer metadata locally to filter its switcher. Accessibility is used to intercept the switcher shortcut. It contains no network client, analytics, update service, screen capture, window-title collection, or keystroke recorder.

The opt-in `--diagnose` command prints local app/display/window metadata. Runtime logs may contain process IDs. Those outputs remain local and are excluded from Git and release bundles.

## Publication boundary

Only reviewed source, tests, scripts, and documentation are committed. Build directories, trial app copies, diagnostic JSON, logs, caches, credentials, signing material, local configuration, and OS metadata are ignored.

Release archives contain only CmdTabo.app. Packaging remaps source paths, strips debug information, removes extended attributes, and omits source-map files, build caches, diagnostics, and copied third-party apps. Checksums cover the final ZIP bytes.

Before publication, the staged snapshot and reachable Git history are scanned for credentials and for personal paths, email addresses, network addresses, and machine identifiers in both contents and paths. Every historical tree is checked, including renamed files that reuse the same blob and deleted directories. Sensitive diagnostic paths are redacted. Commit metadata uses a GitHub handle and GitHub noreply address. Release contents are checked separately, including strings in the executable, plist metadata, file and directory names in the archive, and extended attributes.

```sh
python3 scripts/audit-publication.py --history
python3 scripts/audit-publication.py --history --archive build/releases/CmdTabo-0.1.1-macos-arm64.zip
```

A clean scan records what was checked and that no matching data was found; it is not a guarantee against every possible secret format. Review the exact staged files and release contents when publishing changes. Local audit reports are not published.
