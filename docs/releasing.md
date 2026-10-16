# Publishing signed updates

CmdTabo uses Sparkle 2.10.0, pinned in `Package.swift` and `Package.resolved`.
The public feed URL and public signing key are in `update-config.env`. GitHub Releases
hosts the ZIP; the signed `appcast.xml` on `main` is the discovery feed, including
experimental releases. This avoids GitHub’s `latest` endpoint excluding prereleases.

## Signing tools and key

Download `Sparkle-2.10.0.tar.xz` from the official
[Sparkle release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0).
Extract it outside the repository and set `SPARKLE_BIN` to its `bin` directory.
These tools are not in the SwiftPM framework artifact.

The existing Ed25519 key is stored in the maintainer’s login Keychain under the
account `CmdTabo`. Use that key for every release. `generate_keys --account CmdTabo -p`
prints only the public key for comparison with `SPARKLE_PUBLIC_KEY`. Do not generate
a replacement key or publish private key material. macOS may ask the maintainer
to authorize `generate_appcast` to use the signing key. Complete
that prompt directly in macOS; no password belongs in the repository or chat.
Back up the signing key securely according to
[Sparkle’s key-management instructions](https://sparkle-project.org/documentation/#3-segue-for-security-concerns).

## Build and publish order

1. Increase both fields in `version.env`; `BUILD_NUMBER` must increase monotonically.
2. If artwork changed, inspect its content and PNG metadata, update the reviewed
   SHA-256 in the publication auditor, and generate native icon sizes. Run Swift
   and Python tests, review changes, and merge the release source into
   `main`. Create the version tag using the public Git identity. Build only from a
   clean checkout so the app’s source metadata identifies the tagged commit.
3. Run `bash scripts/package-release.sh`. It verifies nested signatures, creates
   the ZIP and `SHA256SUMS.txt`, and scans publication contents and Git history.
4. Run `SPARKLE_BIN=/path/to/sparkle/bin bash scripts/make-appcast.sh`. It creates
   `build/releases/appcast.xml`, preserving up to three previous feed entries,
   signing the ZIP and feed with the Keychain key. The app requires both signatures
   and refuses to extract unsigned or tampered archives. Do not edit the feed
   after signing; regenerate it instead.
5. Verify signatures using `swift scripts/verify-update.swift FEED ZIP PUBLIC_KEY`.
   This uses only the public key and does not access the Keychain. Push `main` and the tag.
   Create a draft GitHub release with the ZIP, checksum file
   and signed appcast. Download its assets, verify checksums, feed signature,
   bundle metadata and `codesign --verify --deep --strict`, then publish the release.
6. Only after the release ZIP is publicly accessible, copy the exact signed feed
   to the repository’s `appcast.xml`, audit and commit that feed, then push `main`.
   This feed-only commit deliberately follows the tagged binary source commit.
   Check the raw public feed URL and its enclosure URL; both must return the
   published bytes. Never advertise an unavailable or draft asset.

Private signing keys, credentials, logs and local audit reports stay outside Git
and the release. Keep prior release assets accessible while their feed entries
remain published. The application and feed contain only public verification keys
and signatures.

## Installation behavior and limits

Default checks run approximately every six hours while CmdTabo is running;
Sparkle adjusts scheduling for sleep and connectivity. Automatic downloads prepare
installation on quit. Manual **Check for Updates…** can install and relaunch sooner.
Scheduled updates show a menu indicator without activating a window. Menu controls
persist the user’s automatic-check and automatic-download preferences.

The first updater-capable release must be installed once over an older release.
Updates replace the app at its existing location; a non-writable location can
require macOS authorization. CmdTabo releases remain ad hoc signed and unnotarized.
Ed25519 authenticates updates, but does not replace Developer ID or notarization.
macOS may require renewing Accessibility after the app’s code signature changes.
CmdTabo releases native shortcut ownership before an updater relaunch and during
normal termination, so installation does not leave the old capture active.
