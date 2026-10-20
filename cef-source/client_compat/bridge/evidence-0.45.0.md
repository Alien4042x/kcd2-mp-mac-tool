# KCD:MP 0.45.0 CEF candidate evidence

## Target and failure

- Process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect <server-address> --name <player> --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version `0.45.0.0`
- Client SHA-256: `611d39351960e8c9c6b0eb6cc4a29b992770c245472838ea92115c9b290e7647`
- PE timestamp: `1792499297`, image size: `16449536` bytes
- Runtime for earlier controlled CEF result: the owner's WineForge Steam bottle and configured graphics backend

The controlled 0.42.0 test described in the prior evidence showed native panels with the unmodified client and visible web panels after the exact-version CPU frame bridge loaded. The exact 0.44.0 client was the prior reviewed target. The GitHub Actions run `39433797853` selected 0.45.0 and verified the official archives, then refused the automatic port because `record` grew from 964 to 980 unwind bytes. No 0.45.0 game test has been run for this candidate. The installed local 0.45.0 client matches the official archive DLL hash. The local 0.44.0 server refuses the 0.45.0 client at the protocol check, before the game starts.

The official 0.44.0 and 0.45.0 client archives passed their publisher SHA-256 checks. Their archive hashes are `97fcd1926e8c20b78fbd76344f4e21b88ebccda2afaa32fde236a8a823` and `8dd4f43d0becba0081d3b804b0fb0f3d1c684d8f00630820fc98e9111b89ef0f` respectively. The previous DLL matched the 0.44.0 manifest hash before comparison.

## Instruction mapping

The `popup_rect` and `renderer_reset` anchors moved by `+0x51fc0` and `+0x51f70`. The `before_submit` and `after_submit` entries moved by `+0x51f60`. Nine patch functions and five read functions retained their unwind sizes and matched across 1,345 normalized instructions. The changed `record` callback kept the same 14-byte entry and the same registration slot. Its reviewed range has 252 old and 256 new instructions, with 240 aligned identical instructions. Its changed branches select the same loading, menu and game-screen strings plus a changed condition. The helper replaces this callback, so its new internal branch is not executed when the helper is active. That replacement remains experimental until a live game check.

| Function | RVA | Raw offset | Original 14 bytes | Occurrences |
| --- | ---: | ---: | --- | ---: |
| `frames_open` | `0x675d30` | `0x675130` | `415641554154555756534881ec40` | 8 |
| `frames_paint` | `0x678300` | `0x677700` | `56534883ec4848833ddaba8d0000` | 1 |
| `popup_paint` | `0x677990` | `0x676d90` | `56534883ec4848833d4ac48d0000` | 1 |
| `popup_rect` | `0x675830` | `0x674c30` | `4101c8660f6ec1660f6eda4101d1` | 1 |
| `popup_show` | `0x6777c0` | `0x676bc0` | `4883ec2848833d1cc68d0000745a` | 1 |
| `frames_latest` | `0x675870` | `0x674c70` | `5756534883ec20488d3582e48d00` | 1 |
| `record` | `0x616a30` | `0x615e30` | `4154555756534881ecb00000000f` | 9 |
| `before_submit` | `0x614da0` | `0x6141a0` | `803d65d89300007427488b15d0d8` | 1 |
| `after_submit` | `0x614d40` | `0x614140` | `4883ec28803dc1d8930000744448` | 1 |
| `renderer_reset` | `0x6152e0` | `0x6146e0` | `555756534881ec08010000baffff` | 1 |

All entries are in `.text`. The PE inspector verified each original signature, RVA, raw offset and occurrence count. Uniqueness was required only for the eight entries that have one occurrence. Each replacement is the guarded 14-byte in-memory jump `ff2500000000` followed by the little-endian helper entry address resolved at runtime. No client file is changed on disk. Read bindings and the two read checks were mapped separately and checked against the new client.

## Validation and limits

- Baseline command: `KcdMp_launcher.exe --connect 127.0.0.1:27877 --name <player> --wait` with the unmodified 0.45.0 client. Outcome: protocol 111 rejected by the local protocol 100 server before game startup. This does not test CEF behavior.
- Patched command: same command through the candidate Mac app after updating to a matching 0.45.0 server. Outcome: pending. There is no matching local server yet.
- The 0.45.0 candidate was staged in a temporary source copy. The exact target manifest, generated Swift target and helper header agree on the DLL SHA-256.
- The helper rebuilt with the local MinGW compiler. The shipped copy and independent rebuild match after normalizing only PE build timestamps and checksum.
- The unsigned Xcode Release app built successfully. Its resource DLL hash matches the staged helper. The app ZIP passed archive integrity checks. This is an ad hoc or unsigned test artifact, not a notarized release.
- The current GitHub release list has no `KCDMP-Mac-v0.45.0.zip` asset. The selector returns `build=current` with the staged target, so the workflow would take its already-selected branch and create a draft after a push.
- Wrong-process, wrong-architecture, wrong-signature and already-patched runtime guards are unchanged from the earlier reviewed source. A live 0.45.0 negative test and patched game test are pending.

This candidate is outside the active repository. It has not been committed, pushed, published, signed with Developer ID or run in a game. The Mac compatibility helper should stay in a draft until its web panels and stability are checked against a matching 0.45.0 server.
