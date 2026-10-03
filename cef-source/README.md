# CEF compatibility helper source

This directory contains the source for the experimental helper bundled with the Mac launcher. It is our compatibility adapter for the official KCD:MP 0.37.0 client, not the source of Chromium, CEF, the game or the multiplayer client.

- `client_compat/bridge` contains the C++ DLL that copies CEF CPU frames into the game's D3D12 render path. Its target manifest and generated header are pinned to one exact KCD:MP client build.
- `client_compat/loader` contains the Win64 loader and watcher used to initialize that DLL in the newly started game process.
- `client_compat/verify_release_binary.py` rebuilds the DLL and compares it with the copy bundled in `cef-compat`.

## Build

Install an LLVM MinGW toolchain and set `KCDMP_LLVM_MINGW` to its root if it is not at `~/llvm-mingw`. From the repository root, run:

```sh
sh cef-source/client_compat/bridge/build.sh
sh cef-source/client_compat/loader/build.sh
python3 cef-source/client_compat/verify_release_binary.py
```

The build outputs stay under `cef-source/client_compat/bin` and `cef-source/client_compat/loader/bin`. They are ignored by Git and are not automatically substituted into the app. The verification command compares a fresh DLL against the bundled DLL after normalizing PE build timestamps and checksums. It leaves the bundled copy unchanged.

The included target header and shader bytecode allow a rebuild without installing the game. To rederive the target manifest from the exact supported client, set `KCDMP_REGENERATE_TARGET=1` and `KCDMP_CLIENT_DLL` to that client's DLL before running the bridge build. The inspector refuses any other client hash. A new multiplayer version needs a newly derived and tested adapter.

This helper changes process memory during launch. It does not modify the client DLL on disk, game files, Wine or any integrity check. It remains experimental. One game launch rendered the world and CEF interface, while another crashed before the first CEF frame. Full game startup and loading stability still need validation.
