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
  - *Cập nhật:* nay báo thành khoảng, cận dưới theo số chu kỳ SRAM được chọn đếm từ VCD: 96–105 mW (mục 3.4).
- **Công suất theo hoạt động lấy từ GLS unit-delay, không có glitch.** Mỗi kích thước chỉ dùng một cửa sổ 400 chu kỳ trong pha tính. Năng lượng mỗi GEMM giả định công suất của cửa sổ đó đúng cho cả job; pha nạp và xuất dữ liệu có thể tốn ít hơn.
  - *Cập nhật:* giả định cửa sổ đã được thay bằng số đo cả job 2 và theo từng pha (mục 3). Số cửa sổ cũ còn bị lỗi đọc VCD (xem "Thay đổi so với bản trước"), nên không dùng nữa. Vẫn là GLS unit-delay, không có glitch.
- **Điện dung RCX lớn hơn ước lượng sau global route khoảng 1,5–2,7 lần** trên các net dài (`cap_ratio_rcx_grt.csv`).
- **IR drop:**
  - phân tích tĩnh;
  - row và vỏ AXI được mô hình bằng công suất trung bình không đổi, gắn vào macro (lý do và cách làm ở mục IR drop);
  - điểm cấp nguồn do PSM tự đặt trên chân vccd1/vssd1 của IP, chưa có lưới bump hay pad.
  - *Cập nhật:* câu trên sai. Lần chạy đầu dùng mẫu bàn cờ mặc định của PSM (bump cách 140 µm trên toàn vùng core, cảnh báo PSM-0016/0065), không phải chân của IP. Bản mới chạy hai mô hình nguồn (bàn cờ, và nguồn ở hai đầu các dải met5 là chân của IP), và tính thêm IR drop bên trong row (mục 5).
- **Kiểm tương đương PE** là kiểm có giới hạn (BMC 20 chu kỳ), chưa phải chứng minh đầy đủ (mục 8).
  - *Cập nhật:* đã chứng minh đầy đủ bằng `equiv_induct` khi ghép thanh ghi theo tên. Kết quả giống nhau trên Yosys 0.62 và Yosys 0.30 (mục 8).
- **Thông lượng đo bằng testbench gốc**, testbench này tự chèn chu kỳ trống trên luồng vào và hạ TREADY của luồng kết quả. Số "full-rate" (luồng một beat mỗi chu kỳ) ở mục 2 là cận trên của chính phần cứng, đo bằng RTL.
- **row_count = 1 (M = 1) cho kết quả sai trong RTL** (sai giá trị, thừa beat kết quả). Đây là một giới hạn của thiết kế; host phải đệm lên 2 hàng (mục 2.3).

## Thay đổi so với bản trước của SUMMARY
- **Công suất:** bộ đọc VCD cũ (`vcd2act_ip.py`) chỉ giữ tên cuối của mỗi mã id. iverilog dùng một mã id cho mọi tên của cùng một net (net ở top và cổng row/AXI mà nó nối tới), nên driver của các net ở biên row/AXI nhận 0 toggle với duty 0. Với các pin đó, OpenSTA tự suy ra activity thay vì dùng số đo.
  - Đã sửa trong `vcd2act_phases.py` và đo lại cả job.
  - 64×64×64: công suất cả job **745 mW** (bản cũ 800 mW, cửa sổ); **21,4 GOPS/W**, 93,5 pJ/MAC (bản cũ 19,9 GOPS/W, 100,4 pJ/MAC). AXI: 2,8 mW (bản cũ 8,8 mW).
  - Số cũ chuyển sang `data/superseded_alias_bug/`.
  - `vcd2act_flat.py` (công suất PE/row ở mục 4) đã xử lý alias từ trước, nên không bị ảnh hưởng.
  - `tools/power/vcd2act.py` của repo (công suất core trước đây) có cùng lỗi này.
- **IR drop:** đo lại với activity đã sửa và mô hình row/AXI mới (12,69 / 3,28 mW). Mô hình bàn cờ cho 137,1 / 153,6 mV, gần như không đổi. Thêm mô hình nguồn ở mép die và IR bên trong row.
- **Hiệu năng:** thêm phân pha, các kích thước lớn, mô phỏng full-rate và roofline. Phát hiện giới hạn bộ đệm thật là 511 / 1023 / 511 từ, và lỗi khi M = 1.
- **PE:** có 82 flop (66 `dfxtp` + 16 `dfrtp`), không phải 66; số 66 là metric `DFF` của OpenLane, chỉ đếm flop không reset. Nhận định "netlist có 16 flop thừa" ở bản trước là sai. Tương đương PE nay đã chứng minh đầy đủ.
- **Leakage:** thêm bảng tách theo khối, mỗi khối chạy riêng; tổng khớp với bảng cũ.

## 1. Số liệu tĩnh
Nguồn: `ip_summary.csv`, `ip_groups.csv`, `cells_by_block.csv`, `wires_by_block.csv`; script `scripts/static_stats.py`. Kích thước lấy từ LEF.

