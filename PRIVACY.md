# Privacy and publication

## Runtime

CmdTabo reads running-app visibility and WindowServer metadata locally to filter its switcher. Accessibility is used to intercept the switcher shortcut. A temporary child process checks only Accessibility trust when the main process reports it missing. It does not prompt, change permissions or read application data. It contains no analytics, screen capture, window-title collection, or keystroke recorder.

Sparkle 2.10.0 checks a signed update feed hosted at `raw.githubusercontent.com/dmrtx/CmdTabo/main/appcast.xml` approximately every six hours while running. By default it downloads newer signed archives from `github.com/dmrtx/CmdTabo/releases` and prepares installation on quit. Manual checking and immediate installation are available in the menu. Automatic checks and downloads have separate persistent menu controls. Downloads may redirect to GitHub asset-delivery hosts. Normal HTTPS requests disclose an IP address and an app/Sparkle version user-agent to GitHub; no health logs, keyboard counters, app/window inventories or system profile are uploaded. Sparkle system profiling is disabled. Update errors remain local.

The app pins a public Ed25519 key and requires signed feeds and archive verification before extraction. The private signing key stays in the maintainer’s login Keychain and is never bundled, committed or uploaded. The maintainer may see a native Keychain prompt while signing a release. End users do not need that signing key.

The opt-in `--diagnose` command prints local app/display/window metadata. Local rotating health logs in `~/Library/Logs/CmdTabo/` include process IDs, version/build/source state, OS version, sleep/wake and Secure Input transitions, capture failures, query timings and periodic health summaries. Keyboard diagnostics contain only aggregate event/shortcut counts and seconds since the last received event. A delivery monitor compares an aggregate hardware key-down counter with received key-down progress while capture owns the shortcuts; it logs a missing-delivery transition without the hardware counter value or key contents. It does not read individual key state. Logs do not include key values, app names, window titles or screenshots. App and guardian logs each retain approximately 2 MiB with owner-only file permissions. The menu can open their directory. Those outputs remain local and are excluded from Git and release bundles.

## Publication boundary

Only reviewed source, tests, scripts, and documentation are committed. Build directories, trial app copies, diagnostic JSON, logs, caches, credentials, signing material, local configuration, and OS metadata are ignored.

Release archives contain only CmdTabo.app, including Sparkle’s runtime framework and temporary updater helpers. Only safe, relative symlinks confined to that framework are permitted. Developer headers and modules are excluded. Packaging remaps source paths, strips debug information, removes extended attributes, and omits source-map files, build caches, diagnostics, and copied third-party apps. Checksums cover the final ZIP bytes.

Before publication, the staged snapshot and reachable Git history are scanned for credentials and for personal paths, email addresses, network addresses, and machine identifiers in both contents and paths. Every historical tree is checked, including renamed files that reuse the same blob and deleted directories. Raw commit headers, continued headers and embedded merge tags are inspected, including tags without a separate reference. Commit messages are also normalized to UTF-8 so older declared encodings do not bypass identity checks. Sensitive diagnostic paths are redacted. The auditor requires author, committer and tagger metadata to use a matching public GitHub handle and noreply address; full names and other email addresses fail the check. GitHub bot merge metadata is also permitted. All Git object reads disable local replacements. Release contents are checked separately, including strings in the executable, plist metadata, file and directory names in the archive, and extended attributes.

```sh
python3 scripts/audit-publication.py --history
python3 scripts/audit-publication.py --history --archive build/releases/CmdTabo-0.1.7-macos-arm64.zip
```

A clean scan records what was checked and that no matching data was found; it is not a guarantee against every possible secret format. Review the exact staged files and release contents when publishing changes. Local audit reports are not published.
