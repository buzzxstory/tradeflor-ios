# TRADEFLOR for iPhone (native Swift)

SwiftUI app, iOS 16+, same server as the website (`https://app.tradeflor.com/api`, set by `TF_API_BASE` in `project.yml`).

No Mac is needed to work on it:

- `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. The `.xcodeproj` is generated on CI and is not committed.
- `.github/workflows/ios.yml` runs on a GitHub macOS runner (needs the repo on GitHub, private):
  - **simulator** job: build, unit tests, boot an iPhone simulator, install, launch, screenshots → artifact `screenshots`.
  - **device-ipa** job: unsigned Release build → artifact `Tradeflor-unsigned-ipa`.

## Signed-in screenshots on CI

Create a **test** account on app.tradeflor.com (not a real one), then add two repository secrets:
`TF_CI_USERNAME` and `TF_CI_PASSWORD`. The Debug simulator build reads them from the launch environment and signs in.
That hook is `#if DEBUG` only; the IPA job fails if it ever appears in the Release binary.

## Installing on an iPhone without a developer account

1. Download `Tradeflor-unsigned-ipa` from the workflow run and unzip it to get `Tradeflor-unsigned.ipa`.
2. Open it with Sideloadly (or AltStore) on Windows and sign in there with **your own** Apple ID.
3. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID. On iOS 16+ also turn on Developer Mode.
4. A free Apple ID app expires after 7 days: sideload it again. There is no push notification without a paid account.

## Layout

```
Tradeflor/App        app entry, root view, theme
Tradeflor/Core       API client, models, Keychain, session store
Tradeflor/Features   Login, Chats
Tradeflor/Resources  assets, en/ar strings (InfoPlist.strings = permission texts)
TradeflorTests       unit tests
```