| Mục | Giá trị |
|---|---|
| Die | 7274,90 × 10493,76 µm = **76,34 mm²** |
| Vùng core (khung bao các hàng) | 76,07 mm² |
| Macro | 38,72 mm²: 80 SRAM 22,76; 32 row 15,00; vỏ AXI 0,95 |
| Cell chuẩn ở top, trừ filler/decap/tap | 1,61 mm² |
| Mật độ (macro + cell chuẩn) / core | 53,0 % |
| Cổng quy đổi NAND2 (diện tích logic / diện tích `nand2_1` 3,7536 µm²) | top 404 130 + 32 × 58 839 (row) + 26 011 (AXI) = **2,313 triệu** (gồm buffer hold và cây clock, không gồm diode; các biến thể ở mục 1.1) |
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

### 1.1 Chi phí vật lý: diode, buffer hold, NAND2
Nguồn: `diodes_by_block_origin.csv`, `nand2_hold_by_block.csv`, `diode_config_by_design.csv`; script `scripts/phys_cost.py`.

Nguồn gốc diode được nhận theo tên instance:
- `ANTENNA_<inst>_<pin>`: diode của flow trước route (DIODE_ON_PORTS và chèn heuristic).
- `ANTENNA_<số>`: `repair_antennas` của global route.
- `ANTFIX<k>_…`: `ant_eco.py` của flow, chèn theo báo cáo ARC giữa các vòng route.
- Ở top, mọi diode không có trong DEF vòng 1 của ip_v3r là của ECO. Các vòng ECO cũng gọi `repair_antennas` và đánh số giống flow, nên phải tách theo DEF vòng 1 chứ không theo tên.

| Khối | Diode | Trước route (cổng + heuristic) | repair_antennas lúc GRT | ant_eco.py (flow) | ECO |
|---|---|---|---|---|---|
| top | 37 085 | 0 | 34 652 | 1 213 | 1 220 |
| một row | 15 271 | 15 252 | 19 | 0 | 0 |
| 32 row | 488 672 | 488 064 | 608 | 0 | 0 |
| vỏ AXI | 7 648 | 4 607 | 14 | 3 027 | 0 |
| **IP** | **533 405** | 492 671 | 35 274 | 4 240 | 1 220 |

ECO cũng xoá 187 diode của DEF vòng 1 (trên net clock, bước 7B).

Cấu hình chèn diode, giá trị đã resolve trong `config.tcl` của từng run:

| Thiết kế (run) | DIODE_ON_PORTS | Heuristic | Ngưỡng (µm) | GRT_REPAIR_ANTENNAS | GRT_MAX_DIODE_INS_ITERS | GRT_ANT_MARGIN |
|---|---|---|---|---|---|---|
| gemm_pe (paper_pe) | none | 0 | 90 | 1 | 1 | 10 |
| gemm_row (row_v1) | in | 1 | 50 | 1 | 1 | 30 |
| gemm_core (core_v11) | none | 0 | 50 | 1 | 3 | 30 |
| gemm_ip (ip_v3r) | none | 0 | 50 | 1 | 3 | 30 |
| gemm_ip_shell (ip_shell5) | in | 1 | 50 | 1 | 3 | 30 |
| gemm_array (chỉ có config, không còn run; không nằm trong IP) | – | 1 | 50 | – | 3 | 30 |

Buffer hold và cổng quy đổi NAND2 (diện tích / 3,7536 µm²). "Logic" gồm logic tổ hợp, flop, tie, buffer của resizer/I/O và buffer ECO:

| Khối | Buffer hold | Cây clock | Diode | NAND2: chỉ logic | + hold | + hold + clock | + hold + clock + diode |
|---|---|---|---|---|---|---|---|
| top | 47 000 | 4 257 | 37 085 | 249 918 | 375 750 | 404 130 | 428 853 |
| 32 row | 82 368 | 3 776 | 488 672 | 1 639 381 | 1 858 837 | 1 882 859 | 2 208 640 |
| vỏ AXI | 5 571 | 237 | 7 648 | 10 554 | 24 527 | 26 011 | 31 110 |
| **IP** | **134 939** | 8 270 | 533 405 | **1 899 853** | 2 259 114 | **2 313 000** | **2 668 603** |

Buffer hold chiếm 15,9 % diện tích logic có hold của IP (1,35 / 8,48 mm²). Riêng ở top, chúng chiếm 33 %.

## 2. Hiệu năng ở 50 MHz
### 2.1 Ba kích thước GLS
Nguồn: `perf_gls_50MHz.csv`; script `scripts/perf.py`. Số chu kỳ lấy từ ip-gls trên netlist cuối, job 2 của mỗi kích thước (không reset giữa hai job), từ JOB_START tới RESULT_ACCEPT cuối, gồm cả cấu hình AXI-Lite, nạp dữ liệu, tính và xuất kết quả.

