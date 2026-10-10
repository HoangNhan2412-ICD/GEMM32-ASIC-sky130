# Hướng dẫn chạy

Các lệnh dưới đây đã chạy trên máy build của dự án (Linux, 15,5 GB RAM, 32 GB swap). Chỗ nào chưa chạy
lại được thì có ghi "chưa kiểm".

## 1. Yêu cầu máy

- RAM: 16 GB. Run core lên đỉnh khoảng 13 GB (detailed route), global route khoảng 6 GB. Nên có thêm swap.
  Không chạy hai run OpenLane lớn cùng lúc.
- Ổ trống: 40 GB cho một run core (`core` tự dừng nếu thiếu). Một run core xong chiếm khoảng 20-25 GB.
- Thời gian (máy trên, các run thật):

| Tầng | Thời gian |
|---|---|
| sim | khoảng 6 phút |
| pe | 2 phút |
| row | 27 phút |
| array | 3 giờ 14 phút |
| core-sim | khoảng 2 phút |
| core-pre | khoảng 10 phút |
| core | khoảng 7-9,5 giờ (core_v9: 7h02m, route 3h22m; core_v11: 9h26m, route 5h44m) |
| core-gls | khoảng 40 phút cho 3 kích thước ma trận với row gate-level (core_v11: 327 s, khoảng 570 s, 1317 s); khoảng 13 phút nếu `ROW=rtl` |

## 2. Cài đặt

Docker:

    docker --version                     # máy build: Docker 29.8.2
    docker run --rm hello-world

OpenLane 1.0.2 (commit ff5509f6) vào ~/OpenLane. `make` kéo image và cài PDK sky130A vào ~/.ciel bằng ciel
(chưa kiểm lại trên máy mới; máy build đã cài sẵn theo cách này):

    git clone --depth 1 -b 1.0.2 https://github.com/The-OpenROAD-Project/OpenLane.git ~/OpenLane
    make -C ~/OpenLane

Kiểm tra:

    git -C ~/OpenLane log -1 --format=%H        # ff5509f65b17bfa4068d5336495ab1718987ff69
    docker images | grep openlane               # ghcr.io/the-openroad-project/openlane:ff5509f6...
    ~/OpenLane/venv/bin/ciel ls --pdk sky130    # 0fe599b2afb6708d281543108caf8310912f54af
    ls ~/.ciel/sky130A/libs.ref/sky130_sram_macros/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef

Công cụ trên máy (ngoài Docker):

    iverilog -V | head -1                       # máy build: Icarus Verilog 13.0
    python3 --version                           # máy build: 3.12

Mã nguồn: repo này và repo gốc GEMM_32x32_KV260 (lấy testbench) đặt cạnh nhau, tên thư mục repo gốc là
GEMM_32x32_KV260-main (hoặc đặt biến REPO trỏ tới nó):

    mkdir -p ~/gemm_asic && cd ~/gemm_asic
    git clone -b hierarchical-openlane-flow https://github.com/HoangNhan2412-ICD/GEMM32-ASIC-sky130.git
    # repo gốc: giải nén hoặc clone vào ~/gemm_asic/GEMM_32x32_KV260-main
    cd GEMM32-ASIC-sky130

## 3. Chạy từng tầng

Mỗi tầng chỉ chạy khi tầng trước đã PASS (ghi trong openlane/LOG.md). Mỗi lần chạy in `STAGE <tầng> PASS`
hoặc `FAIL` ở cuối. Run của OpenLane nằm ở ~/OpenLane/designs/<design>/runs/<tag>.

| Lệnh | Làm gì | Dấu hiệu PASS | Kết quả |
|---|---|---|---|
| `openlane/run_flow.sh sim` | RTL ASIC chạy testbench gốc, so với RTL FPGA | OVERALL PASS, trùng chu kỳ mọi kết quả | openlane/logs/sim_* |
| `openlane/run_flow.sh pe` | Harden một PE, đo diện tích | PASS, ghi diện tích PE | gemm_pe/runs/pe_v1 |
| `openlane/run_flow.sh row` | Macro 32 PE; kiểm LEF và so netlist với RTL | "row netlist = RTL" | gemm_row/runs/row_v1 |
| `openlane/run_flow.sh array` | FeatureSkew + 32 row + OutputDeskew | 32 macro đặt đúng, DRC/LVS sạch | gemm_array/runs/array_v1 |
| `openlane/run_flow.sh core-sim` | RTL core với model SRAM OpenRAM, 3 kích thước | OVERALL PASS, trùng chu kỳ | openlane/logs/core_sim_* |
| `openlane/run_flow.sh core-pre` | Lint, synthesis, floorplan của core | 80 SRAM, 32 row, macro đặt đủ | gemm_core/runs/core_pre |
| `openlane/run_flow.sh core` | Run core đầy đủ | xem mục 5 | gemm_core/runs/core_v11 |
| `openlane/run_flow.sh core-gls` | Testbench gốc trên netlist cuối của core, 3 kích thước | OVERALL PASS, trùng chu kỳ cả 3 | openlane/logs/core_gls_* |

