# Need for Speed: Underground 2 on Apple TV

A fan project that runs the PC game *Need for Speed: Underground 2* (2004) natively on the **Apple TV 4K**. The game's
x86 code is translated to C ahead of time and built into a tvOS app: Direct3D 9 runs on Metal, the sound on RemoteIO,
the controls on Apple's GameController framework (DualShock, DualSense, Xbox and other pads). You build the app on your
Mac and install it on **your own** Apple TV, from Xcode or through TestFlight. You bring your own copy of the game.

> Not affiliated with or endorsed by Electronic Arts. This repository contains none of the game's code or data, and
> nothing here is meant for distribution.

The same code also runs [in the browser](#other-versions) and natively on macOS.

## Status

| | State |
|---|---|
| Apple TV 4K (3rd generation, A15) | **Tested.** Boots, menus, a profile, the garage and Free Roam run. |
| Apple TV 4K (1st generation, A10X) | **Tested**, works fine (the build is made for the A10 and newer). |
| Apple TV 4K (2nd generation, A12) | Not tested, but it is newer than the 1st generation and should run it. |
| Apple TV HD (A8, 2 GB of memory) | **Not expected to work**: the app is built for the A10 and newer, and its memory is small. |
| Pads | Read through Apple's GameController framework. A DualShock 4 was recognised on the test box. Playing with it, rumble and the light bar are **not tested**. |
| Siri Remote | Works as a simple pad in the menus (touch = D-pad, click = A, Play/Pause = Start, Menu = B). Not a way to drive. |
| Saves | Kept in the app and copied to your iCloud (needs the iCloud capability, see [Saves and your name](#saves-and-your-name)). |
| Frame rate, long sessions | **Not measured yet.** |

The Apple TV gives an app about 2 GB of memory (measured on the 3rd generation by the `tvos/probe/` app). It has no
hardware support for the game's DXT textures, so they are unpacked to 4 bytes per pixel when loaded, which costs
memory. A smarter conversion (DXT to ASTC) is not done yet, so the Apple TV HD, with less memory, is the box to worry about.

## What you need

- **The game**: your own PC copy, patched to v1.2 (North America), with this exact `SPEED2.EXE` (other versions will
  not work): 4,800,512 bytes, SHA-256 `f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7`. Keep the
  whole game folder, with `server.dll` next to the exe.
- **A Mac** (Apple Silicon is what is tested) with **Xcode** that has the tvOS SDK (tvOS 17 or newer), Python 3 and Ruby
  (macOS has Ruby). Install the Ruby gem the project generator uses: `gem install xcodeproj`.
- **An Apple TV 4K** on the same network as the Mac, with tvOS 17 or newer.
- **An Apple Developer Program membership** (paid, per year) if you want TestFlight, iCloud saves or the Game Center
  name. A free Apple account may be enough to put the app on your own TV from Xcode for a few days; this has not been
  tried, and the iCloud and Game Center capabilities need the paid one.
- Several **gigabytes of free disk space** (the lifted C, the build, and the game folder copied into the app) and, for
  TestFlight, **1.8 GB of upload** every time you send a build.

## Install

All commands run from the repository's root folder.

### 1. Get the code and translate the game

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./gen.sh "/path/to/Need for Speed Underground 2/SPEED2.EXE"     # translates the game's code to C (into gen/), this takes a while
```

The generated C is made from the game, so it is never committed (`.gitignore`).

### 2. Put the game folder next to the code

The project looks for a folder called `NFS Underground 2` in the repository's root. Copy your game folder there, or
point `GAME` at it in step 4. The folder is ignored by git; **do not commit or publish it**.

### 3. App icon (optional)

```sh
.venv/bin/python tvos/tools/make_icons.py "/path/to/Need for Speed Underground 2/SPEED2.EXE"
```

This takes the game's own logo out of the exe and makes the tvOS icon and the Top Shelf image. Without the argument
it makes a plain "NFSU2" icon. The result is ignored by git, because it holds EA artwork.

### 4. Make the Xcode project

Use **your own** bundle ID and team ID. The bundle ID must be one that no one else has registered
(for example `com.yourname.nfsu2`). Your team ID is in Xcode, Settings, Accounts, or on developer.apple.com under
Membership.

```sh
GAME="/path/to/Need for Speed Underground 2" BUNDLE_ID=com.yourname.nfsu2 TEAM=YOURTEAMID tvos/tv.sh project
```

(`GAME` can be left out when the folder is in the repository, as in step 2.) The project is generated, not committed.

### 5. Pair the Apple TV with Xcode

On the Mac: Xcode, Window, Devices and Simulators, press **+**, pick your Apple TV from the discovered devices, and
follow the prompts (a code may appear on the TV for you to enter). The TV must be awake and on the same network.
Without a paired device Xcode refuses to sign the app ("your team has no devices").

### 6. Build, install and start

```sh
tvos/tv.sh run        # builds, installs, starts the game with its log in the terminal
```

The first build takes several minutes: it compiles about 130 generated C files and copies 1.7 GB of game data into
the app. Later builds are faster. The same steps one at a time:

```sh
tvos/tv.sh build      # build only
tvos/tv.sh install    # install the last build on the Apple TV
tvos/tv.sh launch     # start it, log in the terminal
```

`tv.sh` finds the connected Apple TV itself; `DEVICE=<id>` picks another. Keep the Apple TV awake while you work:
when it sleeps, the install and launch commands hang until it wakes.

You can also open `tvos/NFSU2.xcodeproj` in Xcode and press Run. Building in Xcode also runs `tvos/build.sh`.

### 7. TestFlight (the app on the TV without the Mac)

This is how you keep the app on the TV after you disconnect the Mac. The build expires after 90 days.

1. In **App Store Connect**, create a new app: platform **tvOS**, the same bundle ID as in step 4, and any SKU
   (for example `nfsu2-tv`). Register the bundle ID first at developer.apple.com, Identifiers, if it is not listed.
2. Send a build:

   ```sh
   tvos/tv.sh upload      # archives and uploads, 1.8 GB
   ```

   Apple processes the build for a few minutes. If the upload says "Account credentials have expired", sign in again
   in Xcode, Settings, Accounts, and run it again.
3. In App Store Connect, TestFlight, add yourself as an **internal tester** (Users and Access gives people a role;
   internal testers do not need Apple's review).
4. On the Apple TV: install the **TestFlight** app from the App Store, sign in with the tester's Apple Account, and
   install NFSU2 from there. Updates arrive as new builds.

The game's files are inside the build, so **uploading sends your copy of the game to Apple**. Keep it to internal
testers who own the game. Do not use external testing or the App Store for this.

## Controls

- **A pad**: any pad that tvOS supports (DualShock 4, DualSense, Xbox, MFi). Pair it in Settings, Remotes and Devices,
  Bluetooth. The game reads it as a DualShock-style pad.
- **The Mac keyboard, for development** (until you have a pad): `tvos/tools/keyrelay.py` serves a small page on
  `127.0.0.1:8765` and sends the keys to the app over UDP port 9777. Start it with the Apple TV's address
  (`python3 tvos/tools/keyrelay.py 192.168.x.x`; the app prints the TV's address in its log). It accepts keys from
  anyone on the network and has no password: **use it only on a network you trust, and remove it before you hand the
  app to anyone** (`tvos/host/host_remote.c`, started from `tvos/host/host_tv.m`).
- **The Siri Remote**: see the [Status](#status) table.

## Saves and your name

- The game's saves are in the app's `Library/Caches/NFSU2/Overlay`. tvOS may delete caches when the disk is full, so
  `tvos/host/host_cloud.m` also keeps a compressed copy in **iCloud's key-value store** (about 3 KB per profile):
  it is read before the game starts, and a few seconds after a save changes it goes up. The newest file wins, with no
  merge. This needs the iCloud key-value capability: the entitlement is in `tvos/app/NFSU2.entitlements`, and automatic
  signing asked Apple for it without a manual step on the portal in our case. If Xcode complains, add **iCloud
  (key-value storage)** and **Game Center** in the target's Signing and Capabilities tab.
- A new profile in the game starts with the name **NAME** in its name field. `tvos/host/host_profile.m` renames a
  profile still called NAME to the player's **Game Center name**, made into what the game takes (letters and digits
  only, 7 at most, accents removed). A profile with any other name is left alone. Apple does not give apps the iCloud
  account's name; Game Center is the name an app can get. With no Game Center account on the Apple TV, nothing is
  renamed.

## Problems we met

| What you see | Why, and what to do |
|---|---|
| Xcode: "your team has no devices" or no profiles | Pair the Apple TV in Xcode first (step 5). |
| The build works but the app does not start; a crash at `UIApplicationMain` | tvOS needs the UIScene life cycle. The project already has it; if you changed `tvos/app/Info.plist`, check the built plist, not the source (Xcode reformats the file). |
| The app is on the TV but not on the home screen | Scroll down or right on the home screen; new apps go to the end. |
| The loading screen of Free Roam never ends | The game asked for car files your folder does not have. The runtime now checks for `CARS/CORSA` and `CARS/PEUGOT106` and leaves those two European cars out if they are missing (the log says `[cars] ... no Corsa or 106`). |
| `devicectl` hangs | The Apple TV is asleep. Wake it and try again. |
| "Account credentials have expired" on upload | Sign in again in Xcode, Settings, Accounts. |
| The app closes after a while | Memory (see [Status](#status)). `tvos/probe/` reports what your box allows. |
| Log lines `CANNOT OPEN ... MOVIES\...vp6` | Normal when your folder has no intro videos. |

## How it works

- **`tools/`:** a Python lifter (Capstone) turns every function of `SPEED2.EXE` into C.
- **`runtime/`:** Windows, Direct3D 9, DirectSound and DirectInput, reimplemented. On the Apple TV, Metal draws, RemoteIO
  plays the sound and GameController reads the pads (`TARGET_OS_TV` branches next to the macOS ones).
- **`tvos/`:** the app: the UIKit host, the build of the runtime for tvOS, the Xcode project generator, `tv.sh`, the
  TestFlight upload and the probe app. See its [README](tvos/README.md) for what each file does.

The design notes in [docs/web/DESIGN.md](docs/web/DESIGN.md) are written for the browser version, but they also cover
the lifter and the runtime.

## Other versions

- **In the browser** (Chrome and Firefox, with multiplayer through a server you run): build and play with
  [docs/web/BUILD.md](docs/web/BUILD.md); the player's guide is [docs/web/PLAYING.md](docs/web/PLAYING.md) and the
  server setup is [docs/web/VPS.md](docs/web/VPS.md).
- **Natively on macOS** (Apple Silicon): `./gen.sh`, `./build.sh && ./link.sh`, `./run.sh`.

## Credits

Based on Talha Müderrisoğlu's static recompilation of NFSU2 for Apple Silicon, which in turn follows the method of
[N64: Recompiled](https://github.com/N64Recomp/N64Recomp) and [XenonRecomp](https://github.com/hedge-dev/XenonRecomp).
The language packs are built from KyoriAsh's [Multi 13 languages mod](https://nfsmods.xyz/mod/5749) (with Lee-Ryo's
Thai support, whose patch `runtime/language.c` follows), from TraduMix's and MixMods' Brazilian Portuguese
translation (Fyro, Beater, Kerlyston F.; Junior_Djjr, SideWinder, Elyzandro), from PLProjekt's Polish translation
(Daniel Graszka, MaDeR, Marcin Piech, Nati, Mateusz Wilkowski, alter), from VileStuff's
[English Subtitles Fixed](https://nfsmods.xyz/mod/5286) and from muntazam's
[Turkish translation](https://www.moddb.com/mods/need-for-speed-underground-2-turkish-translation-patch). The texture pack is built from LunicAura106's
[Upscaled HUD](https://nfsmods.xyz/mod/4319). Built with the help of Claude Code.

## License

MIT ([LICENSE](LICENSE)). *Need for Speed* and *Need for Speed: Underground 2* are trademarks of Electronic Arts Inc.
