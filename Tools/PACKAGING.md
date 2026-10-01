# Packaging ArtemisMac

## Making the DMG

```sh
Tools/make-dmg.sh
```

- **What it does:** builds Release into `~/Desktop/ClaudeScratch/DerivedData-dmg.noindex` and writes `~/Desktop/ClaudeScratch/dist/ArtemisMac-<version>-<build>-<commit>.dmg`, plus a `.sha256` file.
- **What's in the DMG:** `ArtemisMac.app` and a link to `/Applications`. The volume is HFS+, compressed with LZFSE (`ULFO`).
- **Checks before packaging:** the bundle ID is `com.sforkoak.artemis.mac`; the build is arm64 only; the AWDL helper and its launchd plist are present; and the app, the helper and the frameworks are all signed by team `CHD882B8G5` with the hardened runtime.
- **Checks after packaging:** the image verifies; the app inside it passes `codesign --verify --deep --strict` and has the same CDHash as the build.
- **Leaving no trace:** the build is unregistered from LaunchServices so it can't take over `art://` links. Nothing is installed.
  - The `.noindex` suffix matters. Outside one, the build was registered again within ~6 s of `lsregister -u`, probably via Spotlight indexing it. Inside one, it stayed unregistered.
- **Options:** `--skip-build` packages the existing build; `--clean` does a clean build; `--derived-data DIR` and `--out DIR` change the paths. `ARTEMIS_SCRATCH` moves the scratch root.
- **Uncommitted changes:** a working tree with uncommitted changes gives a `-dirty` name.

## Signing today, and what Gatekeeper does

The app is signed with **Apple Development: sforkevo@gmail.com**, team `CHD882B8G5`. That team is a free *Personal Team*: its provisioning profiles expire 7 days after they're made. The certificate is valid until 2027-09-09.

| | Now | Needed for notarization |
|---|---|---|
| Certificate | Apple Development | Developer ID Application |
| Hardened runtime | on everywhere | on everywhere |
| Secure timestamp | none (the helper is signed with `--timestamp=none`; Xcode omits one for Development) | required on every binary |
| `get-task-allow` entitlement | `true` (Xcode adds it for Development signing) | must be absent |
| Embedded provisioning profile | none, so no device list or 7-day expiry | none needed |

`spctl --assess` gives **rejected** for the app (`origin=Apple Development: …`). So the DMG is left unsigned: a Development signature on it would be rejected too, and would add a second Gatekeeper block on another Mac. The script signs the DMG automatically once the app is Developer ID signed.

**On this Mac:** the DMG is made locally, so it has no quarantine flag. An app copied from it into `/Applications` opens with no Gatekeeper prompt, the same as the test copy.

**On another Mac**, or if the DMG reaches you by download, AirDrop, Messages or Mail, it's quarantined:
- The DMG mounts. The first time you open the app, macOS 15 and later show **"ArtemisMac" Not Opened** with *"Apple could not verify "ArtemisMac" is free of malware that may harm your Mac or compromise your privacy."* The only buttons are **Done** and **Move to Trash**. Control-click › Open no longer bypasses this, as of macOS 15.
- **To run it anyway:**
  1. Go to System Settings › Privacy & Security.
  2. Under Security, find *"ArtemisMac" was blocked…* and click **Open Anyway**. It asks for an admin password, and it's only offered for about an hour after the blocked attempt.
  3. Open the app again and confirm.
- **Or, before the first launch:** `xattr -dr com.apple.quarantine /Applications/ArtemisMac.app`.
- **The AWDL helper** still needs its own one-time approval in Login Items on that Mac.

This hasn't been tried on a second Mac. The dialog text is the macOS 15 wording, and macOS 26 may phrase it slightly differently.

## What notarization would need