| Kích thước (M×K×N) | MAC | Chu kỳ | Thời gian (µs) | GOPS hiệu dụng | Tỉ lệ dùng PE |
|---|---|---|---|---|---|
| 64×64×64 | 262 144 | 1645 | 32,90 | **15,94** | 15,6 % |
| 8×32×544 | 139 264 | 5330 | 106,60 | 2,61 | 2,6 % |
| 16×992×32 | 507 904 | 9654 | 193,08 | 5,26 | 5,1 % |

- Đỉnh: 102,4 GOPS (2 × 1024 PE × 50 MHz).
- Testbench gốc tự chèn 0–3 (feature) và 0–4 (weight) chu kỳ trống trước mỗi beat. Nó còn hạ TVALID sau mỗi beat, nên mỗi luồng vào nhiều nhất một beat mỗi 2 chu kỳ. TREADY của luồng kết quả thấp ở 1/7 + 1/11 số chu kỳ. Vì vậy các số trên bị testbench giới hạn; số do phần cứng giới hạn ở mục 2.3.

### 2.2 Chia chu kỳ theo pha, luồng dữ liệu
Nguồn: `power/job_*/job_*.phases.csv` (GLS) và `perf_rtl_subjobs.csv` (RTL, khớp GLS từng chu kỳ); script `scripts/phases.py`, `vcd_job_ip.py`.

Mỗi chu kỳ thuộc đúng một pha, lấy theo trạng thái FSM của BufferFeeder và các dòng của testbench:
- **cấu hình:** IDLE trước beat vào đầu tiên (ghi và đọc lại AXI-Lite);
- **nạp:** IDLE từ beat vào đầu tiên tới tile đầu tiên, gồm feature và weight vào SRAM; hai luồng xen kẽ nhau nên chung chu kỳ;
- **nạp weight theo tile:** SET_WEIGHT, mỗi tile 32×32 đẩy vào PE;
- **tính:** SET_FEATURE;
- **xuất:** IDLE sau tile cuối, gồm xả pipeline và các beat kết quả cuối.

Không có beat kết quả nào được nhận trong lúc tính (0 ở cả 3 kích thước): IP không chồng nạp, tính và xuất lên nhau.

| Kích thước | Cấu hình | Nạp | Nạp weight (số tile) | Tính | Xuất | Job |
|---|---|---|---|---|---|---|
| 64×64×64, testbench gốc | 49 | 579 | 136 (4) | 646 | 235 | 1645 |
| 64×64×64, full-rate | 47 | 197 | 136 (4) | 646 | 200 | 1226 |
| 8×32×544, testbench gốc | 49 | 2723 | 578 (17) | 1801 | 179 | 5330 |
| 8×32×544, full-rate | 47 | 1093 | 578 (17) | 1801 | 142 | 3661 |
| 16×992×32, testbench gốc | 49 | 4001 | 1054 (31) | 3503 | 1047 | 9654 |
| 16×992×32, full-rate | 47 | 1029 | 1054 (31) | 3503 | 1042 | 6675 |

AXI-Stream:
- 3 luồng (feature vào, weight vào, kết quả ra), mỗi luồng 256 bit (32 byte INT8) mỗi beat.
- Ở 50 MHz: 1,6 GB/s mỗi luồng; 3,2 GB/s cho hai luồng vào, 4,8 GB/s cho cả ba.
- AXI-Lite 32 bit, 4 thanh ghi cấu hình.

| Kích thước | Beat feature / weight / kết quả | Byte vào / ra mỗi job | Băng thông vào đạt được (testbench gốc / full-rate) |
|---|---|---|---|
| 64×64×64 | 128 / 128 / 128 | 8192 / 4096 | 0,249 / 0,334 GB/s |
| 8×32×544 | 8 / 544 / 136 | 17 664 / 4352 | 0,166 / 0,241 GB/s |
| 16×992×32 | 496 / 992 / 16 | 47 616 / 512 | 0,247 / 0,357 GB/s |

### 2.3 Kích thước lớn và kiểu LLM (mô phỏng RTL)
Nguồn: `perf_rtl_shapes.csv`, `perf_rtl_subjobs.csv`; script `scripts/perf_rtl.py`, `run_system_paper.sh` (bản sao `sim/run_system.sh`, cấu hình `asic-sram`, WRAP=lean, AXIS_CG=1, tức asic-sram_axileancg; RTL không đổi); đồ thị `figures/roofline.*`, `figures/pe_utilisation.*`.

Kiểm chéo:
- RTL cho đúng số chu kỳ của GLS ở cả 3 kích thước (1645 / 5330 / 9654).
- Mọi job chạy đều có 0 lệch dữ liệu và 0 lỗi giao thức.
- Với các job rất ngắn, testbench báo OVERALL FAIL chỉ vì không kịp thấy cờ busy; dữ liệu vẫn đúng.

Một job phần cứng phải vừa bộ đệm:
- feature M·Kb ≤ **511** từ;
- weight Kpad·Nb ≤ **1023**;
- kết quả M·Nb ≤ **511**;
- Kb, Nb ≤ 31.

