# Gói bằng chứng: IP gemm_ip (GEMM 32x32 INT8, SKY130) sau ECO signoff

**Đây là số sau layout, lấy từ mô phỏng và phân tích tĩnh, chưa phải số đo trên silicon.** Đường dẫn file tính từ thư mục làm việc ECO (`$ECO_DIR`). Trong repo, gói này nằm ở `docs/paper/`, chỉ gồm các file dưới 5 MB; báo cáo theo từng instance (`*.inst.rpt`, `*.act`) chỉ có ở `$ECO_DIR/paper/data/power/` (nén gzip). Mọi con số dưới đây đều ghi kèm file nguồn (trong `paper/data/` trừ khi ghi khác) và điều kiện đo.

Đối tượng là layout cuối `s7E/a5.def` (bản sao ở `final/GEMM_top.def`) cùng run OpenLane 1.0.2 `s5/final_a5`.
- Clock 20 ns (50 MHz). SDC: `final/GEMM_top.sdc`.
- SPEF signoff: RC nom, trích bằng OpenRCX của OpenLane 1.0.2.
- Cell chuẩn: lib `sky130_fd_sc_hd`. SRAM: lib OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8`, chỉ có bản TT, nên dùng cho mọi corner.

## Giới hạn đã biết (đọc trước khi dùng số)
- **50 MHz là "TT theo lib".**
  - SRAM chỉ có lib TT. Timing của SRAM là ngoại suy, vì lib chỉ đặc tính hoá slew 1,25–40 ps.
  - Theo các báo cáo đã công bố, SRAM OpenRAM trên silicon chạy được khoảng 34–40 MHz.
  - Setup ở SS của các path chạm macro âm (−4,94 ns, RC max), chỉ báo.
- **Hold I/O ở SS âm** (607 endpoint, tệ nhất −4,04 ns), chỉ báo. Nguyên nhân là SDC coi clock bên ngoài là lý tưởng; người tích hợp tính lại bằng `final/GEMM_top.tt.lib`.
- **Công suất SRAM là cận trên.** Lib OpenRAM tính cùng một năng lượng cho mọi cạnh clock, dù SRAM có được chọn hay không. Ở cửa sổ 64×64×64, SRAM chiếm 224 mW (28 %).
- **Công suất theo hoạt động lấy từ GLS unit-delay, không có glitch.** Mỗi kích thước chỉ dùng một cửa sổ 400 chu kỳ trong pha tính. Năng lượng mỗi GEMM giả định công suất của cửa sổ đó đúng cho cả job; pha nạp và xuất dữ liệu có thể tốn ít hơn.
- **Điện dung RCX lớn hơn ước lượng sau global route khoảng 1,5–2,7 lần** trên các net dài (`cap_ratio_rcx_grt.csv`).
- **IR drop:**
  - phân tích tĩnh;
  - row và vỏ AXI được mô hình bằng công suất trung bình không đổi, gắn vào macro (lý do và cách làm ở mục IR drop);
  - điểm cấp nguồn do PSM tự đặt trên chân vccd1/vssd1 của IP, chưa có lưới bump hay pad.
- **Kiểm tương đương PE** là kiểm có giới hạn (BMC 20 chu kỳ), chưa phải chứng minh đầy đủ (mục 8).

## 1. Số liệu tĩnh
Nguồn: `ip_summary.csv`, `ip_groups.csv`, `cells_by_block.csv`, `wires_by_block.csv`; script `scripts/static_stats.py`. Kích thước lấy từ LEF.

| Mục | Giá trị |
|---|---|
| Die | 7274,90 × 10493,76 µm = **76,34 mm²** |
| Vùng core (khung bao các hàng) | 76,07 mm² |
| Macro | 38,72 mm²: 80 SRAM 22,76; 32 row 15,00; vỏ AXI 0,95 |
| Cell chuẩn ở top, trừ filler/decap/tap | 1,61 mm² |
| Mật độ (macro + cell chuẩn) / core | 53,0 % |
| Cổng quy đổi NAND2 (diện tích logic / diện tích `nand2_1` 3,7536 µm²) | top 404 130 + 32 × 58 839 (row) + 26 011 (AXI) = **2,313 triệu** |
| Flop | top 22 109 + 32 × 2 616 + 1 158 = **106 979** |
| Instance trong DEF top | 3 697 759 |
| PE | 1024 (32 row × 32) |

Số cell theo khối, tính trên cả IP (top phẳng + 32 row + AXI), nguồn `cells_by_block.csv`:

| Nhóm | Số cell | Diện tích (µm²) |
|---|---|---|
| logic tổ hợp | 573 932 | 4 239 816 |
| flop | 106 979 | 2 260 065 |
| buffer hold (dlygate, `hold*`) | 134 939 | 1 348 521 |
| buffer của resizer và I/O | 84 101 | 617 724 |
| cây clock | 8 270 | 202 264 |
| buffer ECO (`eco_*`) | 1 593 | 9 459 |
| tie | 1 126 | 4 227 |
| diode | 533 405 | 1 334 793 |
| filler/decap | 4 082 038 | 38 085 687 |
| tap | 723 449 | 905 180 |
| SRAM / row / AXI macro | 80 / 32 / 1 | |

Cell do ECO thêm so với DEF vòng 1 của ip_v3r: 2968 cell (1220 diode, 1742 buffer, 6 dlygate); 794 cell đổi cỡ; 187 diode bị xoá. Nguồn: `netdiff` trong `BAOCAO.md`.

Chiều dài dây tín hiệu (không tính lưới nguồn), cả IP, nguồn `wires_by_block.csv`:

| Lớp | Dây (m) | Via ở lớp cut ngay trên |
|---|---|---|
| met1 | 17,41 | via 3 271 001 |
| met2 | 18,39 | via2 231 441 |
| met3 | 6,21 | via3 36 732 |
| met4 | 1,95 | via4 1 020 |
| met5 | 0,17 | – |
| li1 | – | mcon 3 359 796 |

Mật độ dây sau route của top, tính theo ô 50 µm (`routing_utilisation.csv`): met1 38 %, met2 68 %, met3 73 % (3 ô vượt 70 %), met4 66 %.

## 2. Hiệu năng ở 50 MHz
Nguồn: `perf_gls_50MHz.csv`; script `scripts/perf.py`. Số chu kỳ lấy từ ip-gls trên netlist cuối, job 2 của mỗi kích thước (không reset giữa hai job), từ JOB_START tới RESULT_ACCEPT cuối, gồm cả cấu hình AXI-Lite, nạp dữ liệu, tính và xuất kết quả.

| Kích thước (M×K×N) | MAC | Chu kỳ | Thời gian (µs) | GOPS hiệu dụng | Tỉ lệ dùng PE |
|---|---|---|---|---|---|
| 64×64×64 | 262 144 | 1645 | 32,90 | **15,94** | 15,6 % |
| 8×32×544 | 139 264 | 5330 | 106,60 | 2,61 | 2,6 % |
| 16×992×32 | 507 904 | 9654 | 193,08 | 5,26 | 5,1 % |

- Đỉnh: 102,4 GOPS (2 × 1024 PE × 50 MHz).
- Hiệu năng hiệu dụng thấp hơn đỉnh nhiều, vì dữ liệu vào qua AXI-Stream mỗi chu kỳ một beat và weight phải nạp lại theo tile.

## 3. Công suất theo hoạt động thật (TT 25 °C 1,80 V, SPEF RC nom, 50 MHz)
Nguồn: `power/vcd_*.groups.txt`, `power/vcd_*.design.rpt`, `energy_50MHz.csv`; script `scripts/vcd_power.sh`, `vcd2act_ip.py`, `energy.py`.

Cách làm:
- GLS trên netlist cuối (unit delay), dump VCD mọi net ở độ sâu 1 của top, 32 row và AXI;
- cửa sổ 400 chu kỳ trong pha tính của job 2;
- chuyển thành hoạt động trên chân driver của từng net (915 978 chân, 0 chân không tìm thấy);
- `report_power` của OpenSTA, với netlist và SPEF của từng macro;
- VCD tổng 475 MB, đã xoá sau khi tính.

| Kích thước | Cửa sổ (chu kỳ) | Công suất (mW) | Internal | Switching | Leakage | SRAM | Năng lượng / GEMM (µJ) | pJ/MAC | GOPS/W hiệu dụng | Đỉnh 102,4 GOPS / công suất |
|---|---|---|---|---|---|---|---|---|---|---|
| 64×64×64 | 2400–2800 | **800,3** | 573,8 | 223,6 | 2,84 | 224,0 | 26,33 | 100,4 | **19,9** | 128,0 |
| 8×32×544 | 8000–8400 | 744,9 | 548,0 | 194,1 | 2,84 | 224,0 | 79,41 | 570,2 | 3,5 | 137,5 |
| 16×992×32 | 15000–15400 | 772,7 | 562,5 | 207,3 | 2,84 | 224,0 | 149,19 | 293,7 | 6,8 | 132,5 |

- Cột cuối là cận trên lý thuyết (đỉnh chia cho công suất đo được), không phải số đạt được.
- Theo khối, kích thước 64×64×64: SRAM 224,0; row 410,9 (flop 209,5, cây clock 130,8, tổ hợp 70,7); core ở top 156,5 (cây clock 67,7); AXI 8,8 mW.
- So sánh: vectorless (hoạt động mặc định của OpenSTA) cho 1377,6 mW; chỉ dùng làm số tham khảo.

Leakage ở 3 corner (`leakage_3corners.csv`; script `scripts/leakage.sh`):

| Corner cell chuẩn | Tổng | SRAM (lib TT) | Cell chuẩn |
|---|---|---|---|
| tt_025C_1v80 | 2,843 mW | 2,836 | 0,004 |
| ff_n40C_1v95 | 2,849 mW | 2,836 | 0,010 |
| ss_100C_1v60 | 8,415 mW | 2,836 | 5,58 |

## 4. PE và row
Nguồn: `blocks_pe_row.csv`, `fmax_*.rpt`, `power/block_*`; script `scripts/block_sim_power.sh`, `block_fmax.tcl`, `sim/tb_block_rand.v`.
- **PE** được harden riêng bằng cấu hình `gemm_pe` của flow hiện tại (run `gemm_pe/runs/paper_pe`). DRC 0, LVS 0 lỗi, antenna 0.
- **Row** dùng run `row_v1`, chính là row nằm trong IP.
- **Mô phỏng:** dữ liệu ngẫu nhiên; netlist gate-level so với RTL từng chu kỳ (PE 1229 lần so, row 1198 lần so, 0 lệch); cửa sổ 1000 chu kỳ.
- **Công suất** đo ở TT, SPEF RC nom, clock đặt lại 20 ns.
- **fmax** tính theo path flop→flop, SPEF RC nom, propagated clock, fmax = 1/(T − slack).

| | PE | Row (32 PE) |
|---|---|---|
| Diện tích | die 17 218 µm²; core 13 085 µm²; cell (tổng hợp) 6 604 µm² | die 468 800 µm²; cell 259 100 µm² |
| Flop | 66 | 2 616 |
| fmax TT / SS | 208,9 / 108,7 MHz | 172,3 / 90,2 MHz |
| Công suất ở 50 MHz, dữ liệu ngẫu nhiên | 0,666 mW | 22,13 mW |
| Năng lượng mỗi MAC | **13,3 pJ** | **13,8 pJ** |

Trong IP, một row tiêu trung bình 12,84 mW ở cửa sổ 64×64×64 (`power/macro_power_64.txt`), thấp hơn mức dữ liệu ngẫu nhiên vì dữ liệu thật và tỉ lệ dùng PE thấp hơn. Năng lượng mỗi MAC của cả IP (100–570 pJ) cao hơn của PE nhiều vì gồm SRAM, cây clock và thời gian PE không tính.

## 5. IR drop (tĩnh, TT, 50 MHz)
Nguồn: `irdrop_summary.csv`, `irdrop_by_class.csv`, `irdrop_*_worst100.csv`; script `scripts/ir_drop.tcl`, `ir_map.py`; log `paper/work/ir/ir.log`.

Cách làm:
- `analyze_power_grid` của OpenROAD trong OpenLane 1.0.2;
- cell ở top: hoạt động VCD của cửa sổ 64×64×64; SRAM: lib OpenRAM;
- row và vỏ AXI: công suất trung bình theo VCD (12,84 mW mỗi row, 8,77 mW cho AXI), gắn vào bản sao lib dưới dạng `cell_leakage_power`, vì lib của hai macro này không có số công suất;
- tổng công suất PSM dùng là 800 mW, khớp với mục 3;
- 642 điểm cấp nguồn do PSM tự đặt trên chân met4 của IP.

| Lưới | Tệ nhất | % VDD | Trung bình | p99 |
|---|---|---|---|---|
| vccd1 | **138,9 mV** | 7,7 % | 1,67 mV | 8,0 mV |
| vssd1 | **155,6 mV** | 8,6 % | 1,60 mV | 9,6 mV |

- Điểm tệ nhất nằm ở row 0 và rãnh sát các row ở phía đông của mảng row (ảnh `figures/irdrop_map.*`).
- Phần lớn chip dưới 10 mV.
- Mô hình dồn dòng của cả row vào chân nguồn của macro, nên sụt áp quanh row có thể bị phóng đại so với lưới nguồn bên trong row.

## 6. Ảnh
| File | Nội dung |
|---|---|
| `figures/layout/chip_full.png` | KLayout, cả chip (độ sâu phân cấp 1) |
| `figures/layout/pe_about_one.png` | 110 µm đầu của row 0, khoảng 1 PE (row đã phẳng nên không có ranh giới PE) |
| `figures/layout/sram_macro.png` | một SRAM (`u_feature_tile_mem g_bank[0].g_lane[0]`) |
| `figures/layout/eco_clk_20.png` | vùng clkbuf ECO `eco_clk_20` |
| `figures/openroad/ip.layout.png` | OpenROAD, cả chip |
| `figures/openroad/ip.clocktree.png` | cây clock `S_AXI_ACLK` (trình xem cây clock của OpenROAD) |
| `figures/placement_density.*` | mật độ đặt cell, ô 10 µm (dữ liệu `ip.heatmap_Placement.csv.gz`) |
| `figures/routing_utilisation.*` | mật độ dây sau route theo lớp, ô 50 µm |
| `figures/irdrop_map.*` | bản đồ IR drop vccd1 và vssd1 |

- Ảnh dải row không có: ở độ phân giải đọc được, dây met2 phủ kín cả hình.
- Heatmap kẹt dây của OpenROAD không có: bản này không có RUDY, còn heatmap Routing cần dữ liệu global route. Thay vào đó dùng mật độ dây thật sau route.

## 7. Đồ thị (CSV + `scripts/plots.py`, PNG và PDF)
| Hình | Dữ liệu | Nội dung |
|---|---|---|
| `antenna_convergence` | `antenna_convergence.csv` | ECO route lại toàn bộ (OL1, ip_v3r: 1133 → 446 → 293, trong đó 266 chân mới; mỗi vòng route lại 100 % net) so với ECO tăng dần (446 → 37 → 6 → 3 → 1 → 0; mỗi vòng route lại 0,60 / 0,04 / 0,01 / 0,01 / 0,003 % net). Thời gian mỗi vòng: OL1 1749–5458 s, tăng dần 993–1089 s |
| `drv_by_eco_round` | `drv_by_eco_round.csv` | Net cell chuẩn vượt lib ở TT nom và SS max, qua từng lượt ECO: 435/1673 → 0/0 |
| `sram_clk_slew` | `sram_clk_slew_before_after.csv` | Slew chân clock SRAM. Trước khi sửa clock (layout a2): TT max 3,83 ns, 43 chân > 0,75 ns. Sau: TT max 0,739 ns, SS max 0,998 ns |
| `slack_histograms` | `slack_histogram_final.csv` | Histogram slack setup/hold của layout cuối, TT/FF/SS × RC max, theo loại path |
| `cap_ratio_rcx_grt` | `cap_ratio_rcx_grt.csv` | Điện dung RCX (max) so với ước lượng sau global route trên 85 net dài: 1,54–2,71 lần, trung vị 2,05 |

Ghi chú về số chân antenna của ip_v3r: báo cáo vòng 2 có 294 dòng nhưng chỉ 293 chân khác nhau, và 266 chân trong đó không có ở vòng 1. Đồ thị dùng số chân khác nhau.

## 8. Kiểm tương đương hình thức PE (Yosys 0.30 của OpenLane 1.0.2)
Nguồn: `pe_equiv.log`; script `scripts/pe_equiv.ys`.
- **Đối tượng:** RTL `rtl_asic/PE.v` (P_DATAPATH_RESET = 0, như trong flow) so với netlist cuối của PE đã harden. Mô hình cell lấy từ liberty TT.
- **Cách 1, `equiv_make` / `equiv_induct`:** còn 21 bit `o_partial_sum` chưa chứng minh được. Lý do: thanh ghi nội bộ của netlist đi qua buffer và có 82 flop so với 66 của RTL, nên không ghép được trạng thái theo tên.
- **Cách 2, miter + `sat -tempinduct`:** bước cơ sở đạt tới độ dài 20, tức là không có chuỗi đầu vào nào làm đầu ra khác nhau trong 20 chu kỳ tính từ trạng thái 0. Bước quy nạp không khép được.
- **Kết luận:** tương đương có giới hạn trong 20 chu kỳ. Có thêm một lập luận, không do công cụ kiểm: mọi thanh ghi của PE được ghi lại từ đầu vào trong vòng 2 chu kỳ, nên độ sâu 20 đã vượt đường kính trạng thái. Không ghi là "đã chứng minh tương đương".
- Mô phỏng ngẫu nhiên ở mục 4 cũng không thấy lệch nào giữa netlist và RTL của PE và row.

## 9. Tái lập
Nguồn: `reproducibility.csv` (thời gian và RAM từng bước), `machine.csv` (máy, image, phiên bản), `final/TOOLS.txt`, `final/MANIFEST`.
- **Máy:** Intel i7-14700HX (28 luồng), 15 GiB RAM cùng 32 GiB swap, AlmaLinux 10.2, Docker 29.8.2. Mọi container giới hạn 10g/40g.
- **Image OpenLane 1.0.2:** `sha256:832662c8…779a`; OpenROAD 41a51eaf, Magic 8.3.413, Netgen 1.5.255, KLayout 0.28.2, Yosys 0.30+48, OpenSTA 2.4.0.
- **Image ECO:** LibreLane 3.0.16 `sha256:4bc9042b…5051` (OpenROAD dcf36133).
- **PDK:** open_pdks 0fe599b2. Icarus Verilog 13.0. matplotlib 3.9.2 trong `paper/.venv`.
- **GDS cuối:** `final/GEMM_top.gds`, sha256 `87286b9408d1a706d1f47a2925317ed5ed702c0700b780edbdda0a22e8b068fa`.
- **Repo:** nhánh `eco-signoff-wip`; script ECO ở `tools/eco`, gói này ở `docs/paper`.
