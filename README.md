# GEMM 32×32 ASIC — OpenLane Reproducibility Package

Tài liệu này mô tả cách tái lập bản physical design:

~~~text
area7000x5500_density40_macrospaced_v2
~~~

Đây là bản triển khai ASIC của bộ gia tốc nhân ma trận GEMM INT8, sử dụng systolic array 32×32 trên PDK SKY130A. Mục tiêu của bản này là giảm nghẽn dây bằng cách tăng diện tích chip và bố trí thủ công 16 SRAM macro thành hai cột ở hai mép vùng core.

> **Trạng thái hiện tại:** synthesis, floorplan, placement và CTS đã hoàn thành. Flow dừng tại routing-resizer với lỗi **GRT-0119** do routing congestion. Đây là bản tốt nhất trong các run đã so sánh theo số congestion marker, nhưng **chưa phải thiết kế signoff và chưa có GDS hoàn chỉnh**.

## 1. Tổng quan hệ thống

Thiết kế thực hiện phép nhân ma trận bằng mảng systolic 32×32 gồm 1.024 Processing Element (PE), theo cơ chế weight-stationary.

~~~mermaid
flowchart TD
    A["Feature SRAM"] --> C["Input / Feeder buffers"]
    B["Weight SRAM"] --> C
    C --> D["Systolic array 32×32<br/>1.024 PE"]
    D --> E["Output buffers"]
    E --> F["Output SRAM"]
~~~

| Thành phần | Vai trò |
|---|---|
| RTL GEMM | Điều khiển luồng dữ liệu và phép nhân–tích lũy |
| Systolic array 32×32 | Thực hiện song song 1.024 phép MAC theo nhịp |
| PE | Nhân hai toán hạng INT8 và cộng vào giá trị tích lũy |
| Input/feeder buffer | Đưa feature và weight vào mảng theo đúng chu kỳ |
| Output buffer | Thu và sắp xếp kết quả từ mảng |
| SRAM macro | Lưu feature, weight và output dưới dạng hard macro ASIC |

Thiết kế gốc hướng đến FPGA và có thể dùng DSP IP. Khi chuyển sang ASIC, DSP48 không còn tồn tại trong PDK SKY130. Phép nhân trong PE được mô tả bằng RTL signed arithmetic và được tổng hợp thành các standard cell của thư viện **sky130_fd_sc_hd**.

## 2. Mục tiêu của run macrospaced_v2

Các run trước gặp nghẽn routing nghiêm trọng quanh cụm SRAM và vùng trung tâm. Bản **macrospaced_v2** giữ die 7.000 × 5.500 µm, đặt 16 SRAM thành hai cột để:

- giải phóng vùng giữa cho 1.024 PE và logic điều khiển;
- tạo khoảng trống giữa các macro cho nguồn và đường tín hiệu;
- tách nhóm SRAM đầu vào khỏi nhóm SRAM đầu ra;
- giảm số congestion marker so với các phương án đã thử.

~~~mermaid
flowchart LR
    L["Cột trái<br/>8 SRAM input + feeder"] --- C["Vùng trung tâm<br/>standard cells + systolic array"]
    C --- R["Cột phải<br/>8 SRAM output"]
~~~

### Phân nhóm 16 SRAM

| Vị trí | Số macro | Chức năng |
|---|---:|---|
| Cột trái | 2 | Input feature buffer |
| Cột trái | 2 | Input weight buffer |
| Cột trái | 2 | Feature feeder buffer |
| Cột trái | 2 | Weight feeder buffer |
| Cột phải | 8 | Output buffer |
| **Tổng** | **16** | Tất cả dùng cùng một hard macro SRAM vật lý |

Tất cả instance sử dụng macro:

~~~text
sky130_sram_2kbyte_1rw1r_128x128_128
~~~

Macro có tổ chức vật lý 128 word × 128 bit, tương đương 16.384 bit = 2 KiB, với một cổng read/write và một cổng read. Các wrapper RTL như **Sram64x256**, **Sram128x256** hoặc **Sram128x1024** biểu diễn giao diện logic mà thiết kế cần; wrapper ghép nhiều macro vật lý và ánh xạ độ rộng/độ sâu phù hợp.