Bộ đếm từ có log2(depth) bit, nên 512 từ quay về 0: chạy 128×128×128 thành một job thì treo sau 1 beat (đã thử). Ma trận lớn hơn được host chia theo M và N thành các job con gần bằng nhau, chạy liền nhau. Không chia theo K, vì kết quả là INT8 sau phép dịch, nên K ≤ 992. Tổng chu kỳ bằng tổng chu kỳ các job con, mỗi job con trả chi phí cấu hình riêng.

| Hình dạng | M×K×N | Số job con | GOPS (testbench gốc / full-rate) | Tỉ lệ dùng PE (gốc / full-rate) | ops/byte AXIS |
|---|---|---|---|---|---|
| vuông | 128×128×128 | 2 | 17,24 / 23,43 | 16,8 / 22,9 % | 64,0 |
| vuông | 256×256×256 | 15 | 14,80 / 20,43 | 14,5 / 20,0 % | 56,9 |
| vuông | 512×512×512 | 272 | 9,38 / 13,27 | 9,2 / 13,0 % | 30,1 |
| attention Q·Kᵀ, 1 head (128 token, d 64) | 128×64×128 | 2 | 16,21 / 21,90 | 15,8 / 21,4 % | 51,2 |
| attention P·V, 1 head | 128×128×64 | 2 | 17,08 / 23,12 | 16,7 / 22,6 % | 51,2 |
| chiếu QKV/out, d_model 768, 128 token (prefill) | 128×768×768 | 168 | 5,95 / 8,57 | 5,8 / 8,4 % | 22,9 |
| FFN lên 768→3072, 128 token | 128×768×3072 | 672 | 5,95 / 8,57 | 5,8 / 8,4 % | 22,9 |
| chiếu, decode batch 8 | 8×768×768 | 24 | 2,70 / 3,95 | 2,6 / 3,9 % | 12,7 |
| chiếu, decode batch 1 (GEMV), đệm lên M = 2 | 1×768×768 | 24 | 0,34 / 0,51 | 0,3 / 0,5 % | 1,9 |

- Ngay cả full-rate, tỉ lệ dùng PE cao nhất cũng chỉ khoảng 23 %. Pha tính chiếm 50–58 % số chu kỳ, phần còn lại là nạp, nạp weight và xuất, chạy nối tiếp nhau.
- Bản thân pha tính cũng chưa đầy, vì mỗi tile phải trả độ trễ đổ đầy pipeline (khoảng 97 chu kỳ) cho chỉ M hàng.
- Roofline: trần tính 102,4 GOPS; trần băng thông 4,8 GB/s × ops/byte. Mọi điểm nằm dưới cả hai trần nhiều lần. IP bị giới hạn bởi việc các pha không chồng lên nhau, không phải bởi băng thông.
- K > 992 (ví dụ d_model 4096) không chạy đúng được nếu không cộng dồn phần chia K ở host trước khi lượng tử hoá; phần cứng hiện không hỗ trợ.

## 3. Công suất và năng lượng cả job (TT 25 °C 1,80 V, SPEF RC nom, 50 MHz)
Nguồn: `energy_job_50MHz.csv`, `power_by_phase_50MHz.csv`, `power/job_*/` (`*.groups.txt`, `*.design.rpt`, `*.phases.csv`, `*.sram.csv`); script `scripts/job_power.sh`, `vcd_job_ip.py`, `vcd2act_phases.py`, `power_phases.tcl`, `job_energy.py`.

Cách làm:
- GLS trên netlist cuối (unit delay), dump VCD mọi net ở độ sâu 1 của top, 32 row và AXI;
- cửa sổ là **toàn bộ job 2**, từ JOB_START tới RESULT_ACCEPT cuối;
- mỗi chu kỳ gắn với một pha (mục 2.2); toggle đếm riêng theo pha; duty lấy theo cả job và dùng chung cho mọi pha;
- `report_power` của OpenSTA cho cả job và cho từng pha, với netlist và SPEF của từng macro;
- VCD 541 / 1252 / 2510 MB, mỗi lúc một file, xoá ngay sau khi tính.

### 3.1 Cả job
| Kích thước | Chu kỳ | Công suất (mW) | Năng lượng / GEMM (µJ) | pJ/MAC | GOPS | GOPS/W | Cận dưới SRAM: mW / µJ / pJ/MAC / GOPS/W |
|---|---|---|---|---|---|---|---|
| 64×64×64 | 1645 | **745,1** | **24,51** | **93,5** | 15,94 | **21,4** | 626,1 / 20,60 / 78,6 / 25,5 |
| 8×32×544 | 5330 | 751,0 | 80,06 | 574,9 | 2,61 | 3,5 | 622,8 / 66,39 / 476,7 / 4,2 |
| 16×992×32 | 9654 | 753,5 | 145,48 | 286,4 | 5,26 | 7,0 | 626,5 / 120,96 / 238,1 / 8,4 |

