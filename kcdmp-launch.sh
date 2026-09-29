#!/bin/zsh
set -euo pipefail

# Can be used directly or by the macOS app. The launcher path identifies the bottle.
engine=auto
runtime_app=
bottle=
prefix="$HOME/WineForge/Steam"
metal_runtime="$HOME/Library/Application Support/Wine Forge/Runtimes/D3DMetal"
launcher=

usage() {
  cat <<'HELP'
Usage: kcdmp-launch.sh [runtime options] ACTION
Runtime options:
  --engine auto|wineforge|crossover (default: auto)
  --app PATH             WineForge.app or CrossOver.app
  --bottle NAME          CrossOver bottle name (WineForge derives it from prefix)
  --prefix PATH          WineForge bottle directory
  --metal-runtime PATH   WineForge D3DMetal runtime directory
  --launcher PATH        KcdMp_launcher.exe inside the selected bottle
Actions:
  --check-update
  --update-only
  --launch host:port nickname [server-password]
  --browse (or omit the action)
HELP
}

expand_home() {
  local path="$1"
  case "$path" in
    '~') print -r -- "$HOME" ;;
    '~/'*) print -r -- "$HOME/${path#\~/}" ;;
    *) print -r -- "$path" ;;
  esac
}

while (( $# )); do
  case "$1" in
    --engine|--app|--bottle|--prefix|--metal-runtime|--launcher)
      if (( $# < 2 )); then
        print -u2 "Missing value for $1"
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      case "$option" in
        --engine) engine="$value" ;;
        --app) runtime_app="$value" ;;
        --bottle) bottle="$value" ;;
        --prefix) prefix="$value" ;;
        --metal-runtime) metal_runtime="$value" ;;
        --launcher) launcher="$value" ;;
      esac
      ;;
    --help|-h) usage; exit 0 ;;
    *) break ;;
  esac
done

runtime_app="$(expand_home "$runtime_app")"
prefix="$(expand_home "$prefix")"
metal_runtime="$(expand_home "$metal_runtime")"
launcher="$(expand_home "$launcher")"
if [[ -z "$launcher" && "$engine" != crossover ]]; then
  launcher="$prefix/drive_c/Program Files (x86)/Steam/steamapps/Common/KingdomComeDeliverance2/Bin/Win64MasterMasterSteamPGO/KcdMp_launcher.exe"
fi

if [[ -z "$launcher" ]]; then
  print -u2 'Choose the path to KcdMp_launcher.exe in the app.'
  exit 2
fi
if [[ ! -f "$launcher" ]]; then
  print -u2 "KCD:MP launcher not found: $launcher"
  exit 1
fi
if [[ "${launcher:t}" != KcdMp_launcher.exe ]]; then
  print -u2 "Select KcdMp_launcher.exe, not another executable: $launcher"
  exit 2
fi
game_bin="${launcher:h}"

# Steam starts KCD2 with the game's selected locale. Starting the MP executable
# directly misses that handoff, so derive it from the same bottle's appmanifest.
manifest=
if [[ "$launcher" == */steamapps/* ]]; then
  steamapps_dir="${launcher%%/steamapps/*}/steamapps"
  manifest="$steamapps_dir/appmanifest_1771300.acf"
fi
if [[ ! -f "$manifest" && "$launcher" == */drive_c/* ]]; then
  launcher_prefix="${launcher%%/drive_c/*}"
  manifest="$launcher_prefix/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_1771300.acf"
fi
if [[ -f "$manifest" ]]; then
  game_language=$(sed -nE 's/^[[:space:]]*"language"[[:space:]]*"([^"]+)".*/\1/p' "$manifest" | head -n 1)
  if [[ "$game_language" =~ '^[a-zA-Z_-]+$' ]]; then
      export SteamAppLanguage="$game_language"
      case "$game_language" in
        czech) export LANG=cs_CZ.UTF-8 ;;
        english) export LANG=en_US.UTF-8 ;;
        german) export LANG=de_DE.UTF-8 ;;
        french) export LANG=fr_FR.UTF-8 ;;
        italian) export LANG=it_IT.UTF-8 ;;
        spanish) export LANG=es_ES.UTF-8 ;;
        polish) export LANG=pl_PL.UTF-8 ;;
        russian) export LANG=ru_RU.UTF-8 ;;
        japanese) export LANG=ja_JP.UTF-8 ;;
        korean) export LANG=ko_KR.UTF-8 ;;
        portuguese) export LANG=pt_PT.UTF-8 ;;
        brazilian) export LANG=pt_BR.UTF-8 ;;
        turkish) export LANG=tr_TR.UTF-8 ;;
        ukrainian) export LANG=uk_UA.UTF-8 ;;
        schinese) export LANG=zh_CN.UTF-8 ;;
        tchinese) export LANG=zh_TW.UTF-8 ;;
      esac
  fi
