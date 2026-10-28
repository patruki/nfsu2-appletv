# Building and running the browser version

The same lifted C code that runs on the Apple TV also runs in Google Chrome and Firefox: it is compiled to WebAssembly,
Direct3D 9 runs on WebGPU and the sound on Web Audio. You bring your own copy of the game.

![The start page: Play, the controls, your saves and Online](start-page.png)

## What you need

- **The game:** your own PC copy, patched to v1.2 (North America), with this exact `SPEED2.EXE` (other versions
  will not work): 4,800,512 bytes, SHA-256 `f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7`.
- **To build:** an Apple Silicon Mac (the tested setup) or Linux, Python 3, Node.js 20 or newer, Rust
  ([rustup](https://rustup.rs)), and [wasi-sdk](https://github.com/WebAssembly/wasi-sdk/releases) 34 for that system
  unpacked into `deps/`. On Windows,
  build in WSL 2 with the clone in the Linux file system (`~/nfsu2-web`): under `/mnt/c` it builds much slower.
- **To play:** the latest Google Chrome, or Firefox where it has WebGPU (Windows, macOS).

## Build

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
web/gen.sh "/path/to/Need for Speed Underground 2/SPEED2.EXE"   # translate the game's code to C (into gen/)
web/build.sh                                                    # compile it to out/web/nfsu2.wasm
```

The generated C and the compiled module are made from the game, so they are never committed (`.gitignore`).

## Play

```sh
web/start.sh --data "/path/to/Need for Speed Underground 2"
```

Open **http://localhost:8080/** in Chrome or Firefox and press **Play**. The start page has the settings, your saves
and the controls. The player's guide is [PLAYING.md](PLAYING.md). The game plays in any of its
thirteen languages, in Brazilian Portuguese, in Polish or in Turkish; the dubbed voices and movies and the Portuguese,
Polish and Turkish text come from mods, as language packs ([VPS.md](VPS.md#languages)). The menus and
HUD can be redrawn at four times their size, from a mod as a texture pack ([VPS.md](VPS.md#texture-packs)).

To play with friends, run the server behind HTTPS, for example on a small VPS with Docker:
[VPS.md](VPS.md).
Everyone who plays from the same server can meet in free roam.

## The server and the page

- **`web/src/`:** the page. It runs the game's threads as workers on one shared memory, draws with WebGPU and plays
  sound through an AudioWorklet.
- **`web/server-rs/`:** the server, in Rust: serves the page, the module and your game folder, and connects players
  for multiplayer.
- **`runtime/web/`:** the browser parts of the runtime.

More in [DESIGN.md](DESIGN.md).