- Tổng năng lượng theo từng pha khớp với số cả job: 24,54 / 80,55 / 145,31 µJ.
- Đỉnh 102,4 GOPS chia cho công suất cho 136–137 GOPS/W. Đây chỉ là cận trên lý thuyết, không đạt được (mục 2.3).
- Theo khối, cả job 64×64×64: SRAM 224,0; 32 row 376,5; cell ở top 141,7; AXI 2,8 mW. Cây clock (top + row + AXI) chiếm 199,6 mW trong đó.
- Vectorless (hoạt động mặc định của OpenSTA) cho 1377,6 mW; chỉ là số tham khảo.

### 3.2 Theo pha (mW)
| Kích thước | Cấu hình | Nạp | Nạp weight | Tính | Xuất | Cả job |
|---|---|---|---|---|---|---|
| 64×64×64 | 712,8 | 715,8 | 717,7 | **785,5** | 734,8 | 745,1 |
| 8×32×544 | 754,8 | 755,6 | 754,2 | 755,9 | 756,8 | 751,0 |
| 16×992×32 | 746,2 | 747,9 | 746,9 | 761,2 | 747,4 | 753,5 |

- Công suất gần như không đổi giữa các pha. Khoảng 650 mW (SRAM theo lib 224, chân clock của flop, cây clock) chạy theo clock chứ không theo dữ liệu, vì row không có clock gating.
- Chênh lệch lớn nhất là ở 64×64×64: pha tính cao hơn pha cấu hình 73 mW (row 406 so với 357 mW; cell ở top 152 so với 129 mW).
- Các số "cả job" của 8×32×544 và 16×992×32 hơi khác trung bình có trọng số của các pha, vì duty dùng chung; độ chênh dưới 1 %.

### 3.3 Leakage theo khối, 3 corner
Nguồn: `leakage_by_block_3corners.csv`; script `scripts/leak_blocks.sh`, `leak_blocks.tcl`, `leak_blocks.py`. Mỗi khối chạy riêng với netlist và SPEF của nó, cell chuẩn ở đúng corner; SRAM dùng lib TT ở mọi corner. Top chạy với row/AXI dưới dạng lib trừu tượng.

| Corner | Cell ở top | 32 row | Vỏ AXI | SRAM (lib TT) | Tổng |
|---|---|---|---|---|---|
| tt_025C_1v80 | 0,0026 | 0,0040 | 0,0001 | 2,836 | **2,843 mW** |
| ff_n40C_1v95 | 0,0049 | 0,0080 | 0,0002 | 2,836 | **2,849 mW** |
| ss_100C_1v60 | 1,022 | 4,494 | 0,067 | 2,836 | **8,420 mW** |

- Cột cell đã gồm filler/decap/tap; phần này chỉ 0,001–0,002 mW. Một row: 0,13 µW (TT), 0,14 mW (SS).
- Tổng khớp với bản chạy phân cấp trước (`leakage_3corners.csv`: 2,843 / 2,849 / 8,415 mW).

### 3.4 SRAM: số chu kỳ được chọn, khoảng công suất
Nguồn: `sram_range_50MHz.csv`, `power/job_*/job_*.sram.csv`; script `scripts/sram_range.py`.
- Lấy mẫu `csb0`/`csb1`/`web0` của từng macro ở cuối mỗi chu kỳ, đúng giá trị macro chốt ở cạnh clock.
- Lib tính 27,6 pJ mỗi cổng mỗi chu kỳ bất kể `csb`. Cận trên là số lib: 80 × 2 cổng × 27,6 pJ × 50 MHz + leakage = 223,8 mW.
- Cận dưới: chỉ những chu kỳ cổng được chọn mới tốn năng lượng đó.

| Kích thước | Cổng 0 được chọn (đều là ghi) | Cổng 1 (đọc) được chọn | SRAM cận dưới – cận trên |
|---|---|---|---|
| 64×64×64 | 13,3 % | 79,2 % | **105,0 – 223,8 mW** |
| 8×32×544 | 4,4 % | 79,7 % | 95,8 – 223,8 mW |
| 16×992×32 | 5,2 % | 80,0 % | 97,0 – 223,8 mW |

- Cổng đọc của 64 trong 80 macro được chọn ở mọi chu kỳ, vì RTL để read enable luôn bằng 1 ("read every cycle"). Vì vậy cận dưới vẫn khoảng 100 mW, và đó là một chỗ có thể tiết kiệm trong thiết kế.

## 4. PE và row
Nguồn: `blocks_pe_row.csv`, `fmax_*.rpt`, `power/block_*`; script `scripts/block_sim_power.sh`, `block_fmax.tcl`, `sim/tb_block_rand.v`.
- **PE** được harden riêng bằng cấu hình `gemm_pe` của flow hiện tại (run `gemm_pe/runs/paper_pe`). DRC 0, LVS 0 lỗi, antenna 0.
- **Row** dùng run `row_v1`, chính là row nằm trong IP.
- **Mô phỏng:** dữ liệu ngẫu nhiên; netlist gate-level so với RTL từng chu kỳ (PE 1229 lần so, row 1198 lần so, 0 lệch); cửa sổ 1000 chu kỳ.
- **Công suất** đo ở TT, SPEF RC nom, clock đặt lại 20 ns. Đường này dùng `vcd2act_flat.py`, vốn đã xử lý alias, nên không bị lỗi ở mục "Thay đổi".
- **fmax** tính theo path flop→flop, SPEF RC nom, propagated clock, fmax = 1/(T − slack).