GDS của core: ~/OpenLane/designs/gemm_core/runs/<tag>/results/final/gds/GemmAccelerator.gds.

`core` chạy với cấu hình của core_v11 (giống core_v9, chỉ khác row macro đã chạy lại), không cần biến môi trường. TAG đặt tên run khác (mặc định core_v11).
`core-gls` dùng run core mới nhất có results/final; TAG chọn run khác. Mặc định row được mô phỏng bằng netlist
gate-level của row (`ROW=gl`, đỉnh 3,1 GB RAM): chỉ cách này mới thấy lỗi trong netlist row. `ROW=rtl` dùng RTL
của row, nhanh hơn, chỉ để thử nhanh.

## 4. Theo dõi khi chạy core

Run core dài nên chạy nền, tách khỏi terminal (nếu không, đóng terminal là run chết):

    setsid nohup openlane/run_flow.sh core > ~/core_out.txt 2>&1 < /dev/null &

Xem tiến độ (chỉ đọc file, chạy lúc nào cũng được):

    openlane/run_flow.sh core-status

Lệnh này in bước đang chạy, log mới nhất, overflow của global route, số lỗi detailed route, RAM và ổ trống.
Log đầy đủ: openlane/logs/gemm_core_<tag>_<thời điểm>.log và ~/OpenLane/designs/gemm_core/runs/<tag>/logs/.
RAM theo thời gian: openlane/logs/mem_gemm_core_<tag>_<thời điểm>.txt.

## 5. Đọc kết quả

Tổng hợp (miễn timing ở cổng I/O vì đây là core, chưa có vòng pad):

    python3 openlane/check_openlane_run.py --waive-io-timing ~/OpenLane/designs/gemm_core/runs/core_v11

core_v11 cho: router 0 lỗi, LVS 0 lỗi, setup nội bộ +1,21 ns, hold nội bộ +0,27 ns, 219 pin / 205 net antenna,
RAM đỉnh 13,5 GB. Script vẫn ghi RESULT: FAIL vì hai mục dưới.

Antenna: còn 205 net, đa số vượt nhẹ (trung vị 1,4 lần giới hạn), không net nào trên chân SRAM. Router của
OpenROAD bản này không tính antenna khi đi dây và không có chế độ ECO. Flow chèn diode ở global route, rồi
sau detailed route chạy 3 vòng ECO (đặt diode cạnh cổng vi phạm và route lại). Mỗi lần route lại sinh vi phạm
mới ở chỗ khác, nên con số dừng quanh 200.

Magic DRC: Magic đọc SRAM và row macro bằng view abstract, trong đó vùng OBS là kim loại đặc. Dây đi sát
mép macro bị báo lỗi khoảng cách kim loại rộng (met4.5b, met2.3b) mà layout thật không có. Kiểm lại từng cờ
trên GDS đầy đủ:

    tools/magic_macro_check.sh ~/OpenLane/designs/gemm_core/runs/core_v11

core_v11: 48 cờ (đều met4.5b), cả 48 nằm sát macro, 0 lỗi trên layout đầy đủ, RESULT: PASS. Báo
cáo: reports/signoff/magic_macro_check.rpt. Lệnh cần vài GB RAM, không chạy cạnh detailed route.

Timing nhiều corner (setup ở ss/100°C/1,60V, hold ở ff/-40°C/1,95V, RC min và RC max):

    python3 tools/sta_corners.py ~/OpenLane/designs/gemm_core/runs/core_v11

core_v11: setup -7,61 ns (RC max) và -6,35 ns (RC min) ở corner chậm, tức khoảng 57 MHz; hold sạch với cả RC min
và RC max.

Công suất ở tt/25°C/1,80V, 100 MHz:

    tools/power.sh ~/OpenLane/designs/gemm_core/runs/core_v11                  # activity mặc định của OpenSTA
    tools/power.sh ~/OpenLane/designs/gemm_core/runs/core_v11 --vcd 2300 3200  # activity từ mô phỏng

