# Publishing signed updates

CmdTabo uses Sparkle 2.10.0, pinned in `Package.swift` and `Package.resolved`.
The public feed URL and public signing key are in `update-config.env`. GitHub Releases
hosts the ZIP; the signed `appcast.xml` on `main` is the discovery feed, including
experimental releases. This avoids GitHub’s `latest` endpoint excluding prereleases.

## Signing tools and key

There are two independent signing identities:

- `signing-config.env` pins the persistent **CmdTabo Local Signing** certificate
  used by `codesign`. Its private key and certificate stay in the login Keychain.
  This is a self-signed code identity, with no Apple Team ID or notarization.
- `update-config.env` pins the existing Sparkle Ed25519 public key. Keep that
  update key unchanged when migrating from ad hoc to local code signing.

The code certificate is valid until October 2036. Never recreate it just because
the certificate name is the same: TCC tracks the certificate, not its display name.
Back up the original identity securely using Keychain Access's encrypted identity
export. Keep that backup and its password outside Git and release assets. On a
new build Mac, restore the original identity rather than generating another one.
Neither packaging nor preflight creates keys or changes certificate trust.
Receiving Macs do not need to import or trust this certificate.

Run `bash scripts/check-signing-identity.sh` before packaging. It requires the
exact certificate and private identity. A Keychain prompt from `codesign` is for
using this local private key; authorize it directly in macOS. Choosing **Always
Allow** for `/usr/bin/codesign` avoids repeating this prompt for each nested helper.
Never enter a Keychain password into a shell command or chat.

Run `bash scripts/test-signing-continuity.sh` to compile two different executables
with the same bundle identity and certificate. It checks matching designated
requirements, cross-validates both builds and rejects ad hoc code, changed
identifiers and tampered bytes. `verify-code-signature.py` also checks every
nested code object's certificate, helper identifiers and effective flags.
The main app requirement pins both `local.cmdtabo.switcher` and the exact leaf
certificate. Nested bundles retain their own identifiers. Hardened runtime and
library validation remain disabled: the local certificate has no Apple Team ID.
This does not change Gatekeeper settings or certificate trust on the build Mac.

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
3. Run `bash scripts/package-release.sh`. It refuses ad hoc or unpinned signing,
   verifies nested signatures and certificate identity, creates
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
require macOS authorization. From v0.1.10 onward, releases use the persistent local
certificate and remain unnotarized. Ed25519 authenticates updates, but does not
replace Developer ID or notarization. Migrating from earlier ad hoc releases can
require renewing Accessibility once. Subsequent releases preserve the same
certificate, identifier and designated requirement so TCC can recognize the app
across code changes. Keep its installation path stable. Permission decisions
remain controlled by macOS; retention on the other physical Mac is not yet verified.
CmdTabo releases native shortcut ownership before an updater relaunch and during
normal termination, so installation does not leave the old capture active.
