# KCD:MP for Mac

A small native macOS launcher for [KCD:MP](https://kcd-mp.com/). It shows multiplayer servers and starts the official Windows KCD:MP client in the same bottle as a running Windows Steam client. You need your own Steam copy of Kingdom Come: Deliverance II. This repository does not include the game or the multiplayer client.

**CEF support is experimental.** The bundled compatibility helper supports the exact KCD:MP 0.40.0 client in WineForge. Its target functions were compared with the reviewed 0.39.1 client, isolated compatibility checks passed, and two consecutive local-server starts rendered the web interface. Earlier sessions intermittently crashed during level loading inside Wine's `ntdll.dll`. Repeated 0.40.0 sessions on the same public server then crashed at the same `WHGame.dll` address after reaching the world. One controlled launch reproduced that exact fault without the CEF helper, so the helper is not required for this public-server crash. Its cause is still unknown. CrossOver CEF behavior has not been tested. This build is for local testing, not a stable public release.

## Install

1. Install Kingdom Come: Deliverance II through the **Windows Steam client** in a WineForge or CrossOver bottle.
2. Install the **KCD:MP launcher and client** from the [official KCD:MP download page](https://kcd-mp.com/download). Connect checks for client updates and installs the latest official release.
3. In that same Wine bottle, find the folder containing the game's main executable:

   ```text
   .../steamapps/common/KingdomComeDeliverance2/Bin/Win64MasterMasterSteamPGO/KingdomCome.exe
   ```

4. Extract **all contents** of the KCD:MP ZIP into that folder, next to `KingdomCome.exe`. You should now see `KcdMp_launcher.exe` and `KcdMp_client.dll` there too. Keep the ZIP's other files and `ui` folder with them.
5. Build the Mac app from this repository: open `KCDMP Mac.xcodeproj` in Xcode, select the **KCDMP Mac** scheme, and choose **Product → Build**. You can also run `./build.command` to make `KCDMP Mac.app` next to the project.

## Play

1. Start the **Windows Steam client in the same WineForge or CrossOver bottle** as KCD2. Leave Steam running while you play. Let any pending KCD2 update finish.
2. Open `KCDMP Mac.app`.
3. If the app does not find the multiplayer file automatically, click **Change…** and select the `KcdMp_launcher.exe` you placed next to `KingdomCome.exe`. This is a one-time choice.
4. Enter your nickname, select a server, and click **Connect**. Use **Refresh** to fetch the latest server list and player counts whenever you want. The Mac app loads the bundled CEF compatibility helper automatically for the supported WineForge client. You do not need to run a separate test script or install Python.

For a private server, enter its password. To join by address, use the **Direct address** field with `host:port`. Older server versions appear in orange.

The Mac app uses the running Steam process to identify the selected bottle. Connect verifies Steam's Wine prefix and active wineserver before starting another Windows process. On CrossOver it also uses Steam's exact CrossOver installation and bottle name. If the session cannot be verified, Connect stops instead of launching with guessed settings. The CEF helper checks that WineForge is using its configured D3DMetal backend and runs only with its verified client DLL. It temporarily enables KCD:MP's `server_ui` preference and restores its previous value after the game exits or a handled launch error. A forced app quit or system shutdown can prevent that restoration.

After the game closes, you can click **Connect** again in the same Mac app window. The app checks for an existing KCD2 or Wine debugger process in the selected bottle before an update or launch. It also reads the official launcher's crash report marker, because the launcher can exit with code 0 after the game crashes. If a confirmed crash leaves an exact game or debugger process observed during this session, the app closes only that process. Steam and its wineserver stay open. A game process still running after the launcher exits keeps Connect unavailable until that game closes. The current helper keeps the original loading screen on this Mac while a level loads. A live 0.40.0 launch recorded the first CEF overlay frame, and the local server's chat, scoreboard and shop were drawn by the web layer. Servers without a web interface still show the native KCD:MP windows.

CrossOver still uses the original launch path without the CEF helper. Its command receives a Windows `C:\...` path to the selected launcher. That command format was checked against the installed CrossOver wrapper and [CodeWeavers' guide](https://www.codeweavers.com/support/docs/crossover-mac/index). There is no KCD2 installation in a CrossOver bottle here, so actual game launch and CEF behavior in CrossOver are not yet verified.

## Updates

**Connect checks for KCD:MP updates.** For a server on the latest version, it installs the latest official client before joining. When a selected public server is still on an older major/minor version, it leaves the installed client alone. On the exact 0.40.0 DLL it uses the bundled CEF helper. For a newer release or changed DLL it tries the official client directly, without injecting the older helper. The game may run without the Mac CEF interface until that release is tested. Direct addresses have no version information, so Connect follows the latest official release for them. The launch script also has an explicit `--update-only` action for manual use.

Steam updates the base game. The Mac app itself does not auto-update. The official updater handles ordinary KCD:MP client updates without a new Mac app or Git commit while its command line remains compatible. A new reviewed helper and signed Mac build are needed to restore CEF support after an incompatible client DLL change. The 0.40.0 release uses protocol 82, while 0.39.x uses protocol 77, so servers also need to update before a 0.40.0 client can join them.

GitHub Actions builds the Xcode project on every push and checks for new official KCD:MP releases every six hours. It saves an **unsigned test artifact** for each build and an unpublished draft for each new upstream version. See [automatic builds](docs/automatic-builds.md). It never publishes a signed release or uses an Apple certificate. For a local build, run `./build.command`. Set `KCDMP_SIGNING_IDENTITY` to your own Developer ID Application identity when making a signed build. Review CEF changes before distributing a new helper.

The official **Compatible** interface setting selects CPU frames. The observed WineForge run already selected that CPU path but could not create its ready fence or event query, so the game kept its native interface. A durable fix needs a supported CPU composition path in the KCD:MP client. The [upstream request](cef-source/client_compat/UPSTREAM-CEF-REQUEST.md) records the evidence and proposed client change.

## Source code

The Swift/Xcode launcher source is in this repository. The source for our CEF compatibility DLL, loader and watcher is in [`cef-source`](cef-source/README.md). Xcode packages only the compiled helper files from `cef-compat`. The game, KCD:MP client and Chromium/CEF source are not included.

This is an unofficial community tool and is not affiliated with Warhorse Studios, Steam, or the KCD:MP team.
