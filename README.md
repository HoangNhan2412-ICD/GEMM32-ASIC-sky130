# GEMM 32x32 INT8 - flow ASIC phân cấp trên SKY130

Đưa bộ gia tốc GEMM 32x32 INT8 (weight-stationary, bản gốc chạy trên FPGA KV260) ra layout
trên PDK SKY130 bằng OpenLane 1.0.2. Thiết kế được harden từng tầng: PE, rồi row macro
(32 PE), rồi array (32 row), cuối cùng là core GemmAccelerator gồm 32 row macro và 80 SRAM
OpenRAM. Mỗi tầng được kiểm tra riêng trước khi lên tầng trên, nên lỗi nằm ở đâu thì thấy
ngay ở tầng đó, thay vì chỉ thấy nghẽn ở cuối như khi chạy phẳng cả thiết kế.

## Trạng thái

| Tầng | Kết quả |
|---|---|
| RTL | Bản ASIC cho kết quả trùng từng chu kỳ với RTL FPGA (3 kích thước ma trận, model SRAM thật) |
| PE | PASS |
| Row (32 PE) | PASS, dùng làm macro `ProcessingElementRow` |
| Array (32 row) | PASS |
| Core | Floorplan, placement, CTS xong; detailed route còn 1 short met5 (core_v6, core_v6r); bản sửa core_v7 đang chạy |

Core có die 7,06 x 10,24 mm. Vùng A bên trái chứa feeder và InputBuffer (48 SRAM). Vùng B nằm
dưới chồng row, chứa OutputBuffer (32 SRAM xếp lưới 4x8). Chồng 32 row macro ở phía trên bên phải.
Mỗi SRAM được đặt cạnh phần logic dùng nó, để các chuỗi skew/deskew không phải đi vắt qua macro.

## Nhật ký core

| Run | Thay đổi | Kết quả |
|---|---|---|
| v1 | floorplan đầu tiên | FastRoute crash ở global route vì nghẽn quá nặng |
| v3, v4 | SRAM đặt cạnh logic; tắt buffer lúc synthesis (`SYNTH_BUFFERING 0`) | overflow 321k xuống 6,8k |
| v5 | nới dải FeatureSkew và khe vùng A | vẫn nghẽn met4 trên chồng row |
| v6 | `keep_rows_clear.tcl` đẩy cell ra khỏi khe giữa các row macro | overflow 575, detailed route còn 1 short |
| v6r | route lại với seed 7, 23, 101 | seed nào cũng còn đúng short đó |
| v7 | cấm met5 trên SRAM, sửa timing, thêm vòng sửa antenna | đang chạy |

Mấy điểm đáng chú ý:

**Short met5 không đổi theo seed.** SRAM chặn met1-met4, nên dây đi ngang qua SRAM chỉ còn met5.
Ba net đổi track ngay phía trên một SRAM ở vùng B; trên một lớp duy nhất, đổi track nghĩa là có
đoạn met5 đi sai hướng, và hai đoạn như vậy cắt nhau. Từ v7, met5 trên mỗi SRAM là vùng cấm route
(`GEMM_SRAM_MET5_OBS`, sinh từ `gen_core_files.py`), dây phải đi qua khe giữa các SRAM.

**Timing.** 256/257 path âm của v6 đi từ thanh ghi `r_cfg_shift` qua 32 bộ dịch phải. Thanh ghi
này chỉ nạp khi core rảnh nên được khai báo multicycle (`cfg_shift_mcp.sdc`). Path còn lại đi từ
`r_cfg_row_count` qua bộ nhân địa chỉ; tích này dùng ngay đầu job nên không nới được, thay vào đó
Out_buffer có bản sao riêng của thanh ghi để bớt một cây fanout.

**Antenna.** Diode heuristic có sẵn cạnh chân, nhưng router nối diode qua met2 ở chỗ khác nên đảo
met1 của cổng không chứa diode. Sau detailed route, `ant_eco.py` đặt thêm diode sát các cổng còn
lỗi rồi route lại, tối đa 2 vòng.

## Chạy

Cần OpenLane 1.0.2 (Docker) ở `~/OpenLane` và PDK sky130A. Repo gốc GEMM_32x32_KV260 đặt cạnh
thư mục này (dùng testbench của nó).

    openlane/run_flow.sh sim          # RTL ASIC so với RTL FPGA
    openlane/run_flow.sh pe           # tầng 0
    openlane/run_flow.sh row          # tầng 1: row macro
    openlane/run_flow.sh array        # tầng 2
    openlane/run_flow.sh core-sim     # RTL core với model SRAM thật
    openlane/run_flow.sh core-pre     # lint + synthesis + floorplan của core
    openlane/run_flow.sh core         # core đầy đủ (nhiều giờ)
    openlane/run_flow.sh core-status  # run core đang ở bước nào
    openlane/run_flow.sh core-route   # route + signoff lại từ sau CTS của run trước
    openlane/run_flow.sh core-probe   # chỉ global route, xem nghẽn ở đâu

Mỗi tầng chỉ chạy khi tầng trước đã PASS và ghi kết quả vào `openlane/LOG.md`. Các biến môi
trường (floorplan, seed router, vòng sửa antenna...) liệt kê ở đầu `openlane/run_flow.sh`.

## Thư mục

```
rtl_asic/        RTL cho ASIC (bỏ IP nhân của FPGA, tách skew khỏi row, bộ nhớ dùng OpenRAM)
sim/             so sánh với RTL FPGA, testbench hệ thống, mô phỏng gate-level
openlane/
  run_flow.sh            các tầng ở trên
  gen_openlane_files.py  hình học row và array
  gen_core_files.py      floorplan core: vị trí 112 macro, PDN, vùng cấm met5
  designs/gemm_pe, gemm_row, gemm_array, gemm_core/
    gemm_core/core_full.tcl      run core đầy đủ
    gemm_core/route_signoff.tcl  route (nhiều seed, sửa antenna) và signoff
    gemm_core/resume.tcl         chạy tiếp từ sau CTS của một run
tools/           đọc log và layout: core_triage, core_congestion, core_channels,
                 sta_summary, antenna_nets, def_window, core_watch ...
```

## Giới hạn phần mềm

Phần mềm phải theo cùng giới hạn độ sâu buffer của bản ASIC (ggml-cpu.c `rtl_shape_ok`,
FPGA_GEMM.cpp `IP_BUFFER_DEPTH`): M·k_blocks ≤ 512, k_blocks·32·n_blocks ≤ 1024,
M·n_blocks ≤ 512. `tools/patch_software_depths.py` thêm ba giới hạn này vào driver, bật khi
biên dịch với `-DGEMM_ASIC_DEPTHS` (bản FPGA giữ nguyên).
