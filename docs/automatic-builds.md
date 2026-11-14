# Automatic Mac builds

The **Build Mac draft for new KCD:MP version** workflow checks the official releases once a day or when manually started. When the latest client already has a complete matching Mac ZIP, the check ends without a Mac build or another draft. A server-only upstream release does not trigger a new client build.

For a new client, GitHub downloads the previous reviewed client and the new official archive, verifies the publisher's checksums, and compares the functions used by the CEF helper. Missing predicted function entries can move only to a unique fully equivalent entry within the bounded search range. Changed instructions, branch relationships, referenced data, function sizes or required bindings stop the build for review.

When comparison passes, the temporary checkout selects the new exact CEF target and builds its helper. The same job builds the WebView2 bridge with pinned LLVM-MinGW and pinned SDK/JSON headers, then builds the full **KCD2MP Mac.app** through Xcode. The app contains the native WebKit host, its bridge DLL, CEF helper, loader, watcher and a generated manifest binding the official launcher and client hashes to those resources. No Python or compiler is needed on the user's Mac.

The job creates one ZIP containing the complete app and saves it in an unpublished draft tagged `cef-ci-vX.Y.Z`, titled `KCD2MP Mac for KCD:MP vX.Y.Z`. Only the ZIP is attached to the draft. Its checksum and comparison reports stay in the Actions artifact. The ZIP asset name remains `KCDMP-Mac-vX.Y.Z.zip` so existing release detection continues to recognise previous builds.

GitHub build output is unsigned. Signing and notarization, if wanted, happen locally before publishing. The draft remains private until published. GitHub cannot run KCD2 or verify CEF panels, microphone input or game stability. When compatibility checks pass, future upstream versions do not require another source commit or manual rebuild.

The separate **Check Mac source build** workflow checks the committed target on pushes and pull requests. It runs the offline checks and builds the same Xcode application, then saves a development artifact for non-PR runs. It does not create a draft release.

## Local development

Run `./build.command` to prepare the pinned build tools and build `KCD2MP Mac.app`. It uses an available local Developer ID identity or an ad hoc signature. For direct Xcode builds, first run `sh ci/prepare-bridge-toolchain.sh`, then build the existing **KCDMP Mac** scheme in `KCDMP Mac.xcodeproj`. The scheme name is retained for compatibility, its product is **KCD2MP Mac.app**.

The build verifies the selected official archive against its publisher checksum, checks the exact client hash, compiles the application-local bridge and generates `launcher-target.json` inside the app. `KCDMP_LAUNCHER_ARCHIVE` may point to an already downloaded publisher archive with its matching `.sha256` file beside it. The draft workflow uses this to reuse its verified download.

The app asks for `KcdMp_launcher.exe` once and uses the running Steam session from that bottle. It temporarily stages only its own WebView2 bridge. A session lock prevents two app instances from managing the same folder. Cleanup checks the file identity and hash before removing it. A later launch can recover a receipt from an interrupted app, provided the old Windows launcher is no longer running. Existing or replaced DLLs are preserved.

The app also packages a small universal macOS Dock helper for the Windows launcher process. It uses the public AppKit accessory policy inside that process. Activation requires the exact first PE executable argument, the bridge opt-in, a valid session token and a live Mac host PID. It preserves its preload through Wine's native bootstrap re-exec and removes that entry from the Unix environment once Cocoa is ready. Game and Steam executable arguments are refused, and the separate CEF watcher uses the original Steam environment. If the Mac host disappears, it restores the backend's regular Dock entry instead of leaving an invisible orphan. It does not change Wine files or global Dock settings. Native helper ABI checks survive normal Xcode processing and local signing, which can change Mach-O file hashes.

`sh ci/check-launcher.sh` checks candidate relocation, archive metadata, temporary DLL ownership/recovery and the retained saved-server/audio parsers. The native host also supports `--self-test`. Live evidence and remaining compatibility limits are recorded in [the bridge work state](../webview-bridge/STATUS.md).

The Dock activation gate is checked by `ci/test_dock_policy_gate.c`. `ci/run_dock_policy_probe.py` is an optional local GUI-session check that uses only a disposable native fixture, including later foreground promotion, a game-shaped command line and an absent host. Its `--architecture x86_64 --reexec` mode checks the startup failure found in real Wine. It never starts Wine, Steam or KCD2. Actual Wine Dock behaviour was confirmed separately by the user on WineForge 0.50. CrossOver remains unverified.
