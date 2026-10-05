# GEMM 32x32 INT8 trên SKY130

Bộ tăng tốc nhân ma trận INT8 32x32 kiểu weight-stationary. Bản gốc chạy trên FPGA KV260;
repo này đưa nó ra layout trên SKY130 bằng OpenLane 1.0.2. Thiết kế được harden theo tầng:
PE, row (32 PE), array, rồi core GemmAccelerator gồm 32 row macro và 80 SRAM OpenRAM.

## Kết quả (core_v9)

| Mục | Kết quả |
|---|---|
| Die | 7,06 x 10,24 mm (72,3 mm²) |
| Tần số | 100 MHz ở tt/25°C/1,80V; khoảng 57 MHz ở ss/100°C/1,60V |
| DRC | router 0; Magic 0 lỗi thật (47 cờ do view abstract của macro, đã kiểm lại trên layout đầy đủ) |
| LVS | khớp |
| Hold | sạch ở typical; một path -0,12 ns ở ff + RC max |
| Antenna | còn 209 net, vượt nhẹ (trung vị 1,4 lần giới hạn) |
| Mô phỏng gate-level | netlist core (row mô phỏng bằng RTL) đúng, trùng từng chu kỳ với RTL FPGA ở 3 kích thước ma trận; với netlist của row thì sai cột 23, xem Hạn chế |
| Công suất | tt/25°C/1,80V, 100 MHz: 1,53 W với activity từ VCD (mô phỏng gate-level, pha tính của ma trận 64x64x64); 2,89 W với activity mặc định của OpenSTA |
| Hiệu suất | đỉnh 204,8 GOPS (2 x 32 x 32 x 100 MHz); 134 GOPS/W (theo 1,53 W); 2,83 GOPS/mm² |

## Chạy

Cần OpenLane 1.0.2 (Docker) ở ~/OpenLane, PDK sky130A, iverilog và python3. Repo gốc
GEMM_32x32_KV260 đặt cạnh thư mục này (dùng testbench của nó). Cài đặt, thời gian, cách đọc
kết quả và lỗi hay gặp: HUONGDAN.md.

    openlane/run_flow.sh sim        # RTL ASIC so với RTL FPGA
    openlane/run_flow.sh pe
    openlane/run_flow.sh row
    openlane/run_flow.sh array
    openlane/run_flow.sh core-sim   # RTL core với model SRAM OpenRAM
    openlane/run_flow.sh core-pre
    openlane/run_flow.sh core       # khoảng 7 giờ, cần 16 GB RAM và 40 GB ổ trống
    openlane/run_flow.sh core-gls   # mô phỏng gate-level netlist cuối

Mỗi tầng chỉ chạy khi tầng trước đã qua. Kết quả ghi vào openlane/LOG.md,
GDS nằm ở ~/OpenLane/designs/gemm_core/runs/<tag>/results/final/gds/.

## Thư mục

    rtl_asic/   RTL cho ASIC
    sim/        so sánh với RTL FPGA, mô phỏng gate-level
    openlane/   run_flow.sh và cấu hình từng tầng
    tools/      đọc log, kiểm tra DRC quanh macro, phân tích antenna, timing và công suất

## Ghi chú thiết kế

- Mỗi SRAM đặt sát phần logic dùng nó. Floorplan đầu gom SRAM thành khối lớn thì global route nghẽn tới mức crash.
- Cấm đi dây met5 trên SRAM: SRAM đã chặn met1-met4, dây đổi track trên met5 tạo short không sửa được.
- Sau global route có bước kiểm tra net đi xuyên lòng macro; có thì dừng sớm thay vì chạy DRT vô ích.
- Tắt diode heuristic (nguồn nghẽn chính); LEF của SRAM được bổ sung dữ liệu antenna để công cụ thấy chân SRAM.
- Magic DRC đọc cell chuẩn bằng layout đầy đủ, macro bằng abstract; cờ quanh macro được kiểm lại bằng tools/magic_macro_check.sh.
- repair_timing chạy với -skip_pin_swap, và tầng row so netlist cuối với RTL (sim/row_equiv.sh): LVS không bắt được lỗi đổi chân.

## Hạn chế

- Row macro mà core_v9 dùng (row_v1) có lỗi chức năng: resizer đổi chỗ hai chân của một cell and2b, PE 23 tính sai
  bit 12-15 của tích, nên layout core_v9 sai cột 23. Flow đã sửa nhưng chưa chạy lại row và core.
- Antenna chưa về 0: router của bản OpenROAD này không tính antenna khi đi dây và không có chế độ ECO.
- Corner chậm chỉ đạt khoảng 57 MHz; muốn 100 MHz ở mọi corner phải chia lại pipeline.
- Timing ở cổng I/O được miễn vì core chưa có vòng pad; đây là core, chưa phải chip hoàn chỉnh.
- Công suất SRAM là cận trên: thư viện OpenRAM cho cùng năng lượng mỗi cạnh clock dù SRAM có được chọn hay không.

Lịch sử các lần chạy: NHATKY.md.