1. **A paid Apple Developer Program membership** (individual, US$99/year). A Personal Team can't create Developer ID certificates or use the notary service.
   - After you enroll, check the team ID in Xcode › Settings › Accounts. If it isn't `CHD882B8G5`, change it in four places: `DEVELOPMENT_TEAM`; `kHelperRequirement` in `Limelight/Network/AWDLController.m`; `kClientRequirement` in `Limelight/AWDLHelper/main.m`; and `TEAM_ID` in `Tools/make-dmg.sh`.
   - The helper will then need approving again in Login Items. If the team ID stays the same, the existing requirements (`anchor apple generic` plus the team's OU) already accept Developer ID.
2. **A Developer ID Application certificate.** Make it in Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application; only the Account Holder can.
3. **Notary credentials, stored once in the keychain:**
   ```sh
   xcrun notarytool store-credentials artemismac-notary --apple-id <apple-id> --team-id <team>
   ```
   It asks for an app-specific password, made at account.apple.com › Sign-In and Security.
4. **Build changes for Release:**
   - Sign with `Developer ID Application`, manual style, and `OTHER_CODE_SIGN_FLAGS = --timestamp`.
   - In the "Build AWDL Helper" phase, change `--timestamp=none` to `--timestamp`.
   - Developer ID signing doesn't add `get-task-allow`. Check with `codesign -d --entitlements - ArtemisMac.app`.
5. **Package, notarize and staple:**
   ```sh
   Tools/make-dmg.sh   # signs the DMG with Developer ID + timestamp
   xcrun notarytool submit dist/ArtemisMac-….dmg --keychain-profile artemismac-notary --wait
   xcrun stapler staple dist/ArtemisMac-….dmg
   spctl -a -vv -t open --context context:primary-signature dist/ArtemisMac-….dmg   # accepted, Notarized Developer ID
   ```
   If the submission is rejected, `xcrun notarytool log <id> --keychain-profile artemismac-notary` says why.
   - The ticket covers the app inside the DMG. The first launch fetches it online, unless the app is notarized and stapled on its own before packaging.
   - Afterwards, another Mac shows the usual *"ArtemisMac" is an app downloaded from the Internet* prompt, with an **Open** button.

## Moving from the test copy to /Applications

### How the helper finds the app
launchd doesn't record the helper's path. `launchctl print system/com.sforkoak.artemis.awdl-helper` shows only:
- `program identifier = Contents/MacOS/ArtemisAWDLHelper (mode: 2)`
- `parent bundle identifier = com.sforkoak.artemis.mac`
- a `BTM uuid`

Before each launch of the helper, launchd asks backgroundtaskmanagementd (BTM) for that item, to find the app's location.

BTM keeps **one** app record per bundle ID. Any SMAppService call from a copy at a different path, even a plain `status` query, moves that record to the new path. The helper item keeps the same UUID and the same approval state, because the approval belongs to the bundle ID and team, not the path.

This was seen on 2026-10-01 at 04:42, when the test copy moved from `Test/Artemis.app` to `Test/ArtemisMac.app`:
```
_bundleURLForAuditToken: updating item … url=…/Test/Artemis.app/ URL to: …/Test/ArtemisMac.app/
registerLaunchItem: found existing item: uuid=654B3130-…, name=ArtemisAWDLHelper, …
```
The same item, `654B3130-…`, is what launchd runs today.

BTM also stores a SHA-256 of the helper's launchd plist. Rebuilding doesn't change it, but editing `com.sforkoak.artemis.awdl-helper.plist` does. It changed once on 2026-09-30, while the helper wasn't approved yet, so it's unknown whether a change would ask for approval again. Expect it might.

### What this means for the move
- **Re-approval:** shouldn't be needed. When ArtemisMac starts with "Disable AWDL" on, it queries the helper's status before connecting to it, which moves the record to `/Applications`.
  - Not yet verified live: at 04:42 the helper wasn't approved yet, so the log shows the state carried over, but not specifically an *approved* item surviving a move.
- **Don't run `--unregister-awdl-helper` on the test copy.** There's only one registration, shared by both copies.
  - Before the move: it throws away the approval, and you'd approve again.
  - After the move: it disables the helper for the `/Applications` copy too.
  - Keep it for uninstalling.
- **Two copies are fine.** Whichever copy last started with the switch on owns the helper. If BTM still points at a deleted copy, the helper can't start, but the next launch of the remaining copy fixes it.
- **Login Items** may still list the item as "Artemis", the name it was first registered under.

### Steps
1. `Tools/make-dmg.sh`
2. Quit the test copy (AWDL is restored when it quits):
   ```sh
   osascript -e 'tell application id "com.sforkoak.artemis.mac" to quit'
   ```
3. Open the DMG and drag **ArtemisMac** onto **Applications**. It sits next to `Artemis.app` (Artemis Qt), which stays untouched.
4. Make the `/Applications` copy the `art://` handler:
   ```sh
   LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
   $LSREG -u ~/Desktop/ClaudeScratch/Test/ArtemisMac.app
   $LSREG -f /Applications/ArtemisMac.app
   ```
5. Open `/Applications/ArtemisMac.app`. With "Disable AWDL" on, the bar should show AWDL off within a couple of seconds, with no Login Items prompt.
   - If it asks for approval anyway, allow ArtemisMac in System Settings › General › Login Items & Extensions › Allow in the Background.
6. **Check:**
   - `launchctl print system/com.sforkoak.artemis.awdl-helper | grep 'BTM uuid'` still shows `654B3130-…`.
   - While the app is open, `ifconfig awdl0 | head -1` shows no `UP`, and after quitting it shows `UP`.
7. Delete the test copy or keep it. If you keep it, launching it moves the helper back to it, which is harmless.

**If the helper won't start:**
1. From the copy you're keeping, run `ArtemisMac.app/Contents/MacOS/ArtemisMac --unregister-awdl-helper`.
2. Open the app, turn the switch off and on, and approve again in Login Items.

`sfltool resetbtm` would also clear it, but it resets every app's background-item approvals and needs a restart. Avoid it.

**Uninstalling:** turn the switch off, quit, run `/Applications/ArtemisMac.app/Contents/MacOS/ArtemisMac --unregister-awdl-helper`, then delete the app. Its data is in `~/Library/Application Support/Artemis`.
