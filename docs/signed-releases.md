# Signing and releasing Converse

Converse uses its shell build scripts for direct distribution outside the Mac App Store. A release requires a Developer ID Application signature, hardened runtime, a secure timestamp, Apple notarization, and a stapled ticket. The scripts do not require an Xcode project.

## Set up a release Mac once

1. Create a certificate signing request in **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority**. Save it to disk on the Mac that will sign releases; the matching private key stays in that Mac's login Keychain.
2. As the Apple Developer Program's Account Holder, create a **Developer ID Application** certificate in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list). Choose **G2 Sub-CA** when asked, upload the request, download the certificate, and double-click it to install. Apple Development and Apple Distribution certificates do not replace Developer ID Application for this workflow.
3. Verify that `security find-identity -v -p codesigning` lists the Developer ID identity as valid. If the issuing intermediate is missing, obtain **Developer ID - G2** from [Apple PKI](https://www.apple.com/certificateauthority/) and install it with normal system trust settings. Do not override certificate trust to hide an invalid chain.
4. Create an app-specific password in your [Apple Account](https://account.apple.com/) and store notarization credentials interactively:

   ```sh
   xcrun notarytool store-credentials ConverseNotary
   ```

   Enter the Apple Account email, Developer Team ID, and app-specific password at the prompts. Credentials stay in Keychain. An App Store Connect API key is another supported authentication method; see Apple's workflow below.

Keep signing private keys, `.p12` exports, API keys, and passwords outside Git and chat. A certificate alone is not a signing identity: importing one created on another Mac also requires its matching private key, transferred securely as a password-protected `.p12`.

## Build, test, and release

```sh
CONVERSE_ARCHS='arm64 x86_64' ./build.sh
./test.sh
./release.sh --skip-build
```

`./release.sh` without arguments builds both architectures before the release checks. `--skip-build` uses the existing bundle and still verifies both architectures and the full signature. `CONVERSE_APP_OUTPUT=/path/to/Converse.app` selects a separate build/release bundle. Never rebuild, sign, or staple a running app; both scripts reject that target.

`build.sh` automatically uses the sole valid Developer ID Application identity. Set `CONVERSE_SIGN_IDENTITY` to a certificate SHA-1 or full name to choose among several identities. Machines without one can still use `./build.sh` for an ad-hoc local build; a release rejects that signature. Set `CONVERSE_SIGN_IDENTITY=-` to request an ad-hoc local build explicitly.

The release script:

1. Verifies Developer ID Application authority, hardened runtime, timestamp, signature integrity, and Apple Silicon plus Intel architectures.
2. Submits a temporary ZIP through `notarytool`, waits for acceptance, and saves the submission result and notary log under `.build/release/`. `CONVERSE_NOTARY_PROFILE` overrides the default `ConverseNotary` Keychain profile. If an unchanged bundle already has a valid stapled ticket, it reuses that ticket.
3. Staples and validates the ticket and requires `spctl --assess --type execute` to succeed.
4. Copies the app into a fresh package with README and license, verifies the copied signature and ticket, then creates `Converse-<version>-macOS-universal.zip` plus its SHA-256 file. Notary logs and credentials are not included in the download.

Review the notary log even when accepted. Before publishing, extract the final ZIP and verify the extracted app's signature and stapled ticket. Download the published ZIP through a browser on a second Mac and test first launch with normal Gatekeeper settings. Test an upgrade without replacing a running app, retaining conversations, drafts, login bindings, and paired-device identity. Intel and older supported macOS versions require separate hardware/OS testing; a universal build alone does not prove that coverage.

Publish only the verified ZIP and checksum. Building and publishing do not update installed copies: use `install.sh` for that separate step, wait for `INSTALLED`, and verify the destination version and Dock shortcut. Never include local user data in a release.

## Frequency

Sign each build that will run under the stable development identity. Notarize each new distributed build; local iteration does not need notarization. An unchanged signed, notarized artifact can be downloaded repeatedly without repeating either operation. Reuse the certificate until renewal is needed, and retain the app's bundle ID and signing team across updates to preserve its code identity.

The first transition from ad-hoc signing can prompt again for privacy permissions or Keychain access. Subsequent correctly signed versions provide a stable identity; do not promise that all macOS permission prompts disappear.

## Apple references

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Choose the current Developer ID intermediary](https://developer.apple.com/help/account/certificates/replace-developer-id-certificates)
- [Notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Command-line notarization and stapling](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Code identity and privacy permissions](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
