# Script của gói bằng chứng

Các script đọc đường dẫn từ biến môi trường. Script Tcl đọc qua `$::env(...)`; trong `pe_equiv.ys`, các đường dẫn là chỗ trống `<...>`, cần thay tay.

| Biến | Ý nghĩa |
|---|---|
| `ECO_DIR` | thư mục làm việc ECO: `final/`, `s5/final_a5/`, `lib/`, `paper/` |
| `REPO` | repo này (cần `rtl_asic/`, `sim/run_ip_gls.sh`, `tools/power/`) |
| `KV260` | repo GEMM_32x32_KV260 (testbench gốc) |
| `OL` | OpenLane 1.0.2 |
| `PDK_ROOT` | PDK của flow OpenLane 1.0.2 (có `sky130A/` bên dưới) |

Thứ tự chạy, mỗi lúc một job nặng:

1. `static_stats.py` (DEF của IP, row, AXI), rồi `perf.py` (log GLS).
2. `vcd_power.sh <M,K,N> <C0> <C1>` cho từng kích thước; sau đó `energy.py` và `leakage.sh`.
3. `pe_harden.sh`, `block_fmax.tcl`, `block_sim_power.sh pe|row`, `pe_equiv.ys`.
4. `ir_drop.tcl` (OpenROAD `-gui`, `QT_QPA_PLATFORM=offscreen`), rồi `ir_map.py`.
5. `klayout_shots.py`, `or_shots.tcl`, `density_maps.py`.
6. `plots.py`. Cần matplotlib 3.9.2; image OpenLane không có, nên tạo venv riêng.
