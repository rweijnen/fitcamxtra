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

Needed only for the TestFlight upload, which stays switched off until all
three are present:

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


## Getting a build onto your own iPhone

There is no way to install this IPA directly from Windows: it is signed with an
App Store profile, Apple Configurator is Mac-only, and iTunes for Windows no
longer installs IPA files. TestFlight is the route, and it works entirely from
a Windows machine.

1. **Create the app record.** At [App Store Connect](https://appstoreconnect.apple.com),
   go to Apps, click the plus button and choose New App. Platform iOS, pick the
   bundle id `nl.remkoweijnen.fitcamxtra`, give it a name and an SKU of your
   choosing. The name must be unique across the App Store.
2. **Create an API key.** Users and Access, then the Integrations tab, then
   App Store Connect API, then Team Keys. Generate a key with the App Manager
   role. The `.p8` file downloads **once and cannot be downloaded again**, so
   keep it with the rest of the signing material. Note the Key ID on the row and
   the Issuer ID shown above the table.
3. **Store the three secrets** listed above.
4. **Push to main.** The workflow archives, exports and uploads. Processing on
   Apple's side usually takes a few minutes.
5. **Install TestFlight** on the iPhone from the App Store and sign in with the
   same Apple ID. As the account holder you are already an internal tester, so
   add yourself to an internal testing group and the build appears. Internal
   builds skip App Review.

Each upload needs a build number no earlier upload used; CI takes it from the
workflow run number. Export compliance is answered in the Info.plist, so
TestFlight will not ask per build. Builds expire after 90 days.

### Testing against the camera

Joining the camera's own access point from inside the app needs the Hotspot
Configuration capability, which the App ID does not have yet, so that button is
disabled. It does not block testing: put the camera in AP mode, join its wifi
by hand in iOS Settings, and discovery finds it on that subnet. To enable the
in-app join later, add the capability to the App ID, regenerate the profile and
update `APPLE_PROVISIONING_PROFILE_BASE64`.
