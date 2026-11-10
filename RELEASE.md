# Build and TestFlight

The workflows follow [FanControlWatch](https://github.com/agawlbb/FanControlWatch)'s existing procedure, adapted to one iPad app with no Watch target or push capabilities.

- Apple team: `FKR675M7PM`
- Bundle identifier: `dev.makelora.app`
- Initial version: `0.1.0`
- Supported devices: iPad, both landscape orientations; iPadOS 17+

## One-time setup

Register this bundle identifier in Apple Developer → Certificates, Identifiers & Profiles → Identifiers. At [App Store Connect → Apps](https://appstoreconnect.apple.com/apps), choose **+ → New App** and use platform **iOS**, name **MakeLORA**, primary language **English (U.S.)**, bundle ID **dev.makelora.app**, and SKU **MakeLORA**. Apple requires its website for creating app records; API keys cannot perform this initial step. Give the intended tester access to this app. The release script creates a private internal group if needed and verifies that no other testers or public links can receive the build. Add the configured sole tester to that group through App Store Connect → TestFlight → Internal Testing. The API cannot perform this internal tester assignment. Builds may be uploaded while the group is empty; distribution verification waits for its intended tester. The tester must be an existing App Store Connect user with access to this app. Complete any outstanding Apple agreements.

Add these Actions secrets to MakeLORA, reusing the original private credentials used by FanControlWatch:

- `TESTFLIGHT_TESTER_EMAIL` — the sole intended tester; kept out of public source and logs
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY` — original `.p8` contents
- `IOS_DEVELOPMENT_CERT_P12` — base64-encoded existing certificate export with private key
- `IOS_DEVELOPMENT_CERT_PASSWORD`

Never commit these values or paste them into chat. GitHub secret values cannot be read back or copied directly between repositories. If the original files are unavailable, grant access to existing organization secrets where applicable, or have the credential owner supply the originals through GitHub's secret fields. Do not extract secrets through workflow logs or artifacts and do not revoke FanControl's working credentials.

The API key needs access to the new app, upload/TestFlight permissions, and the certificate/identifier/profile operations used by Xcode automatic signing. Existing signing material stays valid for FanControl. Provisioning for MakeLORA must use its own bundle identifier.

## Validation

`Validate iPad app` runs on pushes to main and feature/fix branches, pull requests, or manual dispatch. It uses a GitHub macOS 26 runner, runs `swift test`, generates the Xcode project, and runs application tests on an available iPad simulator. Validation has no Apple credentials and performs no upload.

## Signed build and upload

Run **TestFlight** manually with a positive, unused build number. Leave **Upload signed build to TestFlight** off to verify signing and retain an IPA for seven days. The workflow checks credential availability before starting a Mac and checks uploaded build numbers before archiving.

Enable upload only for an intended release. The workflow runs tests, archives, exports and verifies the distribution signature, uploads to Apple, waits for processing, and assigns/verifies the build in the existing internal group. Processing evidence is retained for seven days. It does not add testers or submit to the public App Store.

Temporary signing files and the runner keychain are removed at cleanup. If upload succeeds but processing verification fails, inspect App Store Connect before rerunning; the build number may already be used.

## Certificate package compatibility

A correct PKCS12 password can still produce macOS's “MAC verification failed” error when the package was exported with OpenSSL 3's default encryption. Re-export the existing certificate and private key using `PBE-SHA1-3DES` for both key and certificate encryption and `sha1` for the package MAC, then update `IOS_DEVELOPMENT_CERT_P12` with the new base64 package. Keep private files outside Git. This changes the package format only; do not create or revoke a certificate to solve this import error.

## Verify an existing upload

If upload succeeds but processing or group verification fails, rerun **TestFlight** with the same build number and **Verify an existing upload without building or uploading** enabled. This skips compilation, signing, the unused-build-number check and upload, and reports internal group membership counts without publishing tester emails. A populated private internal group for the sole intended tester takes precedence over an empty default group.
