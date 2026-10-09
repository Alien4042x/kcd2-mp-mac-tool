# KCD:MP 0.40.0 CEF adapter evidence

## Target

- Process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect 127.0.0.1:27877 --name Alien4042x --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version 0.40.0.0
- SHA-256: `a6ac0a5309abdf21aba9522f11252690c5092c0d5cc34b3229524c8d99a4f82b`
- PE timestamp: `1791453067`, image size: `13307904` bytes
- Runtime: WineForge Steam bottle with its configured D3DMetal backend

## Failing contract

The Mac app built for 0.39.1 updated the installed client to 0.40.0 before Connect. Its exact hash guard selected the official direct path, so the old helper was not injected. The local server supplied web bundle `b381a478`, but the client reported `the ready fence or the event query failed - the interface stays native`. The game reached the world with native chat, scoreboard and shop. It later closed from the game menu with exit code 0. No new client crash report was written for this direct launch. The baseline log is `~/Library/Logs/KCDMP CEF/launch-direct-FD1D239A-C948-4A16-B8BC-14D095C0DA48.log`.

The earlier 0.39.1 controlled comparison established that the original CPU-frame path fails on this WineForge setup while the exact-version helper can render the web panels. This 0.40.0 port tests whether the same narrow private functions and data still have the reviewed behavior. It does not claim to fix the separate intermittent startup crash.

## Instruction mapping

