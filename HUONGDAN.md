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
| core | khoảng 7 giờ (core_v9: 7h02m, trong đó route 3h22m) |
| core-gls | khoảng 13 phút cho 3 kích thước ma trận (row bằng RTL) |

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
| `openlane/run_flow.sh core` | Run core đầy đủ | xem mục 5 | gemm_core/runs/core_v9 |
| `openlane/run_flow.sh core-gls` | Testbench gốc trên netlist cuối của core, 3 kích thước | OVERALL PASS, trùng chu kỳ cả 3 | openlane/logs/core_gls_* |

GDS của core: ~/OpenLane/designs/gemm_core/runs/<tag>/results/final/gds/GemmAccelerator.gds.

`core` chạy với cấu hình của core_v9, không cần biến môi trường. TAG đặt tên run khác (mặc định core_v9).
`core-gls` dùng run core mới nhất có results/final; TAG chọn run khác. Mặc định row được mô phỏng bằng RTL;
`ROW=gl` dùng netlist của row (chậm hơn, khoảng 7 GB RAM).

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

    python3 openlane/check_openlane_run.py --waive-io-timing ~/OpenLane/designs/gemm_core/runs/core_v9

core_v9 cho: router 0 lỗi, LVS 0 lỗi, setup nội bộ +1,01 ns, hold nội bộ +0,11 ns, 209 net antenna, RAM đỉnh
13,0 GB. Script vẫn ghi RESULT: FAIL vì hai mục dưới.

Antenna: còn 209 net, đa số vượt nhẹ (trung vị 1,4 lần giới hạn), không net nào trên chân SRAM. Router của
OpenROAD bản này không tính antenna khi đi dây và không có chế độ ECO. Flow chèn diode ở global route, rồi
sau detailed route chạy 3 vòng ECO (đặt diode cạnh cổng vi phạm và route lại). Mỗi lần route lại sinh vi phạm
mới ở chỗ khác, nên con số dừng quanh 200.

Magic DRC: Magic đọc SRAM và row macro bằng view abstract, trong đó vùng OBS là kim loại đặc. Dây đi sát
mép macro bị báo lỗi khoảng cách kim loại rộng (met4.5b, met2.3b) mà layout thật không có. Kiểm lại từng cờ
trên GDS đầy đủ:

    tools/magic_macro_check.sh ~/OpenLane/designs/gemm_core/runs/core_v9

core_v9: 47 cờ (met4.5b 42, met2.3b 5), cả 47 nằm sát macro, 0 lỗi trên layout đầy đủ, RESULT: PASS. Báo
cáo: reports/signoff/magic_macro_check.rpt. Lệnh cần vài GB RAM, không chạy cạnh detailed route.

Timing nhiều corner (setup ở ss/100°C/1,60V, hold ở ff/-40°C/1,95V, RC min và RC max):

    python3 tools/sta_corners.py ~/OpenLane/designs/gemm_core/runs/core_v9

core_v9: setup -7,46 ns (RC max) và -6,29 ns (RC min) ở corner chậm, tức khoảng 57 MHz; hold sạch với RC min,
-0,12 ns một path với RC max.

Công suất ở tt/25°C/1,80V, 100 MHz:

    tools/power.sh ~/OpenLane/designs/gemm_core/runs/core_v9                  # activity mặc định của OpenSTA
    tools/power.sh ~/OpenLane/designs/gemm_core/runs/core_v9 --vcd 2300 3200  # activity từ mô phỏng

core_v9: 2,89 W với activity mặc định; 1,53 W với activity từ VCD (mô phỏng gate-level kích thước 64x64x64,
chu kỳ 2300-3200 là pha tính của job thứ hai). Trong 1,53 W: SRAM 0,45 W (80 macro), row 0,78 W, phần còn lại
của core 0,30 W. Thư viện OpenRAM cho cùng năng lượng mỗi cạnh clock dù SRAM có được chọn hay không, nên phần
SRAM là cận trên. Mô phỏng không có trễ cổng nên không tính glitch. Đỉnh 204,8 GOPS (2 x 32 x 32 x 100 MHz),
tức 134 GOPS/W và 2,83 GOPS/mm². Bản --vcd mất khoảng 15-20 phút (cửa sổ 900 chu kỳ), cần khoảng 8 GB RAM và 0,7 GB ổ.

Mô phỏng gate-level: `core-gls` in PASS và số sự kiện trùng chu kỳ cho từng kích thước (core_v9: 258, 274 và
34 sự kiện, row bằng RTL). Log ở openlane/logs/core_gls_<thời điểm>/. Với `ROW=gl`, core_v9 sai cột 23 vì row
macro row_v1 bị resizer đổi chân một cell (NHATKY.md). Flow hiện tại đã chặn lỗi này ở tầng row; cần chạy lại
row và core để có layout đúng.

## 6. Xem GDS bằng KLayout

Máy có KLayout:

    klayout -nn ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyt \
            -l ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyp \
            ~/OpenLane/designs/gemm_core/runs/core_v9/results/final/gds/GemmAccelerator.gds

Máy không cài được thì dùng KLayout 0.28.2 trong image OpenLane (cần X11; máy build dùng cách này):

    xhost +local:
    docker run --rm -it -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix -v $HOME:$HOME \
        --user $(id -u):$(id -g) \
        ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64 \
        klayout -nn ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyt \
                -l ~/.ciel/sky130A/libs.tech/klayout/tech/sky130A.lyp \
                ~/OpenLane/designs/gemm_core/runs/core_v9/results/final/gds/GemmAccelerator.gds

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

    FROM=core_v9 openlane/run_flow.sh core-route

Net xuyên macro: sau global route, macro_cross.py tìm net mà global route vạch xuyên lòng macro hơn 50 um
(SRAM chặn met1-met4 và met5 trên SRAM bị cấm, nên detailed route chắc chắn tạo short ở đó). Có net như vậy
thì run dừng ngay, báo cáo ở runs/<tag>/reports/routing/macro_cross.rpt. Cách xử lý là đổi floorplan hoặc
giảm nghẽn, không phải đổi seed.

Detailed route còn lỗi với mọi seed: lỗi ở cùng một chỗ qua nhiều seed là lỗi hình học. Xem vùng quanh lỗi:

    python3 tools/def_window.py <def> <run>/tmp/merged.nom.lef <x> <y> 12 <net...>
