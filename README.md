# KCD:MP for Mac

A small native macOS launcher for [KCD:MP](https://kcd-mp.com/). It shows multiplayer servers and starts the official Windows KCD:MP client in the same WineForge or CrossOver bottle as a running Windows Steam client. You need your own Steam copy of Kingdom Come: Deliverance II. This repository does not include the game or the multiplayer client.

## Install

1. Install Kingdom Come: Deliverance II through the **Windows Steam client** in a WineForge or CrossOver bottle.
2. Download the **launcher and client** ZIP from the [official KCD:MP download page](https://kcd-mp.com/download).
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
4. Enter your nickname, select a server, and click **Connect**.

For a private server, enter its password. To join by address, use the **Direct address** field with `host:port`. Older server versions appear in orange.

The Mac app uses the settings of that running Steam process to start the multiplayer client. WineForge was verified locally. CrossOver is supported by the same process lookup and its Wine command, but has not been tested with a running CrossOver Steam installation yet.

## Updates

Before each connection, the Mac app runs the KCD:MP launcher's `--update` command, waits for it to finish, and then connects. You do not need to download each new KCD:MP version manually. Steam updates the base game. The Mac app itself does not yet auto-update. Rebuild it from this repository when a new version is published.

This is an unofficial community tool and is not affiliated with Warhorse Studios, Steam, or the KCD:MP team.
