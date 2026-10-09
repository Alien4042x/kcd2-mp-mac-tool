# Automatic Mac builds

GitHub Actions builds the Xcode project on every push to `main`, on pull requests, and when started manually. It also checks the [official KCD:MP releases](https://github.com/dintech-rappy/kcd-mp-releases/releases) every six hours. The first check after a new release builds the current Mac launcher and saves an unsigned ZIP and its SHA-256 file as a draft release. Later checks skip that version. A failed build is retried on the next check because no draft was saved.

The draft tag has the form `ci-v0.41.0`. It stays unpublished until the app has been tested, signed with an Apple Developer ID, and notarized. Ordinary build runs also offer an unsigned artifact on their Actions page. No Apple signing certificate is stored in this repository or used by this workflow.

The workflow does not port the CEF helper to a new KCD:MP DLL. For example, a build triggered by 0.41.0 still contains the reviewed 0.40.0 helper and uses the official client directly for 0.41.0. The app checks and downloads the official multiplayer client when you click Connect. GitHub builds only the Mac app.

To download a test build, sign in to GitHub, open the repository's **Actions** tab, choose a successful **Build Mac launcher** run, and download its artifact at the bottom of the run page. Extract the artifact ZIP, then extract the `KCDMP-Mac-test-build.zip` inside it. This is an unsigned test app. The draft under **Releases** is not a public download for ordinary users. They need a reviewed, signed and notarized release to get a normal download link.

The Mac app checks for KCD:MP client updates when you press Connect. Its bundled CEF helper is gated to an exact reviewed client DLL. A new client version uses the official direct launch path until its CEF behavior is reviewed. A successful GitHub build does not prove that the new client renders CEF panels or that the game is stable under Wine.

To get a Developer ID release, sign and notarize the tested app with your own Apple credentials before publishing the draft. Automating that step later requires securely configured GitHub Actions signing and notarization secrets.