The original 0.40.0 client was copied to temporary review storage without changing the installed DLL. The candidate manifest was generated from its retained COFF symbols. The previous client came from the [official 0.39.1 release](https://github.com/dintech-rappy/kcd-mp-releases/releases/tag/v0.39.1). Its archive SHA-256 matched the publisher's `.sha256` file, `f7d5041a042d622dc77274c2dd078a5f013b41a9e33095d3281ec90bc2064bca`, and the extracted DLL matched the reviewed 0.39.1 manifest SHA-256.

All ten patched functions have matching disassembly, 1,320 instructions in total. Their referenced data was compared locally. Of five additional read-only functions, `render_info`, `loading_covers` and `set_loading_cover_probe` match. `loading_visible` differs only in its stack allocation and matching deallocation, both changing from `0x2c0` to `0x2e0`. Its other 265 instructions and referenced data match. `loading_wants_paint` differs only in trailing alignment padding, `nopl` versus `nop`. The full strict `review_target.py` intentionally stops at the first difference, so the two read-only differences were reviewed separately rather than waived by the tool. Across all 15 functions, 16 `.rdata` references were checked.

| Function | RVA | Raw offset | Section | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | --- | ---: |
| `frames_open` | `0x4de910` | `0x4ddd10` | `.text` | `415641554154555756534881ec40` | 7 |
| `frames_paint` | `0x4e0ee0` | `0x4e02e0` | `.text` | `56534883ec4848833dda58790000` | 1 |
| `popup_paint` | `0x4e0570` | `0x4df970` | `.text` | `56534883ec4848833d4a62790000` | 1 |
| `popup_rect` | `0x4de410` | `0x4dd810` | `.text` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x4e03a0` | `0x4df7a0` | `.text` | `4883ec2848833d1c64790000745a` | 1 |
| `frames_latest` | `0x4de450` | `0x4dd850` | `.text` | `5756534883ec20488d3582827900` | 1 |
| `record` | `0x482590` | `0x481990` | `.text` | `4154555756534881ecb00000000f` | 8 |
| `before_submit` | `0x480910` | `0x47fd10` | `.text` | `803df5467f00007427488b156047` | 1 |
| `after_submit` | `0x4808b0` | `0x47fcb0` | `.text` | `4883ec28803d51477f0000744448` | 1 |
| `renderer_reset` | `0x480e40` | `0x480240` | `.text` | `555756534881ec08010000baffff` | 1 |

Each replacement is the existing guarded 14-byte in-memory jump, `ff2500000000` followed by the helper entry VA in little-endian form. The exact new RVA, raw offset, section and original bytes came from the local 0.40.0 binary. No external patch table supplied them. `target-0.40.0.json` also records the read bindings and function ends. The original DLL remains unchanged on disk.

## Validation

- The manifest inspector accepted only the exact candidate SHA-256, AMD64 machine and 0.40.0.0 file version.
- The helper rebuilt from `target-0.40.0.h`. The rebuilt, bundled and app-packaged DLL hashes all matched: `4d1bb52a9d636d5e11f56d8aa802c3c1883f817a2e269e5359f81518825875a2`.
- An isolated guard probe mapped the candidate PE image. Original and already-patched images returned success, with the latter recognized as a no-op. A changed patch entry and changed read signature returned `ERROR_INVALID_DATA` (13). Wrong AMD64 machine, wrong PE timestamp and the old 0.39.1 client returned `ERROR_REVISION_MISMATCH` (1306). Calling the helper from the probe process returned `ERROR_ACCESS_DENIED` (5). The disposable Wine prefix was stopped and removed.
- A live launch with the rebuilt Mac app and the same 0.40.0 client, Steam bottle and local server initialized the helper with code 0. The client loaded CEF 154.0.32, rendered its first web frame, reported chat, scoreboard and shop drawn by the web layer, and notified the server that the web layer was ready. The helper recorded its first overlay draw after native loading ended. The game reached the world. The launch log is `~/Library/Logs/KCDMP CEF/launch-C427176F-799A-4E16-A411-F2E4FB08F9C8.log`.
- A second consecutive launch in the same Steam session also reached the world. The client again reported chat, scoreboard and shop drawn by the web layer, and the helper recorded its first overlay draw. Its launch log is `~/Library/Logs/KCDMP CEF/launch-3A5ADBED-B744-4FD2-8133-C2AFB3A50339.log`. The read-only host probe recorded 15,927 samples over 180 seconds with read and execute protection throughout. The user asked to keep this game running for their own test, so it was not stopped by the agent.
- The read-only host VM probe took 8,344 samples during this live launch. Every sample of the faulting `ntdll.dll` address reported read and execute protection. The game was deliberately stopped after reaching the world, so its launcher returned code 1. This code is an expected result of that test termination, not evidence of a crash.
- A later 0.40.0 launch on public server `179.198.218.192:27877` reached the world with CEF running and the helper's first overlay draw recorded. The user reported that it crashed after joining this server from the local server and taking about two steps. At 20:18 Europe/Prague on 2026-10-08, the game reported an access violation at `WHGame.dll+0xb5989a` while reading address `0x1` on the main game thread. The preceding client log includes remote NPC and animal spawns. This differs from the earlier Wine `ntdll.dll` execute-access faults on the CEF UI thread. The report does not establish whether server content, the base game, the MP client or the Mac helper caused it. No host-page probe was attached to this public-server run. The launch log is `~/Library/Logs/KCDMP CEF/launch-12F0EB4E-9700-4CE0-AFD5-BF1F7A5EB325.log`, and the client report is `crash-20261008-201832.txt` in the bottle's KcdMp local data directory.
- A second launch on that public server crashed at 20:20 Europe/Prague on 2026-10-08. Its report has the same `WHGame.dll+0xb5989a` read from `0x1` on the main game thread and the same leading stack frames. CEF 154.0.32 was running and the helper initialized successfully. The log again shows remote NPC spawns immediately before the crash. The matching fault makes this a repeatable public-server symptom, but it does not identify the faulty component or prove that any particular NPC caused it. The launch log is `~/Library/Logs/KCDMP CEF/launch-BCB028BC-2586-42F8-9CF7-94D1C719ACB8.log`, and the client report is `crash-20261008-202046.txt`.
- A third launch on that public server crashed at 20:23 Europe/Prague on 2026-10-08 with the same `WHGame.dll+0xb5989a` read from `0x1` and the same leading stack frames. The faulting instruction in the installed game image is `movq (%rdi), %rax`. The report does not establish why the game reached an invalid pointer. The helper initialized successfully and CEF 154.0.32 was running. The `/Applications/KCDMP Mac.app` launcher executable and helper DLL have the same SHA-256 values as the project build. The launch log is `~/Library/Logs/KCDMP CEF/launch-3B3F589A-0902-4FE9-9431-9D18E4838F8B.log`, and the client report is `crash-20261008-202329.txt`.
- A fourth app launch on that server crashed at 20:26 with the same `WHGame.dll` fault and CEF active. Its client report is `crash-20261008-202602.txt`.
- A controlled launch at 20:27 used the official `KcdMp_launcher.exe` in the same Steam bottle and on the same public server, without starting the compatibility watcher or loading the helper. It crashed at `WHGame.dll+0xb5989a` while reading `0x1`, with the same leading stack frames. CEF 154.0.32 reported `failed (the ready fence or the event query failed)`, as expected for the unmodified client on this runtime. This rules out the helper as a necessary condition for this specific public-server crash. It does not identify whether the server scripts, MP client, base game or Wine caused it. The client report is `crash-20261008-202742.txt` in the bottle's KcdMp local data directory. The temporary test launcher and its log were removed after recording the result.
- The test app passed `codesign --verify --deep --strict` with an ad hoc signature. It is not signed with a Developer ID and is not notarized. CrossOver CEF behavior and repeated-launch stability remain unverified.

## Integration

The 0.40.0 target is selected in `patch_guard.h`. `CEFLauncher.swift` selects the helper only for the exact 0.40.0 DLL hash and uses the official direct path for an unknown client. The 0.39.1 target files remain for review, but the current app bundles only the 0.40.0 helper. The removal condition is an upstream KCD:MP client path that provides equivalent CPU CEF composition under Wine.
