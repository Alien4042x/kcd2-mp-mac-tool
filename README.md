# KCD2MP Mac

An unofficial macOS launcher for [KCD:MP](https://kcd-mp.com/), the multiplayer mod for Kingdom Come: Deliverance II. It uses your running Windows Steam session and the official KCD:MP launcher. You need your own Steam copy of KCD2. The game and multiplayer client are not included.

## The 0.50 rebuild

KCD:MP 0.50 changed how joining works: external launchers now open a server's details, and the official launcher's **Join** button starts the game. This required a substantial rebuild of the Mac app. See the [official 0.50 changelog](https://kcd-mp.com/changelog).

The new app displays the original launcher interface through macOS WebKit, while the official Windows launcher handles Join and its connection checks. The Mac compatibility helper provides the game's CEF web panels.

**This rebuild is still in progress.** Joining a server, in-game CEF panels and microphone input have worked in local WineForge testing with client 0.50.0. That does not establish long-term stability or support for every launcher feature.

## Install the game and multiplayer mod

1. Install KCD2 through the **Windows Steam client** in your Wine bottle. The verified setup uses WineForge. CrossOver has not yet been tested with the new launcher.
2. Download the **launcher and client ZIP** from the [official KCD:MP download page](https://kcd-mp.com/download).
3. For the currently tested Mac setup, extract **all contents** of that ZIP beside the game's main executable:

   ```text
   .../steamapps/common/KingdomComeDeliverance2/Bin/Win64MasterMasterSteamPGO/
       KingdomCome.exe
       KcdMp_launcher.exe
       KcdMp_client.dll
       ui/
       ...other files from the multiplayer ZIP
   ```

Keep the multiplayer ZIP's other files and its `ui` folder together. Do not copy just the EXE or DLL.

## Install the Mac app

1. Download the Mac ZIP matching your KCD:MP version from [Releases](https://github.com/Alien4042x/kcd2-mp-mac-tool/releases). Older Mac releases use the previous launcher and do not include this 0.50 rebuild.
2. Extract the ZIP and move **KCD2MP Mac.app** to **Applications**. The ZIP contains the complete Mac app and its compatibility files.
3. Keep the official multiplayer files in the game folder. On first launch, select `KcdMp_launcher.exe` there if asked. The app remembers this path.

You do not need Python, Xcode or a separate CEF installation to use a packaged Mac release.

## Play

The verified flow in the new launcher is:

1. Start **Windows Steam in the same bottle as KCD2** and leave it running. Let pending game updates finish.
2. Open the new Mac launcher.
3. Enter your name, choose a server and press its **Join** button. **Refresh** updates the server list and player counts. Use **Direct connect** to enter an address.
4. Allow microphone access if macOS asks and you want voice chat.

The original launcher interface provides favourites, history and settings. There is no extra Mac audio panel. Keep the Mac launcher running while playing. Its Windows backend runs without a separate Dock icon in the tested WineForge setup and still handles the official Join.

## Known issues

- Closing the Mac launcher currently also ends the game. Keep it open while playing.
- The Windows launcher backend does not always close cleanly. The Mac app waits briefly, then terminates its own backend process. Orderly shutdown still needs work.
- Wine processes can remain running after exit. You may need to end the leftover KCD:MP game or launcher process manually in macOS **Activity Monitor** before launching again.

CrossOver and the full range of official launcher features, including Discord sign-in, have not been verified.

## Updates

Steam updates KCD2. The official KCD:MP launcher provides multiplayer client updates. The Mac app and its CEF compatibility helper are separate components. Updating the multiplayer client does not automatically update the Mac helper.

The CEF helper is tied to an exact verified client DLL. A new client may need a new helper and Mac app build. It must not be used with an unverified DLL.

New Mac builds are prepared automatically when a new official client passes the compatibility checks. After testing and publication, download the matching Mac ZIP from Releases. The Mac app does not update itself.

## Source

The new native WebKit host and application-local WebView2 bridge are in [`webview-bridge`](webview-bridge/STATUS.md). CEF helper, loader and watcher sources are in [`cef-source`](cef-source/README.md). The main Xcode project builds the new WebKit launcher. Developer build and draft-release details are in [automatic builds](docs/automatic-builds.md).

This community project is not affiliated with Warhorse Studios, Steam or the KCD:MP team.