| Wrapper logic | Dung lượng logic | Số macro vật lý | Cách ghép chính |
|---|---:|---:|---|
| **Sram64x256** | 64 × 256 bit = 2 KiB | 2 | Hai macro song song để tạo bus 256 bit; chỉ dùng 64 địa chỉ cần thiết |
| **Sram128x256** | 128 × 256 bit = 4 KiB | 2 | Hai macro song song, mỗi macro cung cấp 128 bit |
| **Sram128x1024** | 128 × 1024 bit = 16 KiB | 8 | Tám macro song song, tổng độ rộng 1.024 bit |

Vì hard macro chỉ xuất 128 bit mỗi lần đọc, buffer logic rộng 256 bit vẫn cần hai macro chạy song song, dù tổng dung lượng của **Sram64x256** cũng chỉ là 2 KiB.

### Tọa độ bố trí

| Cột | Tọa độ X | Các tọa độ Y | Hướng |
|---|---:|---|---|
| Trái | 400 µm | 350, 950, 1550, 2150, 2750, 3350, 3950, 4550 µm | N |
| Phải | 5700 µm | 350, 950, 1550, 2150, 2750, 3350, 3950, 4550 µm | N |

Kích thước một macro theo LEF là khoảng 683,10 × 416,54 µm. Halo được đặt 20 µm quanh mỗi macro.

## 3. Công nghệ và cấu hình physical design

| Thông số | Giá trị | Ý nghĩa |
|---|---|---|
| PDK | **sky130A** | Bộ quy tắc và thư viện công nghệ 130 nm |
| PDK snapshot | **0fe599b2afb6708d281543108caf8310912f54af** | Phiên bản PDK dùng để tái lập |
| Standard-cell library | **sky130_fd_sc_hd** | Thư viện cell mật độ cao |
| OpenLane image | **docker.io/efabless/openlane:2023.12.26** | Phiên bản môi trường chạy cố định |
| Top module | **GemmAccelerator** | Module cao nhất của thiết kế |
| Clock port | **i_clk** | Ngõ vào clock |
| Clock period | 10 ns | Mục tiêu 100 MHz, chưa phải kết quả signoff |
| Die area | **0 0 7000 5500 µm** | Kích thước die 7,0 × 5,5 mm, diện tích 38,5 mm² |
| Core area | **200 200 6800 5300 µm** | Vùng đặt standard cell, kích thước 6,6 × 5,1 mm |
| Placement density | **0.40** | Mục tiêu dùng 40% diện tích hàng standard cell |
| SRAM | **sky130_sram_2kbyte_1rw1r_128x128_128** | Hard macro 2 KiB |
| Số SRAM macro | 16 | Tổng số instance vật lý |
| Macro halo | 20 µm | Khoảng đệm quanh macro |

**7000** và **5500** là kích thước die theo micromet. **density40** là mật độ placement mục tiêu 40%; nó không có nghĩa 40% tổng diện tích die đã được silicon sử dụng.

## 4. Luồng OpenLane và trạng thái hiện tại

~~~mermaid
flowchart TD
    A["RTL + SRAM views"] --> B["Lint và synthesis"]
    B --> C["Floorplan + PDN"]
    C --> D["Macro + standard-cell placement"]
    D --> E["CTS"]
    E --> F["Routing-resizer / global routing"]
    F -->|GRT-0119| G["Dừng: routing congestion"]
    F -.->|Chưa đạt| H["Detailed routing + signoff + GDS"]
~~~

| Giai đoạn | Trạng thái | Kết quả chính |
|---|---|---|
| Lint / synthesis | Hoàn thành | RTL được tổng hợp sang cell SKY130 |
| Floorplan / PDN | Hoàn thành | Die, core, nguồn và vị trí macro được tạo |
| Placement | Hoàn thành | Standard cell được đặt quanh 16 SRAM |
| CTS | Hoàn thành | Cây clock được xây dựng |
| Routing-resizer / global routing | Không đạt | **GRT-0119**, tài nguyên routing không đủ |
| Detailed routing | Chưa chạy hoàn chỉnh | Phụ thuộc việc giải quyết congestion |
| STA, DRC, LVS signoff | Chưa đạt | Chưa đủ điều kiện kết luận tape-out |
| Final GDS | Chưa có | Run hiện tại chưa phải sản phẩm cuối |

### So sánh các run đã xác nhận

