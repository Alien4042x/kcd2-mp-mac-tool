# KCD:MP 0.44.0 CEF candidate evidence

## Target and baseline

- Process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect <server-address> --name <player> --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version `0.44.0.0`
- Client SHA-256: `af571d1971fe3ea8cc76a3dd4f5f4c34127e9b6c87596f7195c4226c160a7fd6`
- PE timestamp: `1792076245`, image size: `15896576` bytes
- Runtime for the earlier controlled result: the owner's WineForge Steam bottle and its configured graphics backend

The earlier 0.42.0 baseline showed that the unmodified client could not create the ready fence or event query for CPU-composited CEF frames, so the interface stayed native. The exact-version in-memory helper then initialized and the owner reported visible web panels. That controlled result identifies the compatibility behavior. A live 0.44.0 game result has not yet been obtained. The installed game client was not changed for this review.

The official 0.42.0 and 0.44.0 Windows archives matched the publisher's SHA-256 files. Their archive hashes are `589c895eb05af719a69b897c3d66bb0961d004919764cb45ec244211983936fb` and `97fcd1926e8c20b78fbd76344f4e21b88ebcc6befccda2afaa32fde236a8a823` respectively. The previous DLL matched the reviewed 0.42.0 manifest before comparison.

## Instruction mapping

The unique `popup_rect` and `renderer_reset` entries anchored the frames and compositor groups. Both groups moved by `+0x792c0`. The 15 mapped functions retained their unwind sizes and all 1,597 instructions matched after relocation normalization. The 175 internal branches preserved their relative targets, 47 external branches and 78 data targets mapped consistently, and 26 referenced read-only data values matched. The paint flag remained in the reviewed writable section and its reading function was found through the exact RIP reference.

| Function | RVA | Raw offset | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | ---: |
| `frames_open` | `0x623d70` | `0x623170` | `415641554154555756534881ec40` | 8 |
| `frames_paint` | `0x626340` | `0x625740` | `56534883ec4848833d7a688a0000` | 1 |
| `popup_paint` | `0x6259d0` | `0x624dd0` | `56534883ec4848833dea718a0000` | 1 |
| `popup_rect` | `0x623870` | `0x622c70` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x625800` | `0x624c00` | `4883ec2848833dbc738a0000745a` | 1 |
| `frames_latest` | `0x6238b0` | `0x622cb0` | `5756534883ec20488d3522928a00` | 1 |
| `record` | `0x5c4ac0` | `0x5c3ec0` | `4154555756534881ecb00000000f` | 9 |
| `before_submit` | `0x5c2e40` | `0x5c2240` | `803da5859000007427488b151086` | 1 |
| `after_submit` | `0x5c2de0` | `0x5c21e0` | `4883ec28803d0186900000744448` | 1 |
| `renderer_reset` | `0x5c3370` | `0x5c2770` | `555756534881ec08010000baffff` | 1 |

All listed entries are in `.text`. `inspect_pe_patch.py` verified each RVA, raw offset, original bytes, image hash and occurrence count. Uniqueness was required only for entries with one occurrence. Each replacement remains a guarded 14-byte in-memory jump to the matching helper function. Its final target address is resolved at runtime. The client DLL on disk remains unchanged.

## Validation and integration state

- The exact 0.42.0 to 0.44.0 candidate preparation succeeded in a temporary checkout. Its target manifest, helper header and generated Swift source agree on the 0.44.0 DLL hash.
- The helper rebuilt with the pinned MinGW compiler. `verify_release_binary.py` found no difference from the shipped helper except PE build timestamps and checksum.
- The Xcode Release build succeeded with `CODE_SIGNING_ALLOWED=NO`. The app has only an ad hoc linker signature and no Team ID. The complete app ZIP passed archive integrity checks.
- A disposable copy with one changed byte in `frames_paint` was rejected by `prepare_candidate.py` before it produced a target manifest. It reported the first instruction changed from `pushq %rsi` to `pushq %rdi`.
- The wrong-client hash, architecture, process, original-signature and already-patched runtime guards remain in the same reviewed source. Runtime negative tests and a live patched game test for 0.44.0 are pending.
- This candidate was first built in a disposable checkout. The clean 0.44.0 source tree selects this exact target for testing and contains no older bridge targets. It remains an experimental candidate until a live Mac game test confirms its web panels.

The baseline and candidate require the same Steam bottle, graphics backend, server and game settings for a live A/B check. The candidate stays unpublished until web panels and game stability are verified in a live Mac session.
