# KCD:MP 0.39.0 CEF adapter evidence

## Target and failure

- Process: `C:\Program Files (x86)\Steam\steamapps\common\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe`
- Trigger: `KcdMp_launcher.exe --connect <server> --name <player> --wait`
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version 0.39.0.0
- Client SHA-256: `bdee653dc4cc6a23973264519d2c7e3543d146a59d541ab6e9ecceb81fc5a85e`
- Official ZIP SHA-256: `a965086650db5a632c2f261719f6171ec500f3f3be85e3a7c040b5d6170a978c`
- Baseline: the existing Mac launcher refused the official 0.39.0 update because its helper targeted 0.38.0. A 0.38.0 launch previously showed the CEF interface with the adapter, after one intermittent startup crash. No 0.39.0 game launch has been performed yet.

## Instruction mapping

The candidate was extracted from the official release ZIP to a temporary directory. Its COFF symbols identify the ten functions used by the in-memory adapter. The generated `target-0.39.0.json` records the PE timestamp, image size, bindings, bytes and function ends. The client DLL on disk is unchanged. The replacement remains a guarded 14-byte jump to the local helper.

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

`review_target.py` compared these ten functions and five read-only functions with 0.38.0. All 1,603 instructions matched after normalizing relative addresses. Sixteen referenced `.rdata` values matched. This supports the same CEF behavior at the new RVAs, but does not establish in-game reliability.

## Validation

- The official archive matched its published SHA-256 before extraction.
- `inspect_target.py` accepted only the exact candidate hash and 0.39.0 file version.
- `review_target.py` passed all 15 functions.
- The helper compiled against the generated 0.39.0 header.
- An isolated Wine guard probe mapped the candidate DLL without calling its entry point. It accepted original and already-patched images. It rejected a changed patch entry, a wrong PE timestamp and a changed read signature. The probe used a disposable Wine prefix and stopped its own wineserver.
- A 0.39.0 game launch and CEF render check remain outstanding. Do not describe this as a stable public release.

## Integration and provenance

Offsets and bytes came from the official 0.39.0 binary and its COFF symbols. The 0.38.0 manifest stays in the repository for comparison. The app selects the 0.39.0 helper only after checking the exact client SHA-256. For later releases or a changed DLL, Connect updates the client and tries the official launcher without injecting this helper.

This change is local and uncommitted. No push was made.