core_v11: 2,89 W với activity mặc định; 1,53 W với activity từ VCD (mô phỏng gate-level kích thước 64x64x64,
row gate-level, chu kỳ 2300-3200 là pha tính của job thứ hai). Trong 1,53 W: SRAM 0,45 W (80 macro), row 0,78 W,
phần còn lại của core 0,30 W. Thư viện OpenRAM cho cùng năng lượng mỗi cạnh clock dù SRAM có được chọn hay không, nên phần
SRAM là cận trên. Mô phỏng không có trễ cổng nên không tính glitch. Đỉnh 204,8 GOPS (2 x 32 x 32 x 100 MHz),
tức 134 GOPS/W và 2,83 GOPS/mm². Bản --vcd mất khoảng 15 phút (core_v11: 13m27s, cửa sổ 900 chu kỳ), cần khoảng 8 GB RAM (mô phỏng đỉnh 7,0 GB) và 0,7 GB ổ.

Mô phỏng gate-level: `core-gls` in PASS và số sự kiện trùng chu kỳ cho từng kích thước. core_v11 với row
gate-level: PASS cả 3 kích thước (64x64x64, 8x32x544, 16x992x32), trùng chu kỳ 258, 274 và 34 sự kiện với RTL
FPGA. Log ở openlane/logs/core_gls_<thời điểm>/. Bản core_v9 cũ sai cột 23 khi mô phỏng với row gate-level, do
row macro bị resizer đổi chân một cell (NHATKY.md); flow hiện tại chặn lỗi này ở tầng row.

## 6. Xem GDS bằng KLayout

Máy có KLayout:

    klayout -nn ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyt \
            -l ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyp \
            ~/OpenLane/designs/gemm_core/runs/core_v11/results/final/gds/GemmAccelerator.gds

Máy không cài được thì dùng KLayout 0.28.2 trong image OpenLane (cần X11; máy build dùng cách này):

    xhost +local:
    docker run --rm -it -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix -v $HOME:$HOME \
        --user $(id -u):$(id -g) \
        ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64 \
        klayout -nn ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyt \
                -l ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyp \
                ~/OpenLane/designs/gemm_core/runs/core_v11/results/final/gds/GemmAccelerator.gds

Trong KLayout: Display > Full Hierarchy (phím `*`) để thấy bên trong macro; View > bỏ chọn Show Texts để tắt
chữ. GDS core khoảng 670 MB, mở mất vài phút và vài GB RAM. (Phần thao tác trong giao diện chưa kiểm lại
trong lần viết này.)

## 7. Lỗi hay gặp

Hết ổ: `core` và `core-route` kiểm ổ trước khi chạy và dừng nếu dưới 40 GB, kèm số GB còn trống. Xoá
runs/<tag>/tmp và results của các run cũ. `MIN_DISK_GB=<n>` hạ ngưỡng nếu chắc đủ.

Thiếu RAM: kernel giết OpenROAD ở detailed route, log dừng ngang không có lỗi. Kiểm tra bằng
`openlane/run_flow.sh core-triage` (đọc log, tìm thông báo OOM của kernel). Tắt chương trình khác, thêm swap.

Run bị ngắt giữa chừng (mất điện, đóng terminal) sau khi đã qua CTS: không cần chạy lại từ đầu.
core-route lấy layout sau CTS của run đó, route và signoff lại trong run mới <tag>r:

    FROM=core_v11 openlane/run_flow.sh core-route

Net xuyên macro: sau global route, macro_cross.py tìm net mà global route vạch xuyên lòng macro hơn 50 um
(SRAM chặn met1-met4 và met5 trên SRAM bị cấm, nên detailed route chắc chắn tạo short ở đó). Có net như vậy
thì run dừng ngay, báo cáo ở runs/<tag>/reports/routing/macro_cross.rpt. Cách xử lý là đổi floorplan hoặc
giảm nghẽn, không phải đổi seed.

Detailed route còn lỗi với mọi seed: lỗi ở cùng một chỗ qua nhiều seed là lỗi hình học. Xem vùng quanh lỗi:

    python3 tools/def_window.py <def> <run>/tmp/merged.nom.lef <x> <y> 12 <net...>

## 8. AXI accelerator IP (GEMM_top)

