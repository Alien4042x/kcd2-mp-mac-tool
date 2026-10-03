#!/bin/zsh
set -euo pipefail

# The selected MP file identifies the running Steam bottle.
launcher=

usage() {
  cat <<'HELP'
Usage: kcdmp-launch.sh --launcher PATH ACTION
  --launcher PATH        KcdMp_launcher.exe inside the Steam bottle
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
    --launcher)
      if (( $# < 2 )); then
        print -u2 "Missing value for $1"
        exit 2
      fi
      launcher="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) break ;;
  esac
done

launcher="$(expand_home "$launcher")"
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

# The MP launcher starts KCD2 itself, so use the game's language selected in Steam.
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
    locale_name=
    case "$game_language" in
      czech) locale_name=cs_CZ.UTF-8 ;;
      english) locale_name=en_US.UTF-8 ;;
      german) locale_name=de_DE.UTF-8 ;;
      french) locale_name=fr_FR.UTF-8 ;;
      italian) locale_name=it_IT.UTF-8 ;;
      spanish) locale_name=es_ES.UTF-8 ;;
      polish) locale_name=pl_PL.UTF-8 ;;
      russian) locale_name=ru_RU.UTF-8 ;;
      japanese) locale_name=ja_JP.UTF-8 ;;
      korean) locale_name=ko_KR.UTF-8 ;;
      portuguese) locale_name=pt_PT.UTF-8 ;;
      brazilian) locale_name=pt_BR.UTF-8 ;;
      turkish) locale_name=tr_TR.UTF-8 ;;
      ukrainian) locale_name=uk_UA.UTF-8 ;;
      schinese) locale_name=zh_CN.UTF-8 ;;
      tchinese) locale_name=zh_TW.UTF-8 ;;
    esac
    if [[ -n "$locale_name" ]]; then
      export LANG="$locale_name"
      export LC_ALL="$locale_name"
    fi
  fi
fi

if [[ "$launcher" != /*/drive_c/* ]]; then
  print -u2 'Select KcdMp_launcher.exe inside a Wine bottle drive_c folder.'
  exit 2
fi
prefix="${launcher%%/drive_c/*}"
if [[ -f "$prefix/cxbottle.conf" ]]; then
  if [[ -n "${CX_ROOT:-}" && -x "$CX_ROOT/bin/wine" ]]; then
    wine_exe="$CX_ROOT/bin/wine"
  else
    crossover_app=/Applications/CrossOver.app
    if [[ ! -d "$crossover_app" ]]; then
      crossover_app="$HOME/Applications/CrossOver.app"
    fi
    wine_exe="$crossover_app/Contents/SharedSupport/CrossOver/bin/wine"
  fi
  launcher_relative="${launcher#"$prefix/drive_c/"}"
  windows_launcher='C:'
  for component in ${(s:/:)launcher_relative}; do
    windows_launcher+="\\$component"
  done
  wine_command=("$wine_exe" --bottle "${prefix:t}" --cx-app "$windows_launcher" --)
else
  wine_exe="${WINE:-}"
  wine_command=("$wine_exe" "$launcher")
fi
if [[ ! -x "$wine_exe" ]]; then
  print -u2 'Start Windows Steam in the same Wine bottle before connecting.'
  exit 1
fi

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
    # The CEF helper accepts one exact client build, so Connect must not update it.
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