| Run | Kết quả liên quan congestion |
|---|---:|
| **area5000x6000_density45_fast** | CTS có 103.416 sink và 14.122 clock buffer; dừng GRT-0119 |
| **area7000x5500_density40_iobalanced_v1** | 6.173 marker; overflow 33.063 |
| **area7000x5500_density38_iobalanced_v2** | 6.615 marker |
| **area7000x5500_density40_macrospaced_v2** | **5.557 marker**; overflow 34.313 |

**macrospaced_v2** tốt nhất theo số marker trong nhóm trên, nhưng không có overflow thấp nhất. Vì vậy kết luận đúng là **bố trí macro đã cải thiện congestion nhưng chưa giải quyết hoàn toàn lỗi routing**.

## 5. Cấu trúc gói tái lập

~~~text
OPENLANE_REPRODUCE_MACROSPACED_V2/
├── README.md
├── ENVIRONMENT.md
├── HISTORY_AND_RESULTS.md
├── RUNBOOK.md
├── COMMANDS_COPY_PASTE.sh
├── MANIFEST.sha256
├── archive/
│   └── gemm_macro_spaced_v2_original.py
├── evidence/
│   └── README.md
├── git/
│   ├── GIT_PUSH_GUIDE.md
│   └── gitignore_openlane.txt
├── scripts/
│   ├── 00_install_host_tools.sh
│   ├── 01_preflight.sh
│   ├── 02_capture_for_push.sh
│   ├── 03_reproduce_macrospaced_v2.py
│   ├── 04_verify_run.py
│   ├── 05_extract_shell_history.sh
│   └── run_all.sh
└── templates/
    ├── config_additions.tcl
    └── macro_placement_spaced_v2.cfg
~~~

