# KCD:MP 0.42.0 CEF adapter evidence

## Target and baseline

- Application and process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect <server-address> --name <player> --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version 0.42.0.0
- Client SHA-256: `e3711a4574d152e5ba1953b2885b055bde7c6eeca542f48a691c73afc3bc4e8`
- PE timestamp: `1791633775`, image size: `15097856` bytes
- Runtime: the user's WineForge Steam bottle with its configured D3DMetal backend

The Mac app withheld its 0.41.0 helper after the official client updated to 0.42.0. The direct launch log records `D3D11Fence::CreateSharedHandle` as unsupported. The 0.42.0 client log reports `the ready fence or the event query failed - the interface stays native`, then native chat, scoreboard and shop because the web layer failed. This reproduces the same CEF composition failure seen on the previous unpatched client. The direct launch log is `~/Library/Logs/KCDMP CEF/launch-direct-CACC9742-83E3-4500-8065-71264230D038.log`.

The official 0.42.0 Windows archive SHA-256 is `589c895eb05af719a69b897c3d66bb0961d004919764cb45ec244211983936fb`. It matches the publisher's `.sha256` asset. Its extracted DLL exactly matches the installed client. The previous 0.41.0 archive SHA-256 is `704e56e59050ff5774ca01a886fde1b1cdb77978169fa1653170b024a4dd00b1`, which matches the publisher checksum. Its extracted DLL exactly matches the previously reviewed manifest. Neither installed DLL was modified.

## Instruction correspondence

The new DLL has no retained COFF symbols. The unique 14-byte `popup_rect` and `renderer_reset` function entries anchor the frame and compositor groups. Their moves are `+0x45a60` and `+0x43f20` respectively. Every mapped function retained its unwind function size. The full disassembly comparison matched all 1,320 instructions in the ten patched functions, plus 277 instructions in five read-only functions. The 175 internal branches preserve their relative targets, 47 external branch targets map consistently, and 78 referenced data targets have no mapping conflicts. All 26 referenced read-only data values match. The two loading read functions were located through direct calls and adjacent code, and the paint flag was identified by its exact RIP reference and checked against the unchanged reviewed data layout.

| Function | RVA | Raw offset | Section | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | --- | ---: |
| `frames_open` | `0x5aaab0` | `0x5a9eb0` | `.text` | `415641554154555756534881ec40` | 9 |
| `frames_paint` | `0x5ad080` | `0x5ac480` | `.text` | `56534883ec4848833ddac8850000` | 1 |
| `popup_paint` | `0x5ac710` | `0x5abb10` | `.text` | `56534883ec4848833d4ad2850000` | 1 |
| `popup_rect` | `0x5aa5b0` | `0x5a99b0` | `.text` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x5ac540` | `0x5ab940` | `.text` | `4883ec2848833d1cd4850000745a` | 1 |
| `frames_latest` | `0x5aa5f0` | `0x5a99f0` | `.text` | `5756534883ec20488d3582f28500` | 1 |
| `record` | `0x54b800` | `0x54ac00` | `.text` | `4154555756534881ecb00000000f` | 7 |
| `before_submit` | `0x549b80` | `0x548f80` | `.text` | `803d05e68b00007427488b1570e6` | 1 |
| `after_submit` | `0x549b20` | `0x548f20` | `.text` | `4883ec28803d61e68b0000744448` | 1 |
| `renderer_reset` | `0x54a0b0` | `0x5494b0` | `.text` | `555756534881ec08010000baffff` | 1 |

Each replacement remains the guarded 14-byte in-memory jump to the corresponding helper function. The published client DLL on disk remains unchanged. `inspect_pe_patch.py` independently confirmed the RVA, raw offset, `.text` section, original bytes, SHA-256 and occurrence count for all ten patch entries and both read-only signatures. Uniqueness was required only for entries whose signatures are unique in the image.

The new `prepare_candidate.py` tool reproduced the exact 0.42.0 manifest and header from the official 0.41.0 and 0.42.0 binaries. A candidate with a changed `frames_open` instruction was rejected before writing target files. It does not infer a patch from a version number alone.

After moving the launcher version and SHA-256 into generated Swift code, the complete 0.41.0 to 0.42.0 candidate path was run again in a disposable checkout. It computed the 0.42.0 DLL hash from the official client bytes, staged the new target and generated `CEFClientTarget.swift`. The manifest, header and Swift file exactly matched the reviewed 0.42.0 files. A corrupted generated hash was rejected and regenerated from the manifest.

## Isolated and build checks

- Baseline: the official 0.42.0 client selected native interface after the ready-fence or event-query failure. No helper was injected.
- Candidate: `prepare_candidate.py` mapped the reviewed functions and data and produced the target manifest. The standalone 0.42.0 helper was rebuilt with the pinned source and embedded in the local Xcode app.
- Guard probe in a disposable Wine prefix: exact original image returned success. Changed patch entry and changed read signature returned `ERROR_INVALID_DATA` (13). Wrong machine, PE timestamp, image size and the official 0.41.0 client returned `ERROR_REVISION_MISMATCH` (1306). An already-patched image returned success without applying the patch again. Invoking the DLL from the probe process returned `ERROR_ACCESS_DENIED` (5). The disposable prefix was removed. The user's Steam prefix was not used for this probe.
- The local Xcode Release build passed after running with Xcode service access. The first test build was ad hoc signed. The final local test build was then signed automatically with the owner's `Developer ID Application: Radim Vesely (58HZ49VDDX)` identity. Outside the restricted sandbox, `codesign --verify --deep --strict` reported `valid on disk` and `satisfies its Designated Requirement`. The signature has a secure timestamp. This test build has not been notarized.
- The user's first 0.42.0 test on 10 October still used the direct path. The bundled helper and installed client had the correct 64-digit SHA-256, but `CEFLauncher.swift` contained a 63-digit copy missing one `5` at position 33. The exact-hash gate therefore correctly refused injection. The source hash was corrected, and the Xcode project now generates the launcher's version and SHA-256 from the selected verified target manifest. `verify_launcher_target.py` checks the manifest, helper header and generated Swift file before local and CI builds. A disposable source copy with the same one-character typo was rejected. A live game test of the corrected app is pending.
- Live patched-game test: the owner reports that CEF is working so far. Logs from 10 October at 20:19 on the local server and 21:43 on a public server show the exact 0.42.0 helper loaded into `KingdomCome.exe`, `KcdMpCefCompatInitialize` returned 0, the web interface bundle was prefetched and the game exited with code 0. The logs do not independently prove every panel rendered or long-term stability.
- CrossOver CEF test: pending.

## Integration and release state

`patch_guard.h` selects the 0.42.0 target, while `CEFLauncher.swift` checks the exact 0.42.0 DLL hash before injecting this helper. The 0.40.0 and 0.41.0 target records remain separate. The candidate and automatic draft workflow are local and uncommitted. No push was made. The scheduled workflow can prepare future candidates only when its strict correspondence checks pass, and it keeps them unpublished pending a live game test. Automatic Developer ID signing and notarization need the owner's one-time GitHub secret setup.