Phần này biến core thành một IP có giao tiếp chuẩn: AXI4-Lite để điều khiển, ba cổng AXI4-Stream 256 bit
(feature vào, weight vào, result ra). Core giữ nguyên. Bản KV260 vốn đã là một AXI IP như vậy (`rtl/GEMM_top.v`
và `axi_ip/` của repo gốc), nên ở đây chỉ chép wrapper đó sang `rtl_asic/axi/`, sửa cho hợp ASIC, rồi đo phần
nó tốn thêm.

    rtl_asic/axi/GEMM_top.v            top của IP, cùng tên, cổng, tham số và register map với bản KV260
    rtl_asic/axi/GemmAxiShell.v        mọi thứ trừ core: ResetSync, thanh ghi AXI4-Lite, cờ busy/done, 3 cổng AXIS
    rtl_asic/axi/AxiLiteControlRegs.v  thanh ghi 0x00-0x0C, handshake như template Xilinx của bản KV260
    rtl_asic/axi/AxisSkidBuffer.v      register slice hai ô cho một luồng valid/ready

Register map giữ nguyên nên driver KV260 (FPGA_GEMM.cpp) và testbench gốc dùng được ngay. Khác bản KV260 ở
hai chỗ. Thứ nhất, thanh ghi 0x04-0x0C chỉ lưu số bit core dùng (9, 5, 5), bit cao đọc ra 0. Phần mềm ghi giá
trị hợp lệ thì đọc lại vẫn đúng như cũ. Thứ hai, có ResetSync trên S_AXI_ARESETN (bản FPGA có proc_sys_reset
lo việc này).

Hai biến thể cổng stream, chọn bằng `GEMM_AXIS_REG` trong gemm_asic_cfg.vh (mặc định 1):

| | thin (0) | reg (1) |
|---|---|---|
| Cổng AXIS | nối thẳng vào core như bản KV260 | qua AxisSkidBuffer, mọi cổng ra/vào từ flop |
| TREADY | tổ hợp từ core và từ TSTRB | ra từ flop |
| Độ trễ thêm | 0 | 1 chu kỳ mỗi luồng, thông lượng vẫn 1 beat/chu kỳ |
| Timing ở cổng | bằng timing cổng của core (core_v11 đang miễn) | ngắn, không cần miễn |

Beat có TSTRB không đủ byte (driver KV260 không bao giờ gửi) không bao giờ vào core, và luồng dừng luôn ở đó
cho tới khi reset, như bản KV260. Khác ở chỗ: với thin, TREADY ở mức thấp nên master vẫn giữ beat; với reg,
slice đã nhận beat đó rồi mới dừng. Cả hai trường hợp job đều không xong. Cờ busy/done lấy theo handshake ở
cổng của IP, để "done" nghĩa là beat kết quả cuối đã ra khỏi IP chứ không chỉ rời core. TREADY của reg ở mức
thấp suốt lúc reset và một chu kỳ sau đó, vì reset bên trong nhả muộn hơn cổng hai chu kỳ (ResetSync).

### Chạy

| Lệnh | Làm gì | Dấu hiệu PASS | Thời gian |
|---|---|---|---|
| `openlane/run_flow.sh axi-sim` | Test riêng skid buffer; testbench gốc với thin, reg, reg + model OpenRAM (3 kích thước) | `AXI IP RTL: ALL PASS` | chưa kiểm, ước 10 phút |
| `openlane/run_flow.sh axi-shell` | Harden riêng GemmAxiShell (thin, reg), mỗi biến thể hai run (đo clock latency rồi chạy thật), đo công suất, in bảng overhead so với core | các run sạch DRC/LVS/antenna, có bảng | chưa kiểm |
| `openlane/run_flow.sh axi-gls` | Testbench gốc trên GEMM_top (reg) bọc netlist cuối của core, row gate-level | OVERALL PASS | khoảng 6 phút một kích thước |

Chạy riêng phần RTL không cần OpenLane: `sim/run_axi.sh`. Chọn wrapper cho các script cũ bằng biến WRAP:

    WRAP=thin sim/run_system.sh asic          # hoặc reg; fpga (mặc định) là wrapper của repo KV260
    WRAP=reg ROW=gl sim/run_gls.sh ~/OpenLane/designs/gemm_core/runs/core_v11

Điều mong đợi ở axi-sim: thin trùng chu kỳ từng sự kiện kết quả với RTL KV260, vì logic giống hệt. reg ra cùng
dãy kết quả, trễ hơn vài chu kỳ; script in khoảng lệch. Testbench gốc chặn result 1/7 chu kỳ và có khoảng trống
ở hai luồng vào, nên skid buffer được thử cả lúc đầy lẫn lúc rỗng. tb_axis_skid.v thử thêm valid/ready ngẫu
nhiên 80 000 beat.