| | PE | Row (32 PE) |
|---|---|---|
| Diện tích | die 17 218 µm²; core 13 085 µm²; cell (tổng hợp) 6 604 µm² | die 468 800 µm²; cell 259 100 µm² |
| Flop | 82 (66 `dfxtp` + 16 `dfrtp`) | 2 616 |
| fmax TT / SS | 208,9 / 108,7 MHz | 172,3 / 90,2 MHz |
| Công suất ở 50 MHz, dữ liệu ngẫu nhiên | 0,666 mW | 22,13 mW |
| Năng lượng mỗi MAC | **13,3 pJ** | **13,8 pJ** |

- Trong IP, một row tiêu trung bình 11,8 mW cả job 64×64×64 và 12,7 mW ở pha tính, thấp hơn mức dữ liệu ngẫu nhiên.
- Năng lượng mỗi MAC của cả IP (79–575 pJ) cao hơn của PE nhiều, vì gồm SRAM, cây clock và thời gian PE không tính.

## 5. IR drop (tĩnh, TT, 50 MHz)
Nguồn: `irdrop_v2A_summary.csv`, `irdrop_v2B_summary.csv`, `irdrop_ip_v2_summary.csv`, `irdrop_v2*_worst100.csv`, `irdrop_row.csv`, các log `irdrop_v2A.log`, `irdrop_v2B.log`, `irdrop_row.log`; script `scripts/ir_drop.tcl`, `ir_row.tcl`, `ir_map.py`.

### 5.1 Cả IP
- `analyze_power_grid` của OpenROAD trong OpenLane 1.0.2.
- Cell ở top: hoạt động VCD của pha tính, job 64×64×64. SRAM: lib OpenRAM.
- Row và vỏ AXI: công suất pha tính (12,69 mW mỗi row, 3,28 mW cho AXI), gắn vào bản sao lib dưới dạng `cell_leakage_power`, vì lib của hai macro này không có số công suất.
- Tổng công suất PSM dùng là 789 mW, khớp với 785,5 mW của mục 3.2.
- **Mô hình A:** bàn cờ bump mặc định của PSM (140 µm, 642 nguồn trên toàn core). Giống bản trước, chỉ đổi activity.
- **Mô hình B:** 406 nguồn ở hai đầu của 203 dải met5 là chân vccd1/vssd1 trong LEF của IP, tức dòng vào từ mép die. Đây là mô hình gần hơn với một IP được nối vào chip.

| Mô hình | vccd1 tệ nhất | vssd1 tệ nhất | Trung bình (vccd1 / vssd1) | p99 (vccd1 / vssd1) | VDD−VSS tệ nhất tại một cell (bỏ filler/tap/diode) | Số cell > 200 mV |
|---|---|---|---|---|---|---|
| A | 137,2 mV | 153,7 mV | 1,65 / 1,58 mV | 7,9 / 9,5 mV | 290,7 mV (nút macro row 0) | 399 (đều là nút của row 0) |
| B | 120,5 mV | 125,0 mV | 38,1 / 37,5 mV | 110,5 / 114,1 mV | 180,4 mV (hold24927) | 0 |

- A dồn dòng của row vào chân macro, nên sụt áp tập trung ở góc row 0.
- B cho sụt áp lan rộng hơn, lớn nhất ở giữa mảng row (ảnh `figures/irdrop_map_v2A.*`, `irdrop_map_v2B.*`).
- Tại nút macro row, theo B: VDD tối đa 86,1 mV, VSS 93,6 mV, VDD−VSS 179,7 mV.

### 5.2 Bên trong một row
- Chạy riêng `row_v1` với netlist và SPEF của nó, cùng hoạt động VCD của row 0 ở pha tính 64×64×64 (12,7 mW).
- Nguồn ở tâm mỗi dải met4 là chân vccd1 (4 dải) và vssd1 (4 dải) trong LEF của row; các dải cách nhau khoảng 876 µm.

| Lưới | Tệ nhất | Vị trí | Trung bình |
|---|---|---|---|
| vccd1 | **17,9 mV** | x 1765,6, y 13,6 µm (giữa hai dải) | 4,0 mV |
| vssd1 | **41,8 mV** | x 5,5, y 114,2 µm (mép trái; dải vssd1 đầu tiên ở x 882) | 6,1 mV |

Phần này cộng thêm vào mức sụt của lưới IP tại chân row.

