# tvos/

The Apple TV app. How to build it and put it on your own Apple TV is in the
[root README](../README.md#install); this file only says what is in this folder.

## What is in this folder

- `tv.sh`: build, install, launch and upload in one command.
- `build.sh`: compiles the generated shards and the runtime into `out/tvos/libnfsu2.a` (called by Xcode).
- `make_project.rb`: makes `NFSU2.xcodeproj` (a generated file, not committed).
- `testflight.sh`: archive, and with `UPLOAD=1` upload.
- `host/`: the UIKit side: `host_tv.m` (window and Metal view), `host_bundle.m` (where the game and its saves are),
  `host_cloud.m` (iCloud saves), `host_profile.m` (Game Center name), `host_remote.c` (the keyboard relay).
- `app/`: `Info.plist`, the entitlements, the icon assets (generated).
- `tools/`: `make_icons.py`, `keyrelay.py`.
- `probe/`: a small diagnostic app that reports what an Apple TV allows (address space, memory, textures, pads).

The game itself runs on a thread of its own; Metal does the drawing, RemoteIO the sound, the GameController framework
the pads. The runtime's platform code has `TARGET_OS_TV` branches next to the macOS ones, and the macOS build still
compiles from the same files.
