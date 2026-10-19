# Automatic Mac builds

The **Build Mac launcher** workflow builds the committed Xcode project on pushes, pull requests and manual runs. These are unsigned development artifacts.

The **Prepare Mac CEF candidate** workflow checks the [official KCD:MP releases](https://github.com/dintech-rappy/kcd-mp-releases/releases) once a day or when manually started. It compares the current upstream version with ZIP assets already attached to this repository's releases, including drafts and releases whose tags were renamed. It only builds a candidate when the matching Mac ZIP is absent. When a new client appears, it downloads the previous reviewed client and the new client directly from the publisher, checks both release archive hashes, and compares the exact functions used by the Mac CEF helper. If their instructions, branch relationships, referenced read-only data, function sizes or required writable bindings change, the workflow stops. It never uses a changed client with an older helper.

When those checks pass, the workflow builds a new exact-version helper and Mac app in its temporary checkout. For the already selected exact client, it verifies the official DLL and packages the current app. It saves one ZIP containing the complete unsigned Mac app in an unpublished draft release tagged `cef-ci-vX.Y.Z`. GitHub shows the ZIP's SHA-256 digest on the release page. The checksum file and target manifest remain in the internal Actions artifact. New candidates also include a comparison report there. No commit or manual Git push is needed for a new candidate. The candidate remains unpublished until someone verifies the web panels and game stability in a live Mac session. A GitHub build cannot run KCD2 or prove that CEF renders in the game.

The draft is titled `KCDMP Mac for KCD:MP vX.Y.Z`. Its short description identifies the unsigned test build, asks for the remaining in-game check and links to the official KCD:MP release notes.

The Xcode project generates `CEFClientTarget.swift` from the selected verified client manifest before compiling. The app's version and SHA-256 are never typed into the launcher by hand. The build checks that the manifest, CEF helper header and generated Swift file agree.

When a new exact target is staged, the staging script removes older target headers, manifests and evidence files from that checkout. The scheduled workflow uses a temporary checkout, so its draft build does not commit those changes to `main`.

The Mac app still checks for and installs official KCD:MP client updates when Connect is clicked. The app itself does not yet download a new CEF helper. A candidate must be tested and released before users install that newer app. If a future client changes the reviewed CEF functions, the scheduled workflow fails safely and the upstream developer needs to fix Wine's CPU frame path or the adapter needs a new manual review.
