# Nhật ký các lần chạy

Run nằm ở ~/OpenLane/designs/<design>/runs/<tag>. Thời gian là thời gian OpenLane báo trong metrics.csv.

## PE, row, array

| Run | Thay đổi | Kết quả |
|---|---|---|
| pe_v1 | Một PE, đo diện tích để tính kích thước row | PASS, 6604 um², 2 phút |
| row_v1 | 32 PE, macro 3517,6 x 133,3 um, chặn met1-met4, chân trên/dưới thẳng hàng | PASS, 27 phút. Sau này phát hiện lỗi chức năng do resizer (xem mục cuối) |
| array_v1 | FeatureSkew + 32 row + OutputDeskew | PASS sau 10 lần chạy, 3h14m, 19,9 mm², timing I/O miễn |

## Core (GemmAccelerator: 32 row + 80 SRAM)

| Run | Thay đổi | Kết quả |
|---|---|---|
| core_v1 | Floorplan đầu: SRAM gom thành khối | Global route crash (FastRoute gặp đường vòng quá dài vì nghẽn) |
| core_v1r | Route lại từ sau CTS | Vẫn nghẽn, khoảng 390 nghìn cạnh gcell tràn. Chuỗi FeatureSkew/OutputDeskew phải vắt qua macro |
| (layout v2, v3) | Đặt mỗi SRAM cạnh logic dùng nó; vùng B dưới chồng row | Thử bằng core-probe, không có run riêng |
| core_v4 | Layout v3, SYNTH_BUFFERING 0 (ABC dựng cây buffer không biết vị trí) | Overflow từ 321 nghìn xuống khoảng 6,8 nghìn; 9,5 nghìn short ở DRT do cell kẹt giữa các row |
| core_v5 | Nới dải FeatureSkew 320 lên 1000 um | Không đổi |
| core_v6 | keep_rows_clear.tcl đẩy cell ra khỏi khe giữa row; die 7,06 x 10,24 mm | Overflow 575, DRT còn 1 short met5; LVS chạy 7 giờ vì short |
| core_v6r | Route lại với seed 7, 23, 101 | Cả 3 seed ra cùng short met5 trên SRAM: lỗi hình học, không phải do seed. Setup -1,24 ns ở RightShifter |
| core_v7 | RightShifter viết lại (bỏ bộ cộng 32 bit khỏi đường dữ liệu); cấm met5 trên SRAM; met1 giữ 50 % dung lượng | Dừng giữa DRT để thêm Magic DRC đọc layout đầy đủ của cell chuẩn |
| core_v7r | Route lại từ sau CTS của v7 | Short met5 hết, setup nội bộ sạch, hold -0,01. DRT 23 lỗi: một net phải băng qua SRAM mà không còn lớp nào |
| core_v8 | Tắt diode heuristic | Overflow 46 (v7r: 515), không net nào xuyên macro. Dừng sau global route để thêm dữ liệu antenna cho SRAM |
| core_v9 | LEF SRAM có ANTENNAGATEAREA / ANTENNADIFFAREA; 3 vòng ECO antenna | DRT 0, LVS khớp, setup/hold nội bộ sạch ở typical (+1,01 / +0,11), còn 209 net antenna, Magic 47 cờ giả quanh macro. 7h02m, RAM 13,0 GB |
| core_v10 | Hold margin 0.7, GRT_ANT_MARGIN 50 | Hold sạch mọi corner, nhưng setup typical -0,06 ns, corner chậm tệ thêm 1,4 ns; antenna 219 net. Giữ v9 |

Các kiểm tra thêm vào flow trong quá trình này:

- Thử nhiều seed DRT trong một run, giữ lần ít lỗi nhất; route còn lỗi thì bỏ LVS.
- macro_cross.py sau global route: dừng nếu có net đi xuyên lòng macro hơn 50 um.
- magic_macro_check.sh: cờ Magic quanh macro (do view abstract) được kiểm lại trên GDS đầy đủ.
- need_disk: dừng trước khi chạy nếu ổ còn dưới 40 GB (core_v7r từng chết vì hết ổ).

## Timing nhiều corner của core_v9

| Corner | Path nội bộ |
|---|---|
| tt/25°C/1,80V | setup +1,01 ns, hold +0,11 ns |
| ss/100°C/1,60V, RC max | setup -7,46 ns, chu kỳ tối thiểu khoảng 17,5 ns |
| ss/100°C/1,60V, RC min | setup -6,29 ns |
| ff/-40°C/1,95V, RC min | hold sạch |
| ff/-40°C/1,95V, RC max | hold -0,12 ns, 1 path trong delay line OutputDeskew |

## Lỗi chức năng trong row_v1 (phát hiện 04/10)

GLS của core trước đây mô phỏng row bằng RTL nên không thấy. Khi mô phỏng với netlist gate-level của row,
cột 23 của kết quả sai. So một row RTL với netlist bằng kích thích ngẫu nhiên (sim/row_equiv.sh) thấy chỉ PE 23
sai, ở bit 12-15 của tích.

Chia theo từng bước của row_v1: netlist sau CTS và sau bước 15 đúng, sau bước 17 (resizer timing sau global
route) sai. Log bước đó có "Swapped pins on 1 instances": repair_timing đổi chỗ chân A_N và B của một cell
and2b_1, mà cell này không giao hoán. LVS vẫn khớp vì layout khớp với netlist đã sai.

Cả 32 row của core_v9 và core_v10 là cùng macro này, nên layout hai bản đó tính sai cột 23. Core không có pin
swap nào (bước resizer sau global route của core đã tắt sẵn).

Đã sửa trong flow: run_flow.sh thêm -skip_pin_swap cho repair_timing ở mọi tầng, và tầng row so netlist cuối với
RTL (sim/row_equiv.sh). Cần chạy lại row và core để có layout đúng.