### 5.3 Lập luận về dải điện áp
Đề bài nêu: 1,80 V − 139 mV = 1,66 V, vẫn trên 1,60 V của corner SS, nơi các path giữa các cell đã đạt. Kiểm lại với số mới:
- **Chỉ tính phía VDD:** A: 1,80 − 0,137 − 0,018 = **1,645 V**; B: 1,80 − 0,086 − 0,018 = **1,696 V**. Cả hai đều trên 1,60 V.
- **Cell thật sự thấy VDD − VSS**, nên phải cộng cả độ nâng của VSS.
  - Ở chân row, theo B, cộng tệ nhất của IP và bên trong row (giả định các điểm tệ nhất trùng nhau, tức bi quan): 0,180 + 0,018 + 0,042 = 0,240 V, còn **1,56 V**, dưới 1,60 V.
  - Theo A, tại nút row 0: 0,291 + 0,060 = 0,35 V. Mô hình A dồn dòng vào chân macro, nên số này phóng đại.
  - Các cell ở top theo B đều dưới 200 mV (tối đa 180 mV, còn 1,62 V).
- **Kết luận:** lập luận "1,66 V > 1,60 V" chỉ đúng nếu bỏ qua độ nâng của VSS. Tính cả hai lưới, chỗ tệ nhất trong row có thể xuống khoảng 1,56 V ở TT. Corner SS signoff là process SS, 1,60 V, 100 °C. Một cell process TT, 25 °C ở 1,56 V vẫn nhanh hơn cell ở corner đó, nên timing nhiều khả năng vẫn đạt. Nhưng trường hợp process SS cộng IR drop thì chưa được phân tích. Đây là phân tích tĩnh, chưa có IR động.

## 6. Ảnh
| File | Nội dung |
|---|---|
| `figures/layout/chip_full.png` | KLayout, cả chip (độ sâu phân cấp 1) |
| `figures/layout/chip_blocks.png/.pdf` | cả chip, tô màu theo khối: SRAM, row, AXI, logic ở top, buffer hold, diode, cây clock (cell chuẩn vẽ rộng thêm 3 µm để thấy được; filler/decap/tap không vẽ). Script `scripts/block_maps.py` |
| `figures/layout/row_pe_map.png/.pdf` | một row, cell tô theo chỉ số PE, chỉ vẽ khung cell, không có dây |
| `figures/layout/row_pe_map_zoom_pe0_3.png/.pdf` | như trên, phóng to 4 PE đầu |
| `figures/layout/pe_about_one.png` | 110 µm đầu của row 0, khoảng 1 PE |
| `figures/layout/sram_macro.png` | một SRAM (`u_feature_tile_mem g_bank[0].g_lane[0]`) |
| `figures/layout/eco_clk_20.png` | vùng clkbuf ECO `eco_clk_20` |
| `figures/openroad/ip.layout.png` | OpenROAD, cả chip |
| `figures/openroad/ip.clocktree.png` | cây clock `S_AXI_ACLK` (trình xem cây clock của OpenROAD) |
| `figures/placement_density.*` | mật độ đặt cell, ô 10 µm (dữ liệu `ip.heatmap_Placement.csv.gz`) |
| `figures/routing_utilisation.*` | mật độ dây sau route theo lớp, ô 50 µm |
| `figures/irdrop_map_v2A.*`, `irdrop_map_v2B.*` | bản đồ IR drop vccd1 và vssd1, mô hình A và B |

- Ảnh row tô theo PE: row đã phẳng và tên instance là tên chung (`_12345_`, `holdN`), nên **chỉ số PE lấy từ tên net**, vì net còn giữ phân cấp `g_pe_column[k].u_processing_element.*`.
  - 9 710 cell nằm trực tiếp trên net như vậy.
  - Cell còn lại lấy chỉ số PE chiếm đa số của các cell chung net với nó (net có fanout ≤ 16), lặp đến khi không đổi. Kết quả: 24 351 / 24 581 cell logic có chỉ số.
  - Cell màu xám là cây clock, logic dùng chung, filler, tap và diode.
- Heatmap kẹt dây của OpenROAD không có: bản này không có RUDY, còn heatmap Routing cần dữ liệu global route. Thay vào đó dùng mật độ dây thật sau route.