| File / thư mục | Nội dung |
|---|---|
| **README.md** | Tổng quan thiết kế, trạng thái và cách bắt đầu |
| **ENVIRONMENT.md** | Hệ điều hành, Podman, OpenLane image, PDK và công cụ |
| **HISTORY_AND_RESULTS.md** | Diễn biến các run, thay đổi và số liệu đã xác nhận |
| **RUNBOOK.md** | Quy trình build lại theo từng bước |
| **COMMANDS_COPY_PASTE.sh** | Các lệnh chính để sao chép và chạy nhanh |
| **MANIFEST.sha256** | Checksum kiểm tra toàn vẹn toàn bộ gói |
| **archive/** | Script lịch sử đã dùng trên máy tác giả |
| **evidence/** | Nơi lưu báo cáo nhỏ và bằng chứng sau khi thu thập |
| **git/** | Hướng dẫn push và mẫu .gitignore |
| **scripts/** | Script cài đặt, kiểm tra, tái lập và xác minh |
| **templates/** | Phần cấu hình và tọa độ macro cố định |

## 6. Dữ liệu bắt buộc trong repository chính

Gói này không thay thế source code của dự án. Trước khi chạy, repository phải có tối thiểu:

~~~text
GEMM_final_DSP_OPENLANE_ASIC/
├── designs/
│   └── GemmAccelerator/
│       ├── config.tcl
│       ├── pin_order.cfg
│       ├── src/
│       │   ├── GemmAccelerator.v
│       │   ├── ... PE, array, buffer, feeder, control ...
│       │   └── ... SRAM wrappers ...
│       └── ... macro views referenced by config ...
└── OPENLANE_REPRODUCE_MACROSPACED_V2/
~~~

Các đầu vào bắt buộc gồm:

- toàn bộ RTL được **config.tcl** tham chiếu;
- **config.tcl** và **pin_order.cfg**;
- wrapper SRAM, gồm các module như **Sram128x256.v**, **Sram64x256.v** và **Sram128x1024.v**;
- model Verilog cùng các view LEF, Liberty và GDS của SRAM macro;
- gói tái lập này.

## 7. Chạy lại nhanh

Đặt thư mục này ở thư mục gốc dự án:

~~~text
GEMM_final_DSP_OPENLANE_ASIC/
├── designs/
├── rtl/
└── OPENLANE_REPRODUCE_MACROSPACED_V2/
~~~

### Bước 1 — vào thư mục dự án

~~~bash
cd /duong/dan/toi/GEMM_final_DSP_OPENLANE_ASIC
~~~

### Bước 2 — cài công cụ host

~~~bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/00_install_host_tools.sh
~~~

Script cài hoặc kiểm tra các công cụ cần trên máy host, gồm Podman và các tiện ích shell.

### Bước 3 — kiểm tra đầu vào

~~~bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/01_preflight.sh "$PWD"
~~~

Preflight kiểm tra cấu trúc dự án, RTL, macro views, container image, PDK và dung lượng trước khi chạy.

### Bước 4 — tái lập run

~~~bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/run_all.sh "$PWD"
~~~

**run_all.sh** gọi preflight, chuẩn bị cấu hình cố định và chạy OpenLane. Script không ghi đè run đã tồn tại. Nếu tag **area7000x5500_density40_macrospaced_v2** đã có, script sẽ dừng để bảo vệ dữ liệu.

Chi tiết từng lệnh và cách chạy thủ công nằm trong [RUNBOOK.md](RUNBOOK.md).

## 8. Chuẩn bị dữ liệu trước khi push

Trên máy tác giả, chạy:

~~~bash
cd "$HOME/Downloads/GEMM_final_DSP_OPENLANE_ASIC"

bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/02_capture_for_push.sh "$PWD"
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/05_extract_shell_history.sh
~~~

- **02_capture_for_push.sh** thu cấu hình, checksum và báo cáo nhỏ làm bằng chứng.
- **05_extract_shell_history.sh** lọc các lệnh OpenLane thực tế từ Bash/Zsh.
- Cần đọc lại file history trước khi commit để bảo đảm không có token, mật khẩu hoặc thông tin riêng tư.

Không nên push **designs/GemmAccelerator/runs/** vì mỗi run có thể chiếm 8–10 GiB. Chỉ commit source, config, macro views hợp lệ, script tái lập và evidence nhỏ cần thiết.

## 9. Kiểm tra tính toàn vẹn và kết quả

### Kiểm tra gói

~~~bash
cd OPENLANE_REPRODUCE_MACROSPACED_V2
sha256sum -c MANIFEST.sha256
~~~

### Kiểm tra run

~~~bash
python3 scripts/04_verify_run.py \
  ../designs/GemmAccelerator/runs/area7000x5500_density40_macrospaced_v2
~~~

Script xác minh tag run, vị trí macro, các artifact quan trọng và lỗi **GRT-0119** đã biết.

## 10. Ghi chú về khả năng tái lập

- **archive/gemm_macro_spaced_v2_original.py** là script lịch sử đã dùng để tạo run.
- **scripts/03_reproduce_macrospaced_v2.py** là bản dùng cho clone mới: không phụ thuộc vào một baseline run cũ nhưng giữ nguyên image, PDK, cấu hình die/core, mật độ và tọa độ macro.
- Pin assignment, placement và routing vẫn có thể thay đổi nếu dùng phiên bản OpenLane, PDK hoặc macro view khác. Vì vậy image và PDK snapshot đã được cố định.
- Các lệnh thử nghiệm của những run cũ không thể suy ra đầy đủ chỉ từ thư mục **runs**. Tài liệu chỉ ghi số liệu đã xác nhận; shell history thực tế được thu riêng bằng script.
- Mục tiêu 10 ns là constraint đầu vào, không phải bằng chứng thiết kế đã đạt 100 MHz sau signoff.

## 11. Thứ tự đọc đề xuất

| Thứ tự | Tài liệu | Khi nào cần đọc |
|---:|---|---|
| 1 | **README.md** | Hiểu toàn bộ dự án và trạng thái hiện tại |
| 2 | **ENVIRONMENT.md** | Chuẩn bị đúng công cụ, image và PDK |
| 3 | **RUNBOOK.md** | Build lại từng bước |
| 4 | **HISTORY_AND_RESULTS.md** | Hiểu vì sao chọn macrospaced_v2 |
| 5 | **git/GIT_PUSH_GUIDE.md** | Đưa source và bằng chứng lên Git |
| 6 | **COMMANDS_COPY_PASTE.sh** | Tra nhanh các lệnh thường dùng |

Nếu mục tiêu là tiếp tục tối ưu để đạt GDS, hãy bắt đầu từ báo cáo congestion của **macrospaced_v2**, sau đó thử điều chỉnh pin placement, phân vùng logic, macro channels/halos và chiến lược CTS thay vì coi run này là kết quả signoff.
