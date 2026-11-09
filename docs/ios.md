# iOS port

The game on iPhone and iPad: the macOS Metal renderer (`runtime/src/gfx`) in a UIKit shell
(`runtime/src/ios`). As on the desktop, the game code is recompiled **on your Mac** from your own
`cking.rpx` and linked into the app. iOS doesn't allow an app to compile and load code at run
time, so the Android app's on-device recompiler isn't used.

**The IPA you build contains game code. Install it on your own devices only; never share it.**

## Requirements

- A Mac with Xcode (iOS SDK 16 or newer), CMake 3.20+, Python 3 (`pycryptodome` to extract a disc image)
- Your own The Wind Waker HD, **USA** release (the hooks are at the USA addresses; the EUR/JPN maps
  exist only for the Android on-device recompiler)
- An iPhone or iPad with an A12 chip or newer, iOS 16+
- A way to install it: a paid developer account, SideStore/AltStore, TrollStore, or LiveContainer.
  The entitlements in `runtime/src/ios/wwhd.entitlements` help but aren't required:
  - `extended-virtual-addressing`: the game's 4 GiB memory window goes at 64 GiB, as on Android.
    Without it (LiveContainer's host app, for example) the app takes 4 GiB wherever the system has
    room (`mem::init` in `runtime/src/core.cpp`; the log's `[mem] guest window` line says where).
    A device that can't spare 4 GiB of address space stops with "cannot reserve 4 GiB".
  - `increased-memory-limit`: recommended.

## Build

```sh
# from a disc image (game.key next to it, plus your common key: see tools/wudextract.py)
tools/ios/build-ipa.sh --image game.wux

# or from an extracted game (code/, content/, meta/)
tools/ios/build-ipa.sh --game path/to/game
```

The result is `build/ios/WindWakerHD.ipa`, ad-hoc signed; sideloading tools sign it again with your
certificate. The first build recompiles the game code (minutes); later builds reuse `build/gen`
while the RPX and the recompiler are unchanged.

Options: `--no-content` leaves the 2 GB of game files out of the app. Copy the `game` folder to
the app's folder in the Files app (On My iPhone > Wind Waker HD) or in Finder instead.
`--cpu apple-a14` builds the game code for a newer chip. `--env FILE` bakes in `WWHD_*` switches.
`--sim` builds for the Simulator.

## Playing

- **Touch controls**: the Android app's controls and artwork (`runtime/src/ios/ios_touch.mm` ports
  `ControlsView`). The left side is a floating move stick (it starts where your thumb lands). Swipes
  on the right side turn the camera: double tap centres it, pinch zooms. There is also a fixed camera
  stick. A, B, ZR and the X/Y/R item slots show what they do in the game, and the D-pad items appear
  once Link has them. The orange buttons are one-touch combat moves (jump attack, vertical slash,
  spin attack, dodge), shown once Link has a sword. During scenes the game lets you skip, only a
  Skip button shows, and a tap elsewhere is A. While a game controller is connected, only ≡ and ✎
  stay (`WWHD_TOUCH_ALWAYS=1` keeps all of them).
- **≡ menu**: the GamePad screen (inset, full screen or hidden), the layout editor, button size,
  opacity, camera speed, camera stick, combat buttons (auto, always or never), the performance
  overlay (frame rate, frame time and the longest frame, GPU time, memory, thermal state; works
  everywhere, LiveContainer too), Apple's Metal HUD (iOS shows it only with Developer Mode on, after
  reopening the app) and vibration. The game
  pauses while it's open. ≡ and ✎ fade out after 5 seconds; the first touch on them brings them back.
- **✎ layout editor**: drag a control to move it (it snaps to the grid). Drag the corner handle or
  pinch to resize it. 🗑 removes the selected control, + puts removed ones back, ↺ restores the
  default layout, ✕ cancels and ✓ saves.
- **GamePad screen**: in inset and full-screen mode, touching the GamePad picture is the GamePad's
  touch panel (the map, the items, the Tingle Tuner). In full-screen mode only A, B and pause stay.
- **Controllers**: any MFi, Xbox, PlayStation or Switch controller, mapped by button position as
  on the desktop (Xbox "A" = Wii U B).
- Text entry (naming your file) opens the iOS keyboard.

## Files (in the app's folder, visible in Files and Finder)

| | |
|---|---|
| `save/` | save data |
| `log.txt`, `log-prev.txt` | this run's log and the previous run's |
| `captures/` | crash logs |
| `env.txt` | optional `KEY=VALUE` lines set as environment variables at start (an `env.txt` inside the app is read first) |
| `game/` | the game, if it isn't inside the app; it takes precedence over the copy in the app |

## Differences from Android

The Android app's Vulkan renderer has features the Metal renderer doesn't: 60 fps frame
generation, wider-than-16:9 output, the HUD editor and the sun's lens flare (depth peeks). The iOS
app also lacks most of the Java app's settings menu (the ≡ menu has only the touch control and
GamePad screen settings), its Portuguese translation, its performance overlay, and touch icons
built from the game's own artwork (IconForge); iOS uses the app's bundled icons. The iOS app runs the game at its own
30 fps, at 16:9.

On GPUs that can't sample BC (DXT) textures, they are decoded on the CPU at upload
(`bc_decode` in `runtime/src/gfx/formats.mm`; `WWHD_BC_DECODE=1` forces it). The log's first `[gfx]`
lines report the GPU's largest buffer and which path is used. The guest's 1 GiB MEM2 window is one
Metal buffer, so a device whose limit is under 1024 MiB stops with "cannot map guest memory".

## For developers

- `cmake -S . -B build/ios-check -DCMAKE_SYSTEM_NAME=iOS -DWWHD_IOS_NO_GAME=ON` builds the app
  without game code. The game functions become stubs. With `WWHD_IOS_UI_PREVIEW=1` in `env.txt`,
  the app shows the controls without starting the game.
- iOS-only code: `runtime/src/ios/` (app and scene delegates, views, touch controls, input),
  `metal_main.mm` (`TARGET_OS_IPHONE` blocks), `audio_out_coreaudio.cpp` (RemoteIO).
- `runtime/src/gfx/metal_compat.mm` holds the renderer hooks the shared runtime gained for Vulkan.
