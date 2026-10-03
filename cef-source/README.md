# CEF compatibility helper source

This directory contains the source for the experimental helper bundled with the Mac launcher. It is our compatibility adapter for the official KCD:MP 0.38.0 client, not the source of Chromium, CEF, the game or the multiplayer client.

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

The included target header and shader bytecode allow a rebuild without installing the game. To derive a candidate manifest for a new release, set `KCDMP_CLIENT_DLL`, `KCDMP_TARGET_VERSION` and `KCDMP_TARGET_SHA256` when running `bridge/inspect_target.py`. The inspector refuses a client whose hash or file version differs. Run `bridge/review_target.py` against the previous reviewed client and manifest to compare the exact functions and referenced data. Review the result, select the new header in `patch_guard.h`, run the isolated guard probe and test in the game before publishing a new adapter. The build script never selects a new target automatically. The current review record is in `bridge/evidence-0.38.0.md`.

This helper changes process memory during launch. It does not modify the client DLL on disk, game files, Wine or any integrity check. The current source also retains the original native loading screen on this Mac until the client finishes loading, then resumes normal CEF composition. One 0.38.0 live launch crashed inside Wine during CEF startup before the first overlay frame. A subsequent 0.38.0 launch recorded the native loading phase and the first CEF overlay frame, and the user confirmed that the interface was visible. Its behavior still needs investigation. Startup stability remains unresolved.
