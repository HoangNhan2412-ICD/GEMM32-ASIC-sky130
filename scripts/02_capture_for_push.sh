#!/usr/bin/env bash
# Capture small, reviewable evidence from the author's machine.
set -euo pipefail

project_root="${1:-$(pwd -P)}"
bundle="$project_root/OPENLANE_REPRODUCE_MACROSPACED_V2"
evidence="$bundle/evidence"
design="$project_root/designs/GemmAccelerator"
tag="area7000x5500_density40_macrospaced_v2"
run="$design/runs/$tag"
image="docker.io/efabless/openlane:2023.12.26"
pdk_commit="0fe599b2afb6708d281543108caf8310912f54af"

[ -d "$design" ] || { echo "Không thấy $design" >&2; exit 1; }
mkdir -p "$evidence"

{
    date -Ins
    uname -a
    sed -n '1,30p' /etc/os-release 2>/dev/null || true
    lscpu 2>/dev/null | rg 'Architecture|Model name|CPU\(s\)|Thread|Core|Socket' || true
    free -h 2>/dev/null || true
    df -h "$project_root"
    podman --version
    python3 --version
    git --version
    printf 'OpenLane image: %s\n' "$image"
    podman image inspect "$image" --format 'Image ID={{.Id}} RepoDigests={{json .RepoDigests}}' 2>/dev/null || true
    printf 'PDK commit: %s\n' "$pdk_commit"
    printf 'Git HEAD: '
    git -C "$project_root" rev-parse HEAD 2>/dev/null || printf 'not-a-git-repository\n'
    git -C "$project_root" status --short 2>/dev/null || true
} > "$evidence/environment.txt"

find \
    "$design/src" \
    "$design/macros/sky130_sram_2kbyte_1rw1r_128x128_128" \
    "$design/config.tcl" \
    "$design/pin_order.cfg" \
    -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sed "s|$project_root/||" \
    > "$evidence/input_sha256.txt"

if [ -f "$run/config.tcl" ]; then
    cp "$run/config.tcl" "$evidence/run_config_snapshot.tcl"
elif [ -f "$run/config_in.tcl" ]; then
    cp "$run/config_in.tcl" "$evidence/run_config_snapshot.tcl"
fi

if [ -f "$design/macro_placement_spaced_v2.cfg" ]; then
    cp "$design/macro_placement_spaced_v2.cfg" "$evidence/macro_placement_snapshot.cfg"
fi

{
    printf 'tag=%s\n' "$tag"
    if [ -d "$run" ]; then
        du -sh "$run"
        rg -n -F 'GRT-0119' "$run/logs" --glob '*.log' 2>/dev/null || true
        report="$run/tmp/routing/resizer-routing-design-congestion.rpt"
        if [ -f "$report" ]; then
            printf 'congestion_markers='
            rg -c 'bbox =' "$report" || true
            awk -F'overflow:' '/overflow:/ {split($2,a,/[^0-9]/); s+=a[1]} END {print "overflow_sum=" s+0}' "$report"
        fi
        find "$run/results" -type f \( -name '*.gds' -o -name '*.gdsii' \) -print 2>/dev/null || true
    else
        printf 'run_missing=true\n'
    fi
} > "$evidence/run_status.txt"

echo "Đã tạo evidence trong: $evidence"
echo "Hãy kiểm tra các file trước khi commit."

