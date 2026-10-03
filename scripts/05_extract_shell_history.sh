#!/usr/bin/env bash
# Extract only project/OpenLane-related commands from Bash/Zsh history.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
evidence="$(cd "$script_dir/../evidence" && pwd -P)"
output="$evidence/historical_commands_from_shell.txt"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

for history_file in "$HOME/.zsh_history" "$HOME/.bash_history"; do
    [ -r "$history_file" ] || continue
    sed -E 's/^: [0-9]+:[0-9]+;//' "$history_file" \
        | rg 'GEMM_final_DSP_OPENLANE_ASIC|area[0-9]+x[0-9]+|flow\.tcl|gemm_macro_spaced|config_macro_spaced|macro_placement_spaced|openlane:2023\.12\.26' \
        | rg -v -i 'token|password|passwd|secret|authorization|podman login|docker login|ghp_' \
        >> "$tmp_file" || true
done

awk 'NF && !seen[$0]++' "$tmp_file" > "$output"

echo "Đã tạo: $output"
echo "Bắt buộc đọc lại file này trước khi git add."

