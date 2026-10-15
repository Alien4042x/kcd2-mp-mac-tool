#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$here/build.sh" >/dev/null

output=${1:-"$HOME/Desktop/kcdmp-ntdll-probe-$(date +%Y%m%d-%H%M%S).log"}
address=${KCDMP_PROBE_ADDRESS:-0x6ffffff8d30c}
duration=${KCDMP_PROBE_SECONDS:-180}

printf 'Waiting for the next KCD:MP game process. Click Connect in the Mac app.\n'
printf 'Probe output: %s\n' "$output"

while :; do
    pids=$(pgrep -f 'KingdomCome[.]exe.*-KcdMp_connect' || true)
    for pid in $pids; do
        if "$here/bin/macos_ntdll_page_probe" "$pid" "$address" "$duration" > "$output" 2>/dev/null; then
            printf 'Probe complete: %s\n' "$output"
            exit 0
        fi
    done
    sleep 0.2
done
