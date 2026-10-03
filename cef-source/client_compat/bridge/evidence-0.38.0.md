# KCD:MP 0.38.0 CEF adapter evidence

## Target and observed failure

- Process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version 0.38.0.0
- SHA-256: `20740fd5c119f7ba90a5137bbde62e5e43cd6b2d256e7996f945873842478a80`
- Runtime: installed WineForge Steam bottle with D3DMetal, with Steam running
- Trigger: `KcdMp_launcher.exe --connect 127.0.0.1:27877 --name Alien4042x --wait`
- Baseline on 0.37.0: three 2026-10-03 Connect attempts returned `protocol 68 not supported (server speaks 69)`. Those attempts stopped before game and CEF startup. The previous CEF bridge had rendered in other 0.37.0 runs, but some launches had an unrelated startup crash.
- Official `--update-check` reported the available 0.38.0 release and protocol 69. Official `--update` completed successfully. The previous launcher and client were copied to `/private/tmp/kcdmp-pre-038` before updating.

## Instruction mapping

The client includes COFF symbols. Each RVA below was independently derived from the 0.38.0 file's symbol table and mapped through its PE section table. The replacement is a guarded in-memory `FF 25 00 00 00 00` absolute jump followed by the local helper entry address. The client DLL on disk remains unchanged.

| Function | RVA | Raw offset | Section | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | --- | ---: |
| `frames_open` | `0x4394a0` | `0x4388a0` | `.text` | `415641554154555756534881ec40` | 6 |
| `frames_paint` | `0x43ba70` | `0x43ae70` | `.text` | `56534883ec4848833d4ae06f0000` | 1 |
| `popup_paint` | `0x43b100` | `0x43a500` | `.text` | `56534883ec4848833dbae96f0000` | 1 |
| `popup_rect` | `0x438fa0` | `0x4383a0` | `.text` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x43af30` | `0x43a330` | `.text` | `4883ec2848833d8ceb6f0000745a` | 1 |
| `frames_latest` | `0x438fe0` | `0x4383e0` | `.text` | `5756534883ec20488d35f2097000` | 1 |
| `record` | `0x3eb9b0` | `0x3eadb0` | `.text` | `4154555756534881ecb00000000f` | 8 |
| `before_submit` | `0x3e9d30` | `0x3e9130` | `.text` | `803d15e77400007427488b1580e7` | 1 |
| `after_submit` | `0x3e9cd0` | `0x3e90d0` | `.text` | `4883ec28803d71e7740000744448` | 1 |
| `renderer_reset` | `0x3ea260` | `0x3e9660` | `.text` | `555756534881ec08010000baffff` | 1 |

The 0.37.0 and 0.38.0 builds have the same function sizes for all ten patched entries. `review_target.py` compared all 1,603 instructions across these ten functions and five additional read-only API functions. It normalized only addresses of relative branches and RIP references. Sixteen `.rdata` references had their pointed-to bytes checked. All reviewed instructions and data matched. The two guarded loading API signatures and all read-binding RVAs were generated from the new symbols. The full version-specific record is `target-0.38.0.json`.

The original functions implement CEF CPU frame capture, popup handling, publication of the latest frame, and composition callbacks. On this Mac the replacements move those CPU frames into the game's D3D12 rendering path. They also keep the original native loading display until the loading phase ends. These are internal client functions, so a new version still needs review and live verification.

## Validation

- Candidate derivation: `KCDMP_TARGET_SHA256=20740fd5c119f7ba90a5137bbde62e5e43cd6b2d256e7996f945873842478a80 KCDMP_TARGET_VERSION=0.38.0 python3 cef-source/client_compat/bridge/inspect_target.py`, passed.
- Static correspondence: `python3 cef-source/client_compat/bridge/review_target.py --previous-client /private/tmp/kcdmp-pre-038/KcdMp_client.dll --previous-manifest cef-source/client_compat/bridge/target-0.37.0.json --candidate-client <installed-client> --candidate-manifest cef-source/client_compat/bridge/target-0.38.0.json`, passed all 15 functions. `<installed-client>` stands for the full installed DLL path.
- Isolated passive-copy test: `/private/tmp/kcdmp-run-guard-038.py`, passed. It mapped a disposable copy without calling the client's DllMain. It verified the original image, guarded patch, rollback after injected instruction-cache flush failure, repeat apply, loading handoff, code protections and unchanged disk hash.
- Negative cases passed: wrong process, wrong AMD64 machine, wrong PE timestamp, modified entry bytes and modified loading API signatures. Already-patched bytes were recognized as a no-op.
- The test used only a disposable Wine prefix and stopped its own wineserver. It did not launch the game or stop the running Steam bottle.
- One 0.38.0 live launch ran at 2026-10-03 21:45 Europe/Prague. The server accepted the updated protocol and the helper initialized with exit code 0. CEF 154.0.32 began starting, then Wine reported an execute-access fault at `ntdll.dll+0x5d30c`. The game exited with `0xc0000005` before the helper logged its first overlay draw. The launch log is `~/Library/Logs/KCDMP CEF/launch-3D86ED17-8B6C-48B8-9BBA-67A4A1A89653.log`. The previous intermittent startup crash remains unresolved. The adapter must not be described as a stable public release.
- A subsequent 0.38.0 launch at 2026-10-03 21:47 Europe/Prague initialized the helper with exit code 0. The client logged native loading, then the first CEF overlay draw and normal composition. The user confirmed that the CEF interface was visible, but reported that it behaved strangely without yet identifying the symptom. Its launch log is `~/Library/Logs/KCDMP CEF/launch-D6BE1789-7A33-4EC7-B198-3CA12BDE17FB.log`. The CEF GPU process crashed once and restarted during this run. Several D3DMetal fragment pipeline compilations failed. These events have not yet been tied to the reported behavior.

## Provenance and integration

The offset and byte evidence came from the local 0.38.0 binary and its symbols. No third-party patch table was used. The source change adds a separate 0.38.0 manifest and selects it from `patch_guard.h`. The previous 0.37.0 manifest remains for comparison. The rebuilt helper is packaged only in the Mac launcher resources. It does not enter `Server/upload` and does not modify Wine.

No commit or push was made during this review. Startup crash diagnosis and review of the visible CEF behavior are pending.
