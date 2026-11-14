# KCD:MP 0.50.0 CEF compatibility evidence

## Exact target

- Process: the selected Steam bottle's `Bin/Win64MasterMasterSteamPGO/KingdomCome.exe`.
- Trigger: the original 0.50 `KcdMp_launcher.exe`, its unmodified `ui/launcher.html` and the user's official Join action through the Mac WebKit bridge.
- Module: `KcdMp_client.dll`, AMD64 PE32+, file version `0.50.0.0`.
- SHA-256: `3fece145db3f40f850e4847be6b266189358c787d2a547c9c072b2b07cdad605`.
- PE timestamp: `1794584508`, image size: `17584128` bytes.
- [Exact manifest](target-0.50.0.json) records each module RVA, raw offset, section, original signature, occurrence count, replacement encoding and read binding. [Generated header](target-0.50.0.h) binds the helper to that same image.

Each replacement is the guarded 14-byte in-memory jump `ff2500000000` followed by the runtime helper address in little-endian order. The original client DLL remains unchanged on disk. No internal launcher address or direct game connection bypass is used.

## Derivation and applicability

The prior reviewed target was 0.45.0, SHA-256 `611d39351960e8c9c6b0eb6cc4a29b992770c245472838ea92115c9b290e7647`. Publisher archives were checked against their published SHA-256 values before comparing the client images.

All ten patch functions and five read functions matched across 1,601 normalized instructions, 178 internal branches and 26 read-only references. The frames and compositor anchors moved by `+0x7c520` and `+0x682b0`. Three predicted frames entries were missing from the new unwind table. A bounded search found unique fully equivalent entries an additional `0x20` away. Changed existing entries, ambiguous candidates, changed branches and mismatched referenced data remain errors.

The relocation checks cover missing predicted entries, changed existing entries, ambiguous matches and failed-candidate mapping isolation. The standalone guard probe checked wrong architecture, changed signatures, already-patched and partial images, bounds and wrong-process refusal without attaching to a game.

The CPU-frame workaround retains the earlier controlled CEF evidence recorded with the preceding helper. The 0.50 observations below establish local functionality, they are not a new controlled measurement of crash frequency or long-term stability.

## Live observations and build verification

- Without the exact helper, original launcher run 002 reached a public server and retained native panels. Its separate local crash does not by itself identify the cause.
- With the exact 0.50 helper, original launcher run 003 logged watcher readiness before official Join and completed helper initialization. The user confirmed visible CEF web panels and working microphone input on the local server.
- The final 14 November Dock test recorded two successful CEF initializations. The user launched the game and confirmed both functionality and removal of the extra launcher icon.
- Closing the Mac launcher also ended that game. This and leftover Wine processes are documented as known issues. CrossOver, long-term stability and the complete original launcher feature set remain unverified.
- The helper rebuilt from these sources and matched the supplied DLL after normalizing only PE build timestamps and checksum. The complete 0.50 Xcode app and its unpacked ZIP passed resource and native self-checks.

The [bridge work state](../../../webview-bridge/STATUS.md) identifies the retained local probe and session records. Their `.build` directories and live logs are excluded from Git. No proprietary client DLL, publisher ZIP, personal signing credential or Wine runtime is included in this evidence.

The user explicitly approved selection of this tested target, the release commit and push on 14 November 2026. Automatic future targets remain draft candidates until reviewed in game.