fi

if [[ "$launcher" != /*/drive_c/* ]]; then
  print -u2 'Select KcdMp_launcher.exe inside a Wine bottle drive_c folder.'
  exit 2
fi
launcher_prefix="${launcher%%/drive_c/*}"
if [[ "$engine" == auto ]]; then
  prefix="$launcher_prefix"
  if [[ -f "$prefix/cxbottle.conf" ]]; then
    engine=crossover
  else
    engine=wineforge
  fi
elif [[ "$engine" == crossover ]]; then
  prefix="$launcher_prefix"
fi
if [[ "$engine" == crossover && -z "$bottle" ]]; then
  bottle="${prefix:t}"
fi
if [[ -z "$runtime_app" ]]; then
  if [[ "$engine" == crossover ]]; then
    runtime_app=/Applications/CrossOver.app
  else
    runtime_app=/Applications/WineForge.app
  fi
fi

case "$engine" in
  wineforge)
    if [[ -z "$bottle" ]]; then
      bottle="${prefix:t}"
    fi
    wine_root="$runtime_app/Contents/Resources/Engine/WineForgeCore"
    wine_exe="$wine_root/bin/wine"
    wine_server="$wine_root/bin/wineserver"
    for required in "$prefix" "$wine_exe" "$wine_server" \
      "$metal_runtime/wine/x86_64-windows/d3d12.dll" \
      "$metal_runtime/external/D3DMetal.framework/D3DMetal"; do
      if [[ ! -e "$required" ]]; then
        print -u2 "WineForge component not found: $required"
        exit 1
      fi
    done
    export WINEPREFIX="$prefix"
    export WINE="$wine_exe"
    export WINESERVER="$wine_server"
    export WINEDEBUG=-all
    export WINEWFUSYNC=1
    export WINEFORGE_BOTTLE_NAME="$bottle"
    export GRAPHICS_BACKEND=d3dmetal
    export ACTIVE_GRAPHICS_BACKEND=d3dmetal
    export D3DMETAL_RUNTIME_DIR="$metal_runtime"
    export D3DMETAL_FRAMEWORK_PATH="$metal_runtime/external/D3DMetal.framework/D3DMetal"
    export D3DMETAL_LIBD3DSHARED_PATH="$metal_runtime/external/libd3dshared.dylib"
    export WINEDLLOVERRIDES='dxgi=n,b;d3d10=n,b;d3d10core=n,b;d3d11=n,b;d3d12=n,b'
    export WINEDLLPATH="$metal_runtime/wine:$wine_root/lib/wine/x86_64-windows:$wine_root/lib/wine/i386-windows:$wine_root/lib/wine:$wine_root/lib/dxmt"
    export DYLD_LIBRARY_PATH="$wine_root/lib/gstreamer-1.0:$metal_runtime/external:$metal_runtime/wine/x86_64-unix:$wine_root/lib/wine/x86_64-unix:$wine_root/lib:$wine_root/lib/dxmt/x86_64-unix"
    export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
    wine_command=("$wine_exe" "$launcher")
    ;;
  crossover)
    wine_exe="$runtime_app/Contents/SharedSupport/CrossOver/bin/wine"
    if [[ ! -x "$wine_exe" ]]; then
      print -u2 "CrossOver wine wrapper not found: $wine_exe"
      exit 1
    fi
    # CrossOver's wrapper configures the bottle and its graphics backend.
    wine_command=("$wine_exe" --bottle "$bottle" --cx-app "$launcher" --)
    ;;
  *)
    print -u2 "Unknown runtime: $engine"
    exit 2
    ;;
esac

cd "$game_bin"
run_launcher() { "${wine_command[@]}" "$@"; }

case "${1:---browse}" in
  --check-update)
    run_launcher --update-check
    ;;
  --update-only)
    run_launcher --update
    ;;
  --launch)
    if (( $# < 3 )); then
      print -u2 'Usage: --launch host:port nickname [server-password]'
      exit 2
    fi
    address="$2"
    player_name="$3"
    server_password="${4:-}"
    print 'Checking for KCD:MP updates...'
    run_launcher --update
    if [[ -n "$server_password" ]]; then
      run_launcher --connect "$address" --name "$player_name" --token "$server_password" --wait
    else
      run_launcher --connect "$address" --name "$player_name" --wait
    fi
    ;;
  --browse)
    print 'Checking for KCD:MP updates...'
    run_launcher --update
    run_launcher --browse --wait
    ;;
  *)
    print -u2 "Unknown action: $1"
    usage >&2
    exit 2
    ;;
esac
