# Wind Waker HD Recompiled for iOS (kid with sister HD iOS port)

**The Legend of Zelda: The Wind Waker HD**, running natively on iPhone and iPad.
This is a static recompilation of the Wii U game: its PowerPC code is turned into native ARM64 code,
and its graphics run on Metal. It is **not an emulator**.

This is the iOS port of [WindWakerHD-Android-Plus](https://github.com/Nycolazs/WindWakerHD-Android-Plus).
It uses the project's macOS Metal renderer inside an iPhone app, with the Android app's touch
controls.

> **You need your own copy of the game, and a Mac.** iOS doesn't let an app compile code while it
> runs, so the game code is recompiled on your Mac from your own disc dump and built into the app.
> **The app you build contains that game code: install it on your own devices only, never share
> it.** This repository has no game code, no game files and no keys, and no IPAs are published.

---

## Contents

- [Requirements](#requirements)
- [Building the app](#building-the-app)
- [Installing](#installing)
- [How to play](#how-to-play)
- [The ≡ menu](#the--menu)
- [Differences from Android](#differences-from-android)
- [Troubleshooting](#troubleshooting)
- [For developers](#for-developers)
- [Credits](#credits)
- [Legal notice](#legal-notice)

---

## Requirements

**To build**
- A Mac with Xcode (iOS SDK 16 or newer), CMake 3.20+ and Python 3 (`pip3 install pycryptodome`
  to extract a disc image)
- Your own The Wind Waker HD for Wii U, **USA** release (title ID `0005000010143500`), as either:
  - a disc image, `.wux` or `.wud`, with its disc key (`.key`, named like the image) and the Wii U
    common key (`common.key`), both dumped from your own console, or
  - an extracted game folder with `code/`, `content/` and `meta/` inside
- About 5 GB of free disk space

**To play**
- An iPhone or iPad with an A12 chip or newer (iPhone XS / XR and later), iOS 16 or newer
- A way to install your own apps: LiveContainer, SideStore / AltStore, TrollStore, or a paid
  Apple developer account
- A game controller is optional: touch controls are built in

---

## Building the app

```sh
git clone https://github.com/cheemu21/kid-with-sister-hd-ios-port
cd kid-with-sister-hd-ios-port

# from a disc image (game.key next to it, common.key next to it or in the current folder)
tools/ios/build-ipa.sh --image path/to/game.wux

# or from an extracted game
tools/ios/build-ipa.sh --game path/to/game
```

The result is `build/ios/WindWakerHD.ipa` (about 1.4 GB, the game files included). The first build
extracts the disc and recompiles the game code, which takes a few minutes. Later builds reuse that
work.

| Option | |
|---|---|
| `--no-content` | Leave the game files out (an IPA of about 25 MB). Copy the game folder into the app afterwards (see [Installing](#installing)). |
| `-o FILE` | Where to write the IPA |
| `--cpu apple-a14` | Build the game code for a newer chip (default `apple-a12`) |
| `--env FILE` | Bake `WWHD_*` switches into the app (as an `env.txt`) |
| `--bundle-id ID`, `--version V` | The app's identifier and version |
| `--sim` | Build for the iOS Simulator instead |

---

## Installing

Install the IPA with your sideloading tool. It is signed ad hoc, and the tool signs it again with
your certificate.

**With the game files inside** (the default build): open the app and play.

**Built with `--no-content`**: open the app once, then copy your extracted game folder into the
app's folder, named `game` and with `code/`, `content/` and `meta/` inside:
- Files app: **On My iPhone > Wind Waker HD**
- in **LiveContainer**: Files app > On My iPhone > LiveContainer > Data > Application > the
  folder that has `log.txt` and `save` in it
- or Finder on a Mac: your iPhone > Files > Wind Waker HD

Then open the app again. A `game` folder there takes precedence over game files inside the app.

The app's folder also holds your saves (`save/`), this run's log and the previous one's
(`log.txt`, `log-prev.txt`), crash logs (`captures/`) and an optional `env.txt` of `KEY=VALUE`
switches.

---

## How to play

### Touch controls

The Android app's touch controls, with its artwork:

- **Moving**: the left side of the screen is a floating stick that starts where your thumb lands.
- **Camera**: swipe on the right side, double tap to centre it behind Link, and pinch to zoom.
  There is also a fixed camera stick.
- **Context buttons**: A, B, ZR and the X / Y / R item slots show what they do in the game. The
  D-pad items (Wind Waker, cannon, salvage hook) appear once Link has them.
- **Combat buttons**: the orange buttons are one-touch moves (jump attack, vertical slash, spin
  attack, dodge). They show once Link has a sword.
- **Scenes**: during scenes you can skip, a **Skip** button appears and a tap anywhere else is A.
- **≡ and ✎**: the menu and the layout editor sit at the bottom centre. They fade after 5 seconds,
  and the first touch on them brings them back.

### Layout editor (✎)

- **Moving and resizing**: drag a control to move it (it snaps to a grid). Drag its corner handle
  or pinch it to resize.
- **Removing**: 🗑 removes the selected control, and **+** puts removed ones back.
- **Finishing**: ↺ restores the default layout, ✕ cancels and ✓ saves.

### GamePad screen

The Wii U GamePad's screen can be an inset at the top, full screen, or hidden (≡ > GamePad
screen). Touching it works like the GamePad's touch screen (the map, the items, the Tingle Tuner).
In full-screen mode only A, B and pause stay on screen.

### Controllers

Any MFi, Xbox, PlayStation or Switch controller works. Buttons are mapped by position (Xbox "A" =
Wii U B). While a controller is connected, the touch controls hide except ≡ and ✎
(`WWHD_TOUCH_ALWAYS=1` in `env.txt` keeps them all).

---

## The ≡ menu

The game pauses while the menu is open. Every setting is remembered.

| Setting | |
|---|---|
| GamePad screen | Inset, full screen or hidden |
| Edit layout | The ✎ layout editor |
| Button size, Opacity | The touch controls' size and opacity |
| Camera speed, Camera stick | How fast swipes turn the camera; the fixed camera stick on or off |
| Combat buttons | Auto (once Link has a sword), always or never |
| Performance overlay | Frame rate, frame time and the longest frame, GPU time, memory and the phone's thermal state, at the top left |
| Apple Metal HUD | Apple's own overlay. iOS shows it only with Developer Mode on (Settings > Privacy & Security), and after the app is reopened |
| Vibration | Haptic feedback on button presses |

---

## Differences from Android

The iOS app uses the project's Metal renderer (from the macOS version), not the Android app's
Vulkan one. That means:

- **Frame rate**: the game runs at its own 30 fps. The Android app's generated 60 fps isn't ported
  yet.
- **Screen shape**: the picture is 16:9, so there's no wider-than-16:9 view or HUD editor.
- **Lens flare**: the sun's lens flare (depth peeks) isn't there.
- **Settings**: the ≡ menu has the touch, display and overlay settings only. The Android app's
  graphics settings, mods menu, translations and save tools aren't ported.
- **Game version**: only the **USA** release works. The Europe and Japan game code addresses exist
  only for the Android app's on-device recompiler.
- **Icons**: the touch icons are the app's bundled artwork. The Android app can rebuild them from
  the game's own art.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "The game files were not found" | Built with `--no-content`: copy the `game` folder into the app's folder (see [Installing](#installing)). It must hold `code/`, `content/` and `meta/`. |
| The app closes right away, and `log.txt` says "cannot reserve 4 GiB" | The device or host app allows too little address space. Installing directly with the `extended-virtual-addressing` entitlement (`runtime/src/ios/wwhd.entitlements`: a paid developer account or TrollStore) avoids it. |
| Slow or stuttering for a while after installing | iOS is compiling the game's shaders for the first time; they are cached afterwards. The performance overlay shows it. |
| "cannot map guest memory" | The GPU's largest buffer is under 1 GiB. The first `[gfx]` lines of `log.txt` report it. |
| Apple Metal HUD doesn't show | Turn on Developer Mode and reopen the app, or use the performance overlay instead. |
| Black or broken textures on older GPUs | Textures in BC formats are decoded on the CPU where the GPU can't read them. `WWHD_BC_DECODE=1` in `env.txt` forces it. |

When reporting a problem, include `log.txt` (and `log-prev.txt` if the app closed) from the app's
folder.

---

## For developers

The full details are in [docs/ios.md](docs/ios.md).

- **iOS code**:
  - `runtime/src/ios/` holds the app and scene delegates, views, touch controls (`ios_touch.mm`,
    a port of the Android `ControlsView`), controllers, the performance overlay and the icon.
  - `metal_main.mm` has the `TARGET_OS_IPHONE` parts, and `metal_compat.mm` the renderer hooks the
    shared runtime gained for Vulkan.
- **Building without game code**: `cmake -S . -B build/ios-check -DCMAKE_SYSTEM_NAME=iOS
  -DWWHD_IOS_NO_GAME=ON` builds the app with stub game functions. With `WWHD_IOS_UI_PREVIEW=1` in
  `env.txt`, the app shows the controls without starting a game. `WWHD_IOS_PREVIEW_ASPECT=2.22`
  lays them out as on a 20:9 phone.
- **Guest memory**: on iOS the 4 GiB guest window is placed at run time. It goes at 64 GiB when
  the app may use that much address space, and anywhere free otherwise (`mem::init` in
  `runtime/src/core.cpp`). This is how it runs inside LiveContainer.

---

## Credits

- **[ZeldaWWHDRecomp](https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp)**: the recompilation, the
  Wii U system libraries, the Metal renderer and many fixes.
- **[Nycolazs/WindWakerHD-Android-Plus](https://github.com/Nycolazs/WindWakerHD-Android-Plus)**: the
  Android Plus app this port is forked from: touch controls and their artwork, the launcher icon
  art, and the game state the controls read.
- **[GreenNaugahyde/ZeldaWWHDRecompAndroid](https://github.com/GreenNaugahyde/ZeldaWWHDRecompAndroid)**
  and **[SSunnKing/ZeldaWWHDRecompAndroid---ENHANCED](https://github.com/SSunnKing/ZeldaWWHDRecompAndroid---ENHANCED)**:
  the Android port and the Enhanced fork it builds on.
- **[Cemu](https://github.com/cemu-project/Cemu)**: the GPU address library, the shader decompiler
  and the disc image reader (MPL-2.0).
- **[zeldaret/tww](https://github.com/zeldaret/tww)**: the decompilation used for the save data and
  actor layouts.
- **[Zstandard](https://github.com/facebook/zstd)** and the other libraries in `runtime/third_party`.

---

## Legal notice

This is an unofficial fan project. It is **not affiliated with, endorsed or sponsored by Nintendo**.
"The Legend of Zelda", "The Wind Waker", "Wii U" and related names are trademarks of their
respective owners and are used only to describe what this software is compatible with.

This repository contains **no game code, no game assets and no keys**. You need your own, legally
obtained copy of the game, dumped from your own Wii U disc and console. The IPA you build on your
Mac contains code recompiled from your copy and, unless built with `--no-content`, your game files:
**it is for your own devices only and must not be shared or published.**

## License

[Mozilla Public License 2.0](LICENSE), as the projects it is based on. Third-party code keeps its
own license.
