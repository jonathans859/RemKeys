# Secrets setup (iOS TestFlight + macOS notarized release)

You add these under **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**.
Names must match exactly (the workflows read them by name).

## iOS TestFlight — needed by `release-apple.yml` (ios job)

| Secret | What it is | Where to get it |
|---|---|---|
| `ASC_KEY_ID` | Key ID of an App Store Connect API key | appstoreconnect.apple.com → **Users and Access → Integrations → App Store Connect API** → create a **Team key**, role **App Manager**. Shown in the key row. |
| `ASC_ISSUER_ID` | Issuer ID for that same API-key page | Same page, at the top ("Issuer ID"). One per team. |
| `ASC_KEY_P8` | The private key file contents | The `.p8` you download **once** when you create the key. Paste the whole file (including the `-----BEGIN/END PRIVATE KEY-----` lines). Apple only lets you download it once. |
| `APPLE_TEAM_ID` | Your 10-char Team ID | developer.apple.com → **Membership** (e.g. `A1B2C3D4E5`). |

## macOS Developer ID (notarized zip) — needed by `release-apple.yml` (mac job)

The Mac app is **not** TestFlight — it's Developer ID signed + notarized (see CLAUDE.md for why).
Notarization reuses `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8` above. Signing needs just two more:

| Secret | What it is | Where to get it |
|---|---|---|
| `DEVID_P12` | Your **Developer ID Application** certificate + private key, exported as a `.p12`, then base64-encoded | See steps below. |
| `DEVID_P12_PASSWORD` | The password you set when exporting the `.p12` | You choose it during export. |

**Exporting the `.p12`** (do this once, on your Mac):

1. In Xcode → Settings → Accounts → your team → **Manage Certificates**, make sure you have a **Developer ID Application** certificate (create one with `+` if not). This requires the cert's private key to be in your login keychain — so do this on the Mac that created the cert.
2. Open **Keychain Access** → login → My Certificates. Find **Developer ID Application: …**, expand it so you see the private key underneath, select **both** the cert and its key, right-click → **Export 2 items…** → save as `devid.p12`, set a password (that's `DEVID_P12_PASSWORD`).
3. Base64-encode it for the secret:
   - macOS: `base64 -i devid.p12 | pbcopy` (now paste into `DEVID_P12`).

No `match`, no certs repo — the mac lane imports this cert into a throwaway CI keychain at build time.

## Windows agent
No secrets. `release-windows.yml` just builds and attaches the zip.
