# CEF compatibility helper source

This directory contains the source for the experimental helper bundled with the Mac launcher. Its current exact client target is KCD:MP 0.42.0. It does not contain the source of Chromium, CEF, the game or the multiplayer client.

- `client_compat/bridge` contains the C++ DLL that copies CEF CPU frames into the game's D3D12 render path. Its target manifest and generated header are pinned to one exact KCD:MP client build.
- `client_compat/loader` contains the Win64 loader and watcher used to initialize that DLL in the newly started game process.
- `client_compat/verify_release_binary.py` rebuilds the DLL and compares it with the copy bundled in `cef-compat`.
- `client_compat/probe/macos_ntdll_page_probe.c` reads the host memory protection of a faulting Wine `ntdll.dll` address during a live run. See [probe/README.md](client_compat/probe/README.md).

## Build

Install an LLVM MinGW toolchain and set `KCDMP_LLVM_MINGW` to its root if it is not at `~/llvm-mingw`. From the repository root, run:

```sh
sh cef-source/client_compat/bridge/build.sh
sh cef-source/client_compat/loader/build.sh
python3 cef-source/client_compat/verify_release_binary.py
```

The build outputs stay under `cef-source/client_compat/bin` and `cef-source/client_compat/loader/bin`. They are ignored by Git and are not automatically substituted into the app. The verification command compares a fresh DLL against the bundled DLL after normalizing PE build timestamps and checksums. It leaves the bundled copy unchanged.

The included target header and shader bytecode allow a rebuild without installing the game. For a new official release, `bridge/prepare_candidate.py` calculates the client DLL hash and compares the exact patched and read functions with the previous reviewed client. It refuses changed instructions, ambiguous anchors and mismatched data. `bridge/stage_candidate.py` selects a passing target in a disposable checkout, then `bridge/verify_launcher_target.py` generates the matching Swift version and hash. The scheduled GitHub workflow runs these steps and saves a draft build. An isolated guard probe and live game check are still required before publishing an adapter. The current review record is in `bridge/evidence-0.42.0.md`.

This helper changes process memory during launch. It does not modify the client DLL on disk, game files, Wine or any integrity check. The current source also retains the original native loading screen on this Mac until the client finishes loading, then resumes normal CEF composition. The 0.42.0 target passed static correspondence and isolated guard checks. The helper loaded on local and public servers, and the owner reports that the web interface works. Long-term stability and CrossOver CEF behavior are unverified.
