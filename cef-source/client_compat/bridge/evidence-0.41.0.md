# KCD:MP 0.41.0 CEF adapter evidence

## Target

- Application/process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect <server-address> --name <player> --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version 0.41.0.0
- SHA-256: `1903aec2fa7dad2979207aa8305c4ad1745c34cefb6513c9d498fea3d1e60d6b`
- PE timestamp: `1791552528`, image size: `14577664` bytes
- Runtime: the user's running WineForge Steam bottle and its configured D3DMetal backend

## Failing contract

The official 0.41.0 client was launched through the Mac app's direct path while its 0.40.0 helper was correctly withheld by the version and hash guard. The 0.41.0 client reported `the ready fence or the event query failed - the interface stays native`. The same client log says its chat, scoreboard and shop were drawn natively because the web layer failed. This is the same CEF composition contract previously reproduced on 0.40.0 without its helper. The current game was still running while this static review was performed. No process, prefix, server or installed DLL was changed.

The 0.41.0 Windows release archive SHA-256 is `704e56e59050ff5774ca01a886fde1b1cdb77978169fa1653170b024a4dd00b1`, matching the publisher's `.sha256` asset. The `KcdMp_client.dll` extracted from it exactly matches the installed client's SHA-256. The reference 0.40.0 archive SHA-256 is `682cfab091abeaae1de525940614cd493e64ab8f994fcb635a304a692c4ee86a`, also matching its publisher checksum. Its extracted client matches the reviewed 0.40.0 manifest.

## Instruction mapping

The 0.41.0 DLL has no retained COFF symbols. The new locations were derived from exact old instruction signatures where unique, relative function layout, direct-call correspondence and full disassembly comparison. `popup_rect` and `renderer_reset` each provided a unique 14-byte anchor. The frame functions move by `0x86740` and compositor functions by `0x85350`. All ten patch functions match the 0.40.0 instruction forms over 1,320 instructions after normalizing only relocated RIP operands and branch/call addresses. Five additional read-only functions also match over 284 instructions. The 146 branches internal to these functions preserve their relative targets, and 72 external branches/calls map consistently. The 22 referenced `.rdata` targets retain their relevant values. Four adjacent GUID blocks differ beyond their identical 16-byte GUID values.

The two loading-screen read functions are reached from the reviewed `record` function's direct calls. `render_info` is reached from the same path. `set_loading_cover_probe` is adjacent to `loading_covers` and its exact instructions identify the probe pointer. `loading_wants_paint` was located through its surrounding function block and exact normalized instructions, then its RIP target identified the paint flag. All other helper data bindings come from matched RIP operands in the reviewed functions. The mapping does not assume one universal RVA shift.

| Function | RVA | Raw offset | Section | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | --- | ---: |
| `frames_open` | `0x565050` | `0x564450` | `.text` | `415641554154555756534881ec40` | 8 |
| `frames_paint` | `0x567620` | `0x566a20` | `.text` | `56534883ec4848833dfa45820000` | 1 |
| `popup_paint` | `0x566cb0` | `0x5660b0` | `.text` | `56534883ec4848833d6a4f820000` | 1 |
| `popup_rect` | `0x564b50` | `0x563f50` | `.text` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x566ae0` | `0x565ee0` | `.text` | `4883ec2848833d3c51820000745a` | 1 |
| `frames_latest` | `0x564b90` | `0x563f90` | `.text` | `5756534883ec20488d35a26f8200` | 1 |
| `record` | `0x5078e0` | `0x506ce0` | `.text` | `4154555756534881ecb00000000f` | 8 |
| `before_submit` | `0x505c60` | `0x505060` | `.text` | `803d05488800007427488b157048` | 1 |
| `after_submit` | `0x505c00` | `0x505000` | `.text` | `4883ec28803d6148880000744448` | 1 |
| `renderer_reset` | `0x506190` | `0x505590` | `.text` | `555756534881ec08010000baffff` | 1 |

Each replacement is the existing guarded 14-byte in-memory jump, `ff2500000000` followed by the helper entry VA in little-endian form. The helper diverts CPU frame composition around the unsupported fence/event path and restores the normal game path on failure. The executable's bytes on disk remain unchanged. The skill's `inspect_pe_patch.py` independently confirmed each candidate RVA, raw offset, section, original bytes, SHA-256 and occurrence count. It required a unique signature only for the eight entries that actually have one.

## Provenance

The old target comes from this project's reviewed 0.40.0 manifest and the publisher's archive. The 0.41.0 candidate comes from the publisher's exact archive and the matching installed DLL. No external patch table or CrossOver binary supplied the new addresses. The candidate manifest and header were generated from the disassembly mapping above, then checked against the unchanged 0.41.0 PE image.

## Validation

- Baseline result: 0.41.0 direct launch selected native chat, scoreboard and shop after the ready-fence/event-query failure.
- Project-build injection: one local-server launch loaded the 0.41.0 helper into the exact game process. The loader reported `KcdMpCefCompatInitialize` exit code 0 and the app reported `CEF loaded`. The launch log is `~/Library/Logs/KCDMP CEF/launch-BF797214-CC57-4657-A514-E80107185451.log`. The client log confirmed `KcdMpCefCompat.dll` in the process. This proves guarded loading, not successful web composition.
- A later launch from `/Applications/KCDMP Mac.app` also loaded its 0.41.0 helper into the game and returned `KcdMpCefCompatInitialize` exit code 0. Its log is `~/Library/Logs/KCDMP CEF/launch-379398E1-EC4D-4C55-AB81-87093B89347D.log`. The local server again refused its UI manifest at startup, so this run also cannot establish web composition.
- Initial web result: unverified because the local server refused its UI manifest at startup. The server files were left in their original state at the user's request.
- Later web result: after a separate server correction, the 2026-10-09 20:40 launch from `/Applications/KCDMP Mac.app` loaded the 0.41.0 helper with `init_exit=0x00000000` and `loader_exit=0`. The local server logged `Alien4042x's web layer: ready` and `frame 'ledger' is ready`. The user reported that it was working. This supports actual web startup, while repeated-launch stability and a client-side first-draw trace were not established. The launch log is `~/Library/Logs/KCDMP CEF/launch-4D722BCF-D415-4305-9684-2832CEA9E8FA.log`.
- An isolated Wine probe mapped the candidate PE image without running its DLL entry point. The exact original image returned success. Changed patch-entry and read-only signatures returned `ERROR_INVALID_DATA` (13). Wrong AMD64 machine, PE timestamp, image size and the official 0.40.0 client returned `ERROR_REVISION_MISMATCH` (1306). An image with all ten jumps already applied returned success with the already-patched flag set.
- Calling the candidate helper from the probe process returned `ERROR_ACCESS_DENIED` (5). The disposable prefix's wineserver exited. The user's Steam prefix was not used for the probe.
- A local-server connection was accidentally opened from the older `/Applications/KCDMP Mac.app` due to Launch Services choosing that installed app for `open -a`. Its status explicitly chose the official direct path without CEF. The user asked to close that game, and the old app was closed. The project build was then launched by its absolute executable path.
- Other application regression check: pending.
- Process cleanup at the initial test: the project-build game and Steam were left running at the user's request. The server was not restarted by this compatibility work.

## Integration

The 0.41.0 target is selected in `patch_guard.h`. `CEFLauncher.swift` gates the helper on the exact 0.41.0 DLL hash. The 0.40.0 target files remain as a separate reviewed record. The helper must remain an unpublished local candidate until isolated and live checks pass. Remove the adapter when the official client provides equivalent CPU CEF composition under Wine. This change is local and uncommitted. No push was made.
