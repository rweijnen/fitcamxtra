# Code signing for CI

The `iOS build` workflow signs the app with an Apple Distribution certificate and a
provisioning profile that are stored as **GitHub Actions secrets**. Nothing in this
list is ever committed; the `.gitignore` also blocks the usual file types
(`*.p12`, `*.mobileprovision`, `*.p8`, `.env`, `private/`).

## Secrets

| Secret | Contents |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | The distribution certificate + private key exported from Keychain as `.p12`, base64 encoded |
| `APPLE_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12` |
| `APPLE_PROVISIONING_PROFILE_BASE64` | The `.mobileprovision` for the app's bundle id, base64 encoded |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer team id |
| `KEYCHAIN_PASSWORD` | Any random string; used only for the temporary keychain on the runner |

Optional, only needed once TestFlight upload is enabled:

| Secret | Contents |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Key id of an App Store Connect API key |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer id shown on the API keys page |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | The `AuthKey_XXXX.p8` file, base64 encoded |

## Producing the values

On a Mac:

```sh
base64 -i Certificates.p12 | pbcopy           # -> APPLE_CERTIFICATE_P12_BASE64
base64 -i FitCamXtra.mobileprovision | pbcopy  # -> APPLE_PROVISIONING_PROFILE_BASE64
base64 -i AuthKey_XXXX.p8 | pbcopy            # -> APP_STORE_CONNECT_KEY_P8_BASE64
```

On Windows (PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("Certificates.p12")) | Set-Clipboard
```

Then add each value under *Settings > Secrets and variables > Actions* in the
repository, or with the CLI:

```sh
gh secret set APPLE_CERTIFICATE_P12_BASE64 < cert.b64
```

## How the workflow uses them

1. Decodes the certificate and profile into the runner's temp directory.
2. Creates a throwaway keychain protected by `KEYCHAIN_PASSWORD`, imports the
   certificate, and installs the profile under `~/Library/MobileDevice/Provisioning Profiles`.
3. Runs `xcodebuild archive` with manual signing, then `xcodebuild -exportArchive`.
4. Uploads the resulting `.ipa` as a workflow artifact.
5. Deletes the temporary keychain in an `always()` step so nothing survives the job.
