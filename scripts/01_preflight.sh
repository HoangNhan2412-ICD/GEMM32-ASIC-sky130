#!/usr/bin/env bash
# Read-only validation before launching OpenLane.
set -euo pipefail

project_root="${1:-$(pwd -P)}"
design="$project_root/designs/GemmAccelerator"
macro="sky130_sram_2kbyte_1rw1r_128x128_128"
macro_dir="$design/macros/$macro"
pdk_commit="0fe599b2afb6708d281543108caf8310912f54af"
pdk_dir="$HOME/.volare/volare/sky130/versions/$pdk_commit"
image="docker.io/efabless/openlane:2023.12.26"

fail() {
    echo "LỖI: $*" >&2
    exit 1
}

for cmd in podman python3 git rg find sha256sum df; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Thiếu lệnh: $cmd"
done

[ -d "$design" ] || fail "Không thấy design: $design"

required_files=(
    "$design/config.tcl"
    "$design/pin_order.cfg"
    "$design/src/GEMM_core.v"
    "$design/src/In_buffer.v"
    "$design/src/Buffer_feeder.v"
    "$design/src/Gemm_compute_core.v"
    "$design/src/PE_array.v"
    "$design/src/PE_row.v"
    "$design/src/PE.v"
    "$design/src/Out_buffer.v"
    "$design/src/Signed_adder.v"
    "$design/src/Right_shifter.v"
    "$design/src/Sram128x256.v"
    "$design/src/Sram64x256.v"
    "$design/src/Sram128x1024.v"
    "$macro_dir/$macro.v"
    "$macro_dir/$macro.lef"
    "$macro_dir/${macro}_TT_1p8V_25C.lib"
    "$macro_dir/$macro.gds"
)

for path in "${required_files[@]}"; do
    [ -s "$path" ] || fail "Thiếu hoặc rỗng: $path"
done

config="$design/config.tcl"
required_config=(
    'set ::env(DESIGN_NAME) GemmAccelerator'
    'set ::env(CLOCK_PORT) i_clk'
    'set ::env(CLOCK_PERIOD) 10'
    'set ::env(PDK) sky130A'
    'set ::env(STD_CELL_LIBRARY) sky130_fd_sc_hd'
    'set ::env(DIE_AREA) "0 0 7000 5500"'
    'set ::env(CORE_AREA) "200 200 6800 5300"'
    'set ::env(PL_TARGET_DENSITY) 0.40'
    'set ::env(FP_PIN_ORDER_CFG)'
)

for expected in "${required_config[@]}"; do
    rg -q -F "$expected" "$config" || fail "config.tcl thiếu/khác: $expected"
done

rg -q -F "$macro" "$config" || fail "config.tcl chưa tham chiếu macro $macro"
rg -q "^MACRO[[:space:]]+$macro$" "$macro_dir/$macro.lef" || fail "LEF sai tên macro"
rg -q 'SIZE[[:space:]]+683\.1[[:space:]]+BY[[:space:]]+416\.54[[:space:]]*;' "$macro_dir/$macro.lef" || fail "LEF sai kích thước 683.1 × 416.54 µm"
rg -q "cell[[:space:]]*\([[:space:]]*$macro[[:space:]]*\)" "$macro_dir/${macro}_TT_1p8V_25C.lib" || fail "Liberty sai cell name"
rg -q "module[[:space:]]+$macro[[:space:]]*\(" "$macro_dir/$macro.v" || fail "Verilog macro sai module name"

[ -d "$pdk_dir/sky130A" ] || fail "Thiếu PDK $pdk_commit; xem ENVIRONMENT.md"
podman image exists "$image" || fail "Thiếu image $image; chạy podman pull $image"

active="$(podman ps -q)"
[ -z "$active" ] || fail "Đang có container chạy; dừng/đóng trước khi chạy OpenLane"

available_kib="$(df -Pk "$project_root" | awk 'NR==2 {print $4}')"
[ "$available_kib" -ge 20971520 ] || fail "Cần ít nhất 20 GiB trống"

echo "PREFLIGHT PASS"
echo "Project: $project_root"
echo "Image:   $image"
echo "PDK:     $pdk_dir"
echo "Disk free: $(df -h "$project_root" | awk 'NR==2 {print $4}')"

