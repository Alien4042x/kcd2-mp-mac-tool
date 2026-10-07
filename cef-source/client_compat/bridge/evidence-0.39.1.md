# KCD:MP 0.39.1 CEF adapter evidence

## Target and observed failure

- Process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect <server> --name <player> --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version 0.39.1.0
- SHA-256: `1645ae3cd10d8852505e325208c0eeccbf4cbc19a8dc1b87db451f78b8d17c1d`
- PE timestamp: `1791323408`, image size: `12795904` bytes
- Runtime: WineForge Steam bottle with D3DMetal
- Baseline: the Mac launcher with the 0.39.0 helper used its direct launch path for the new DLL. On both a public and local server, the game opened with native interface windows. The local client's log reported `web engine: fallback level 1 (Wine / Proton, CPU frames)`, followed by `the ready fence or the event query failed - the interface stays native`. It received the server's web bundle, then rendered chat, scoreboard and shop natively.

## Instruction mapping

The 0.39.1 DLL was copied from the installed client to a temporary review directory while the game continued running. The original file was not modified. Its COFF symbols identified the ten patched functions and five read-only functions. `review_target.py` compared them against the independently reviewed 0.39.0 binary. All 1,603 instructions in the 15 functions matched at the same RVAs. Sixteen referenced `.rdata` values matched. The only changed top-level manifest fields were product version, PE timestamp and SHA-256.

| Function | RVA | Raw offset | Section | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | --- | ---: |
| `frames_open` | `0x497870` | `0x496c70` | `.text` | `415641554154555756534881ec40` | 6 |
| `frames_paint` | `0x499e40` | `0x499240` | `.text` | `56534883ec4848833d7a01760000` | 1 |
| `popup_paint` | `0x4994d0` | `0x4988d0` | `.text` | `56534883ec4848833dea0a760000` | 1 |
| `popup_rect` | `0x497370` | `0x496770` | `.text` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x499300` | `0x498700` | `.text` | `4883ec2848833dbc0c760000745a` | 1 |
| `frames_latest` | `0x4973b0` | `0x4967b0` | `.text` | `5756534883ec20488d35222b7600` | 1 |
| `record` | `0x43b550` | `0x43a950` | `.text` | `4154555756534881ecb00000000f` | 9 |
| `before_submit` | `0x4398d0` | `0x438cd0` | `.text` | `803d35ef7b00007427488b15a0ef` | 1 |
| `after_submit` | `0x439870` | `0x438c70` | `.text` | `4883ec28803d91ef7b0000744448` | 1 |
| `renderer_reset` | `0x439e00` | `0x439200` | `.text` | `555756534881ec08010000baffff` | 1 |

The replacement is the existing guarded 14-byte in-memory jump to the local helper. The source does not patch the DLL on disk. `target-0.39.1.json` records the read bindings, entry signatures, function ends and PE metadata.

## Official Compatible setting

The installed `ui/launcher.html` maps Interface drawing `Compatible` to `web_gpu: cpu`. The launcher's `web_gpu_args` function maps `cpu` to `-KcdMp_web_cpu 1`. The client's current Wine run already selected fallback level 1 with CPU frames and failed when the ready fence or event query was created. This is strong evidence that the setting alone will not resolve this failure. No preference was changed and no live Compatible test was run while the user's game was open.

## Validation

- Candidate derivation accepted the exact copied client SHA-256 and 0.39.1.0 file version.
- Static comparison passed all 15 functions, 1,603 instructions and 16 referenced data values.
- The helper rebuilt from the 0.39.1 target. The packaged copy matched the rebuilt helper except PE build timestamps and checksum.
- An isolated Wine probe mapped the candidate image without running its DLL entry point. It accepted the original candidate and its already-patched image. It rejected 0.39.0 and a changed entry signature.
- A separate isolated probe called the helper from the wrong process. It returned `ERROR_ACCESS_DENIED` (5).
- Disposable Wine prefixes were stopped and removed. The running game and Steam session were untouched.
- One live launch on 2026-10-07 through the Mac app joined `127.0.0.1:27877`. The helper initialized with exit code 0 for game PID 748. It opened the CPU frame producer, kept the native loading phase, resumed CEF composition and recorded the first overlay draw. The client received web bundle `e2071b08`, loaded CEF 154.0.32, rendered its first frame and reported that chat, scoreboard and shop were drawn by the web layer. The server recorded the web layer as ready. The user confirmed that the web panels were visible. The launch log is `~/Library/Logs/KCDMP CEF/launch-F2DFC926-2E2C-4A91-B1CD-C05714258B1B.log`.
- A preceding live launch on a public server also initialized the helper with exit code 0. That server reported `web interface: none`, so native windows there were expected and did not test web rendering.
- This is still a local test build. CrossOver behavior and intermittent startup stability remain unverified.

## Provenance and integration

The offsets came from the local 0.39.1 binary's COFF symbols and were checked against the official 0.39.0 archive whose published ZIP SHA-256 matched. No external patch table was used. The 0.39.0 manifest remains for comparison. This change is local and uncommitted. No push was made.