### Đọc bảng overhead

axi-shell ghi bảng vào openlane/logs/axi_overhead_<thời điểm>.md (tools/axi_overhead.py). Các cột là core_v11,
shell thin, shell reg, và shell tính theo phần trăm của core. Cần báo cáo công suất vectorless của core
(`tools/power.sh <run core>` ghi reports/power/vectorless.design.rpt). Chưa có thì cột công suất của core để
trống.

- Diện tích: số cell sky130_fd_sc_hd sau synthesis nhân với diện tích từng cell trong liberty tt (script tự tìm
  dưới $PDK_ROOT, ~/.ciel, ~/.volare, hoặc `--lib`). Macro SRAM không bao giờ lọt vào con số này. Phía core được
  tính cả cell bên trong 32 row macro (lấy từ run row_v1), vì phần lớn logic của core nằm trong row; cell ở top
  core thôi chỉ là một phần nhỏ, so với nó thì phần trăm overhead bị phóng to nhiều lần. Die của run shell do
  ~1780 chân quyết định nên không có nghĩa (600 x 1500 um; bản 300 um đầu tiên nghẽn route ở mép Tây với reg).
  Dòng "placed area" (trước khi chèn filler) chia cho die core_v11 là phần die IP tốn thêm nếu đặt shell sát core.
- Timing: slack setup và hold ở cả ba corner, tách đường bên trong khối với đường chạm cổng. Với core_v11, đường
  chạm cổng đang được miễn (chưa có pad ring) nên chỉ đọc các dòng "inside the block". Shell dùng ngân sách cổng 30 % chu kỳ ở cả hai phía
  (GEMM_SHELL_IO_PCT trong config). Độ trễ ở cổng tính theo clock latency của chính shell, đo ở run hiệu chỉnh
  shell_<biến thể>_cal (cùng cách core.sdc làm với core). Không làm vậy thì mọi input của reg đều vi phạm hold
  bằng đúng latency, và resizer chèn delay cell vào cả ~560 input, làm phồng diện tích lẫn công suất. Dòng
  "violating setup paths at a port" cho thấy thin và reg khác nhau ở cổng.
- Công suất: OpenSTA activity mặc định ở cả hai bên, cùng cách với con số 2,89 W của core. Con số 1,53 W của
  core (VCD) được in để tham khảo. Shell chưa có số theo VCD.

Giới hạn của cách đo này: shell được harden riêng nên cây clock của nó không cân với cây clock của core, và
path giữa shell với core chưa được phân tích thật. Muốn có timing của cả IP thì cần bước 3 bên dưới.

### Bước 3 (chưa làm): chạy phẳng GEMM_top

Cho ra một GDS IP hoàn chỉnh: chạy lại core flow với top là GEMM_top, khoảng 9,5 giờ như core_v11. Những chỗ
cần sửa, đã đếm trên code hiện tại:

- gen_core_files.py: tên chân theo AXI (`feature_axis_tdata` thay `i_feature_data`...), thêm 3 x 32 chân TSTRB
  và 96 chân AXI4-Lite ở nhóm cfg/clk, tên macro trong macro.cfg có thêm tiền tố `u_gemm_accelerator.`
- config.tcl và core.sdc: DESIGN_NAME, VERILOG_FILES, CLOCK_PORT S_AXI_ACLK, false path cho S_AXI_ARESETN;
  cfg_shift_mcp.sdc tìm net `r_cfg_shift*` ở top, sau khi flatten phải tìm theo tên có tiền tố
- run_flow.sh có 63 chỗ ghi cứng gemm_core/GemmAccelerator; core_full.tcl, resume.tcl, route_signoff.tcl,
  keep_rows_clear.tcl, preflight.tcl cũng có. Nên làm design riêng gemm_axi thay vì sửa gemm_core, để không
  phá flow core đang sạch
- Với reg, các cổng AXIS đều ra/vào từ flop, nên bỏ được `--waive-io-timing` và đặt ngân sách cổng thật

Nên chạy axi-sim, axi-shell, axi-gls trước. Số overhead ở bước 2 đủ cho báo cáo; bước 3 cần khi muốn nộp
một IP có GDS hoàn chỉnh hoặc muốn số timing của cả IP.
