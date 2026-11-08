# AirDox

AirDox is a native macOS app (Swift, AppKit + SwiftUI) that mirrors and controls an Android phone. It is modelled on Apple's iPhone Mirroring.

## Features

### Window and display
- A phone-shaped window with rounded corners. Hover over it to show a toolbar:
  - traffic lights
  - **Screens**: show the phone on both screens, or on the Mac only with the phone's own display off (⇧⌘P)
  - **Rotate**: switch between portrait and landscape (⌘R). The phone turns 90° in place instead of the window reshaping.
  - **Back**, **Home**, **App Switcher**
- Video is hardware-decoded H.264 at up to 60 fps, using VideoToolbox through `AVSampleBufferDisplayLayer`.
- **Phone audio plays on the Mac** (Android 11+).

### Wireless by default
- The first time the phone is plugged in over USB, AirDox switches it to Wi-Fi and mirrors over Wi-Fi, so you can unplug the cable.
- Later launches reconnect without a cable, and dropped connections are reconnected quietly.
- After the phone **reboots**, plug it in once more, or pair under Connection › Connect Wirelessly…

### Input
- Click or drag to tap and swipe. Double-tap and long-press work.
- Scroll with a trackpad or mouse wheel.
- Two-finger trackpad swipes become finger drags:
  - Start near the left or right edge to go **Back**.
  - Swipe up from the bottom to go **Home**. Swipe up and hold for the app switcher.
  - Swipe down from the top for notifications.
- Pinch on the trackpad to zoom.
- Right-click is Back, middle-click is Home.
- Type with the full keyboard. Esc is Back.

### Mac keys on the phone
These keys go to the phone while the AirDox window is in front:

| Mac key | On the phone |
|---|---|
| Volume up/down, mute | Phone volume and mute |
| Brightness up/down | Phone brightness |
| F7 / F8 / F9 | Previous / Play-Pause / Next |
| F3 | App switcher |
| F4 | Search: the open app's search box if it has one, otherwise the phone's search |
| F5 | Voice assistant |
| ⌥⌘D | Do Not Disturb on/off |

This needs a one-time permission in System Settings › Privacy & Security › Accessibility ("Device Control and Data Access" on newer macOS).

### Lock screen
When the phone locks, its own screen turns on so you can unlock it with its fingerprint sensor. You can also type the PIN from the Mac. After unlocking, the phone screen follows the Screens setting again.

### Protected screens
When an app shows a secure screen (GPay, banking, PIN entry), AirDox shows a "Continue on your phone" notice and turns the phone's screen on. Android hides secure screens from all screen capture by design.

### Clipboard, files and other shortcuts
- **Clipboard:** ⌘C / ⌘X copy from the phone to the Mac, and ⌘V pastes from the Mac to the phone.
- **Files:** drag a file onto the phone to save it to Downloads. Drag an `.apk` to install it.
- **Shortcuts:**

  | Shortcut | Action |
  |---|---|
  | ⌘1 | Home |
  | ⌘2 | App Switcher |
  | ⌘3 | Notifications |
  | ⌘4 | Quick Settings |
  | ⌘[ | Back |
  | ⌘L | Lock |
  | ⇧⌘S | Screenshot to Desktop |
  | ⌘+ / ⌘0 / ⌘− | Window size |

## Phone setup (one time)
1. Settings › About phone › tap **Build number** 7 times.
2. Settings › Developer options › turn on **USB debugging**.
   - On Xiaomi / HyperOS, also turn on **USB debugging (Security settings)**.
3. Plug the phone in and tap **Allow** on the prompt. Tick **Always allow**.

Developer options are required. AirDox controls the phone through Android's debugging interface (adb).

## Build
```bash
brew install --cask android-platform-tools
```
```bash
brew install scrcpy
```
```bash
./scripts/build_app.sh
```
This builds `build/AirDox.app`. The script copies `adb` and the scrcpy server into the app bundle.

The app is signed with a self-signed identity kept in `.signing/`, a project-local keychain. This folder is git-ignored and is not your login keychain. Because the identity stays the same, the Accessibility permission survives rebuilds.

## Known limitations
- **Banking and payment apps:** their protected screens can't be mirrored. Finish those steps on the phone.
- **Resolution:** some phone encoders can't stream at full resolution. The server then drops to a lower one automatically.
- **Screen staying on:** some ROMs, such as HyperOS, turn the phone screen back on when input arrives. AirDox keeps switching it off again while in "Mac only" mode.

## How it works
AirDox copies the open-source [scrcpy](https://github.com/Genymobile/scrcpy) server (Apache-2.0) to the phone and starts it there. It then talks to the server over an `adb forward` tunnel using scrcpy's v5.0.1 wire protocol.

The protocol client, video pipeline, audio, input and UI are all written in Swift. AirDox does not run the scrcpy desktop program.

Code layout:
- `Sources/AirDox/Protocol`: the wire format
- `Device`: adb, the mirroring session, search, and secure-screen detection
- `Media`: video and audio
- `Input`: Mac keys and Now Playing
- `UI`: windows and views
- `App`: app state and menus