## 7. Đồ thị (CSV + `scripts/plots.py`, `scripts/plots_perf.py`, PNG và PDF)
| Hình | Dữ liệu | Nội dung |
|---|---|---|
| `antenna_convergence` | `antenna_convergence.csv` | ECO route lại toàn bộ (OL1, ip_v3r: 1133 → 446 → 293, trong đó 266 chân mới; mỗi vòng route lại 100 % net) so với ECO tăng dần (446 → 37 → 6 → 3 → 1 → 0; mỗi vòng route lại 0,60 / 0,04 / 0,01 / 0,01 / 0,003 % net). Thời gian mỗi vòng: OL1 1749–5458 s, tăng dần 993–1089 s |
| `drv_by_eco_round` | `drv_by_eco_round.csv` | Net cell chuẩn vượt lib ở TT nom và SS max, qua từng lượt ECO: 435/1673 → 0/0 |
| `sram_clk_slew` | `sram_clk_slew_before_after.csv` | Slew chân clock SRAM. Trước khi sửa clock (layout a2): TT max 3,83 ns, 43 chân > 0,75 ns. Sau: TT max 0,739 ns, SS max 0,998 ns |
| `slack_histograms` | `slack_histogram_final.csv` | Histogram slack setup/hold của layout cuối, TT/FF/SS × RC max, theo loại path |
| `cap_ratio_rcx_grt` | `cap_ratio_rcx_grt.csv` | Điện dung RCX (max) so với ước lượng sau global route trên 85 net dài: 1,54–2,71 lần, trung vị 2,05 |
| `roofline` | `perf_rtl_shapes.csv` | Roofline: trần 102,4 GOPS và 4,8 GB/s (đường chấm: 3,2 GB/s chỉ tính luồng vào); điểm của 12 hình dạng, testbench gốc và full-rate |
| `pe_utilisation` | `perf_rtl_shapes.csv` | Tỉ lệ dùng PE theo hình dạng, và phần chu kỳ theo pha (full-rate) |

Ghi chú về số chân antenna của ip_v3r: báo cáo vòng 2 có 294 dòng nhưng chỉ 293 chân khác nhau, và 266 chân trong đó không có ở vòng 1. Đồ thị dùng số chân khác nhau.

## 8. Kiểm tương đương hình thức PE
Nguồn: `pe_equiv2_yosys062.log`, `pe_equiv2_yosys030.log` (bản mới), `pe_equiv.log` (bản cũ); script `scripts/pe_equiv2.ys`, `pe_equiv.ys`.
- **Đối tượng:** RTL `rtl_asic/PE.v` (P_DATAPATH_RESET = 0, như trong flow) so với netlist cuối của PE đã harden. Mô hình cell lấy từ liberty TT.
- **Số flop hai bên bằng nhau, 82 = 82.**
  - Có reset: `r_weight_shift` 8 và `r_weight_value` 8.
  - Không reset: `r_product` 16, `r_partial_sum_d1` 21, `o_partial_sum` 21, `o_feature_value` 8.
  - Bản trước so 82 flop của netlist với 66 flop không reset của RTL, nên kết luận sai rằng có flop thừa.
- **Lý do lần đầu không ghép được:** netlist tách bus thành dây một bit tên `\r_product[3] `, còn RTL giữ bus `r_product`. Ngoài ra 37 flop nối ra cổng qua buffer đầu ra, nên Q của chúng mang tên `netNN`.
- **Cách mới:** `splitnets` cho RTL để tên trùng với netlist, rồi `equiv_make` ghép:
  - 45 bit thanh ghi trong (`r_product`, `r_partial_sum_d1`, `r_weight_value`);
  - 37 bit đầu ra (`o_partial_sum`, `o_feature_value`, `o_weight_shift_out` = `r_weight_shift`);
  - 16 bit `w_product`.

  Sau đó chạy `equiv_simple -seq 5` và `equiv_induct -seq 5`.
- **Kết quả:** 98/98 ô `$equiv` đã chứng minh, `equiv_status -assert` đạt, trên cả Yosys 0.62 (image LibreLane, có eqy và sby nhưng không cần) và Yosys 0.30 (OpenLane 1.0.2).
- **Kết luận:** netlist PE tương đương tuần tự với RTL. Điều kiện là các thanh ghi tương ứng xuất phát cùng giá trị: thanh ghi có reset thì sau reset; thanh ghi dữ liệu không reset thì giả định trạng thái đầu giống nhau, như mọi phép ghép thanh ghi.
- Mô phỏng ngẫu nhiên ở mục 4 cũng không thấy lệch nào giữa netlist và RTL của PE và row.

## 9. Tái lập
Nguồn: `reproducibility.csv` (thời gian và RAM từng bước), `machine.csv` (máy, image, phiên bản), `final/TOOLS.txt`, `final/MANIFEST`.
- **Máy:** Intel i7-14700HX (28 luồng), 15 GiB RAM cùng 32 GiB swap, AlmaLinux 10.2, Docker 29.8.2. Mọi container giới hạn 10g/40g.
- **Image OpenLane 1.0.2:** `sha256:832662c8…779a`; OpenROAD 41a51eaf, Magic 8.3.413, Netgen 1.5.255, KLayout 0.28.2, Yosys 0.30+48, OpenSTA 2.4.0.
- **Image ECO:** LibreLane 3.0.16 `sha256:4bc9042b…5051` (OpenROAD dcf36133; Yosys 0.62, eqy, sby).
- **PDK:** open_pdks 0fe599b2. Icarus Verilog 13.0. matplotlib 3.9.2 trong `paper/.venv`.
- **GDS cuối:** `final/GEMM_top.gds`, sha256 `87286b9408d1a706d1f47a2925317ed5ed702c0700b780edbdda0a22e8b068fa`.
- **Repo:** nhánh `eco-signoff-wip`; script ECO ở `tools/eco`, gói này ở `docs/paper`.
