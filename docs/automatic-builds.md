# Automatic Mac builds

The **Build Mac launcher** workflow builds the committed Xcode project on pushes, pull requests and manual runs. These are unsigned development artifacts.

The **Prepare Mac CEF candidate** workflow checks the [official KCD:MP releases](https://github.com/dintech-rappy/kcd-mp-releases/releases) every six hours. When a new client appears, it downloads the previous reviewed client and the new client directly from the publisher, checks both release archive hashes, and compares the exact functions used by the Mac CEF helper. If their instructions, branch relationships, referenced read-only data, function sizes or required writable bindings change, the workflow stops. It never uses a changed client with an older helper.

When those checks pass, the workflow builds a new exact-version helper and Mac app in its temporary checkout. It saves the app and the target manifest in an unpublished draft release tagged `cef-ci-vX.Y.Z`. No commit or manual Git push is needed for a new candidate. The candidate remains unpublished until someone verifies the web panels and game stability in a live Mac session. A GitHub build cannot run KCD2 or prove that CEF renders in the game.

The draft is titled `KCDMP Mac for KCD:MP vX.Y.Z`. Its description is filled automatically with the verified compatibility and signing status, a link to the official KCD:MP release notes, and the remaining in-game check. GitHub also adds its generated changelog for changes in this repository. That changelog is based on commits and pull requests, not AI, and cannot describe a client update that happened only in the publisher's repository.

The Xcode project generates `CEFClientTarget.swift` from the selected verified client manifest before compiling. The app's version and SHA-256 are never typed into the launcher by hand. The build checks that the manifest, CEF helper header and generated Swift file agree.

## One-time signing setup

The scheduled workflow can sign the candidate with **your Developer ID Application** certificate and notarize it automatically. Add these five repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 of a `.p12` export containing your Developer ID Application certificate and private key |
| `APPLE_P12_PASSWORD` | Password used for that `.p12` export |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_NOTARY_KEY_P8` | Contents of that API key's `.p8` file |

The workflow imports the certificate into a temporary keychain on the GitHub macOS runner. It accepts exactly one Developer ID Application identity, signs with hardened runtime and a timestamp, requires an Accepted response from Apple's notary service, staples the ticket and then places the finished ZIP in the draft. With none of the five secrets configured, it creates an unsigned draft. A partial secret setup stops the build with an error. Credentials never belong in Git, release assets or logs.

For a `.p12` already exported from Keychain Access, generate the Base64 text locally with `base64 -i DeveloperID.p12`. Paste the resulting text into the GitHub secret. Keep the `.p12`, its password and the `.p8` key private. The owner's Developer ID identity is available in the local Keychain, but the GitHub runner cannot read that Keychain. The one-time secret setup gives the runner its own temporary signing identity.

The Mac app still checks for and installs official KCD:MP client updates when Connect is clicked. The app itself does not yet download a new CEF helper. A candidate must be tested and released before users install that newer app. If a future client changes the reviewed CEF functions, the scheduled workflow fails safely and the upstream developer needs to fix Wine's CPU frame path or the adapter needs a new manual review.
