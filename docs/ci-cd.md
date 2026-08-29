# CI/CD and distribution

## Workflows

- **`ci.yml`** — every push and PR: BridgeCore tests plus an unsigned macOS app
  build (one macOS job — jobs bill separately and macOS is 10×) and a Windows
  agent build on ubuntu (1× vs 2× on windows). No secrets.
  **No iOS build in CI on purpose**: `deploy-ios` compiles the same code against
  the real SDK on every push to main, so a simulator build was redundant billed
  minutes. Actions minutes are a real constraint here — don't add macOS jobs
  casually.
- **Continuous per-platform deploys**, path-filtered so each fires only when its
  own platform or a shared input (`BridgeCore/**`, `project.yml`, `fastlane/**`)
  changed. All three also fire on Release publish and attach their asset to the
  Release.
  - `deploy-ios.yml` — push to main → TestFlight upload (internal testers via a
    group with automatic distribution). Runs on `macos-26`: App Store Connect's
    SDK floor applies to uploads only, so `ci.yml` stays on the stabler
    `macos-15`.
  - `deploy-macos.yml` — push to main → Developer ID-signed, notarized zip as a
    run artifact (and a Release asset on release).
  - `deploy-windows.yml` — push to main → agent zip as a run artifact (and a
    Release asset on release). Stamps the agent version via `-p:Version=`.

## fastlane

Lanes: `ios ios_beta`, `mac mac_release` (`fastlane/Fastfile`).

Build number = `git rev-list --count HEAD` (needs `fetch-depth: 0`): monotonic on
main, recomputable from any checkout. Re-running a run whose upload already
succeeded fails as a duplicate build — push a new commit instead.

The mac lane signs **manually with Developer ID end-to-end**: the CI keychain has
no Apple Development cert, so automatic signing would find no identity for the
archive step. No profile is needed without sandbox or restricted entitlements.

## Signing notes

Secrets are GitHub Actions secrets, shared across the repos on this Apple account;
their names appear in the workflow files. Nothing about where key material lives
belongs in this repo.

- **One App Store Connect API key (role Admin) serves the whole account**, for both
  TestFlight upload and macOS notarization.
- **One cached Apple Development certificate is shared by every repo**, imported
  into the CI keychain by the `ios_beta` lane so Xcode cloud signing reuses it. It
  cannot be per-repo: Apple returns 409 when minting a second Development
  certificate while one is current, and the certificate identifies the *team*, not
  an app. Without the cache, every ephemeral runner minted a new certificate until
  the account hit Apple's cap and archiving failed with "Choose a certificate to
  revoke".
- **A revoked certificate fails invisibly.** A revoked `.p12` still imports
  cleanly, still satisfies `find-identity`, and the build still goes green — while
  cloud signing quietly mints a fresh certificate every run. If certificates start
  piling up again, suspect this first, and check with
  `asc certificates list --certificate-type DEVELOPMENT` after a build rather than
  trusting a green tick.
- **Any `.p12` destined for CI must be exported in legacy format**
  (`openssl pkcs12 -export … -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
  -macalg sha1`): macOS `security import` rejects OpenSSL 3's default encoding with
  "MAC verification failed (wrong password?)" even when the password is right, and
  `import_certificate` doesn't fail the run on it — so the lanes assert the
  identity is present right after import.
- The Windows release needs no secrets.

## Deviation from the original brief: macOS does not use TestFlight

The brief asked for TestFlight on both Apple platforms. **The macOS app installs a
`CGEventTap`, which requires it to run un-sandboxed, and macOS TestFlight / the Mac
App Store require App Sandbox.** The two are mutually exclusive, so the Mac app
ships as a **Developer ID-signed, notarized** build via GitHub Releases — the same
channel as the Windows agent. iOS is unaffected and still goes to TestFlight.
