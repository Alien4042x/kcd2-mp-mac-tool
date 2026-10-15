# macOS host page probe

`macos_ntdll_page_probe` watches the actual macOS protection of one mapped `ntdll.dll` address in an existing Wine process. It reads `PROC_PIDREGIONINFO` every 10 ms and prints protection changes and one status line per second. It does not attach to the process, inject code, change memory, or stop Wine.

Build with `./cef-source/client_compat/probe/build.sh` from the repository root. The binary stays in the ignored `probe/bin` directory and is not packaged in the Mac app.

For the current WineForge build, run the watcher before clicking Connect in the Mac app:

```sh
./cef-source/client_compat/probe/watch-next-game.sh
```

It builds the probe, waits for the next KCD:MP game process and writes a timestamped log on the Desktop. It runs for up to 180 seconds, or stops sooner when the game process exits. Press Ctrl-C if you cancel the game launch. Run it again before a second Connect attempt. The watcher uses the current WineForge fault address. For a different Wine build, set `KCDMP_PROBE_ADDRESS` to the address in that build's crash report.

For a live game test, record the macOS PID of the exact `KingdomCome.exe` process in the selected Steam bottle. Start the probe soon after Connect, using the fault address from that Wine build's crash report. For the current WineForge build, the repeatedly faulting `ntdll.dll+0x5d30c` maps to `0x6ffffff8d30c`:

```sh
./cef-source/client_compat/probe/bin/macos_ntdll_page_probe MAC_GAME_PID 0x6ffffff8d30c 120 > /private/tmp/kcdmp-ntdll-page.log
```

The probe refuses an address outside `ntdll.dll`. `protect=5` means macOS reports read and execute permission. An `execute=0` change immediately before a crash would support a host-page protection problem. If the page remains executable, the observed access fault needs a different explanation or a shorter transient than the 10 ms sampling interval. The probe does not identify which component changed a protection. The previous Windows `VirtualQuery` checks reported executable protection before and after CEF loading, so this probe checks a different layer.

Compare launches on the same KCD:MP client, server, Wine bottle and web preference. Run one with the verified CEF helper and one without it, then repeat if the crash remains intermittent. Save the probe output beside the launch log and client crash report. Stop each test's game process before starting the next. Do not stop Steam or its wineserver between paired runs.
