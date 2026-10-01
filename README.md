# Artemis for macOS

A native AppKit client for [Apollo](https://github.com/ClassicOldSong/Apollo) and Sunshine hosts, built for the lowest latency possible on Apple Silicon Macs. It brings the Apollo features of [Artemis Android](https://github.com/ClassicOldSong/moonlight-android) to the Mac, on top of [Moonlight for macOS](https://github.com/MichaelMKenny/moonlight-macos).

Requires macOS 26 and an Apple Silicon Mac. AV1 needs an M3 or newer.

## Apollo features

- **Virtual display**: launch apps in an Apollo virtual display sized to this Mac (per app from the app's right-click menu, or by default in Settings › Apollo), with a scale slider.
- **OTP pairing**: right-click a host › *Pair with OTP…* and enter the PIN and passphrase from Apollo's web UI. Nothing has to be typed on the host.
- **Clipboard sync** (text): sent to the host when the stream window becomes active, fetched when you switch away. *Apollo › Send/Get Clipboard* (Ctrl-Opt-Cmd-V / C) do it by hand.
- **Server commands**: the host's commands are listed under *Apollo › Server Commands* while streaming.
- **Permissions**: right-click a paired host › *Apollo Permissions…* shows what the host allows this Mac to do.
- Real per-install client identity and device name, and launching apps by UUID.

## Latency

- **Video**: frames go straight from the network thread into a hardware-only VideoToolbox decoder, and each decoded frame is drawn into a `CAMetalLayer` the moment it's ready. A single "latest frame" slot means nothing ever queues up behind the display. *Smoothest Video* switches to `CAMetalDisplayLink` pacing instead.
- **Codecs**: Automatic picks AV1, then HEVC, then H.264, whichever the host and this Mac decode in hardware. Reference frame invalidation (HEVC/AV1) repairs Wi-Fi packet loss without a full keyframe.
- **Frame rate multiplier**: the host encodes at 2× or 4× the frame rate while its display keeps the base rate (Artemis's "warp"), which smooths out stutter.
- **Audio**: a HAL AudioUnit with a 5 ms device buffer and at most 30 ms queued, so audio can't drift behind the video.
- **Mouse**: raw, unaccelerated GameController input handled off the main thread, with sub-pixel precision.
- **System**: Game Mode in fullscreen, a latency-critical process activity while streaming, and user-interactive scheduling for the streaming threads.
- **Wi-Fi**: a 20 ms keepalive (Apollo) keeps the radio out of power save. **Disable AWDL while Artemis is open** (at the bottom of the host list) stops the AirDrop/Handoff link from making the radio hop channels. See below.
- **Resolution**: *Match Display* streams at this Mac's fullscreen size below the notch, in panel pixels.
- **Measuring**: Ctrl-Opt-Cmd-S shows host encode, network, decode and on-screen latency. A summary is also logged every 5 seconds:
  ```sh
  /usr/bin/log stream --predicate 'subsystem == "com.sforkoak.artemis"'
  ```

### Disable AWDL

AWDL (`awdl0`) is the peer-to-peer Wi-Fi link behind AirDrop, Handoff, Universal Control, Sidecar and AirPlay to the Mac. It makes the Wi-Fi radio hop channels, which shows up as periodic latency spikes while streaming.

Turning AWDL off needs root, so Artemis bundles a small privileged helper (`ArtemisAWDLHelper`), registered with `SMAppService`.
- **First use**: the first time you turn the switch on, macOS asks you to allow Artemis in **System Settings › General › Login Items › Allow in the Background**.
- **What it can do**: the helper only keeps `awdl0` down while Artemis asks it to, and puts it back down when macOS brings it up again.
- **Who can use it**: it only accepts connections from Artemis signed by the same team.
- **Always restored**: when Artemis quits or crashes, the helper restores AWDL.

To remove the helper: `Artemis.app/Contents/MacOS/Artemis --unregister-awdl-helper`.

Because a sandboxed app can only register sandboxed helpers, Artemis doesn't use the App Sandbox. Its data lives in `~/Library/Application Support/Artemis`.

## Shortcuts

- **Release the mouse**: Control-Option
- **Performance stats**: Control-Option-Command-S
- **Disconnect, leaving the app running**: Control-Option-W
- **Disconnect and quit the app**: Control-Shift-W

## Building

1. Clone with submodules:
   ```sh
   git clone --recursive -b artemis https://github.com/SforkOak/ArtemisMac.git
   ```
2. Download [moonlight-apple-xcframeworks.zip](https://github.com/coofdy/moonlight-mobile-deps/releases/download/latest/moonlight-apple-xcframeworks.zip) and unzip the `.xcframework`s into `xcframeworks/`.
3. Open `Moonlight.xcodeproj`. Under *Signing & Capabilities*, set your team and bundle identifier.
   - If you change either, update the code-signing requirements in `Limelight/AWDLHelper/main.m` and `Limelight/Network/AWDLController.m`, and `AssociatedBundleIdentifiers` in the helper's plist.
4. Build the *Moonlight for macOS* scheme. Shaders are compiled at runtime, so Xcode's optional Metal toolchain isn't needed.

Unit tests for the plain-C video code: `Tests/run-tests.sh`.

`moonlight-common-c` comes from [SforkOak/moonlight-common-c](https://github.com/SforkOak/moonlight-common-c/tree/apollo) (`apollo` branch). It's upstream plus ClassicOldSong's Apollo control-stream extensions (server commands and the Wi-Fi keepalive).

## Acknowledgements

- [Moonlight for macOS](https://github.com/MichaelMKenny/moonlight-macos) by Michael Kenny, the AppKit client this is built on. It in turn is a fork of [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) by the [Moonlight Stream](https://github.com/moonlight-stream) team.
- [Artemis](https://github.com/ClassicOldSong/moonlight-android) and [Apollo](https://github.com/ClassicOldSong/Apollo) by ClassicOldSong, for the protocol extensions and features.
- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt), whose VideoToolbox/Metal renderer informed the presenter design.
- [MASPreferences](https://github.com/shpakovski/MASPreferences) and [Functional](https://github.com/leuchtetgruen/Functional.m).

Licensed under the GPL v3, like the projects it builds on.
