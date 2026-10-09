# Request for a stable Wine CEF path in KCD:MP

## Reproduction

On KCD:MP 0.40.0 under WineForge with D3DMetal, join a server that supplies web interface components. The client selects `fallback level 1 (Wine / Proton, CPU frames)` and loads CEF 154.0.32. Without the Mac helper, it then reports `the ready fence or the event query failed - the interface stays native`. The server's web bundle downloads successfully, but chat, scoreboard and other components use their native windows. The same behavior was observed on 0.39.1.

The launcher already has an Interface drawing setting named Compatible. Its `web_gpu: cpu` value adds `-KcdMp_web_cpu 1`. The failing Wine run is already in the CPU-frame fallback level, so selecting Compatible does not appear to avoid the failing synchronization path. A live setting comparison is still needed to confirm this.

## Requested client change

Please provide a supported CPU-frame rendering path for Wine and CrossOver that does not make CEF availability depend on opening a shared D3D12 ready fence or a working event query. CEF's [OnPaint callback](https://github.com/chromiumembedded/cef/blob/master/include/cef_render_handler.h) supplies a BGRA pixel buffer when shared textures are disabled. If the client's own composition step still needs a fence or query, please provide a CPU upload path for those frames. Alternatively, expose a documented stable callback or API for frame pixels, popup rectangles and visibility changes, plus a supported way to submit them to the game's overlay compositor.

The goal is to let the official client update itself without a Mac launcher replacing private CEF and compositor functions after each binary release. A documented compatibility option and a log line naming the selected path would make the behavior testable.

## Current Mac workaround

The Mac helper currently redirects ten private client functions in memory and validates the exact client DLL hash and PE signatures before doing so. Two consecutive 0.40.0 local-server starts rendered the web panels with the helper, while the unmodified client had fallen back to native windows after the ready-fence failure. The helper works only for reviewed versions. A future release can change those functions or data layouts, so automatically applying old offsets to a new binary is unsafe. The client DLL, Wine and server web files remain unchanged.
