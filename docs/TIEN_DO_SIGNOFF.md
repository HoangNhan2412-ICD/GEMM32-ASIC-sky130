# Tiến độ signoff IP gemm_ip

**Đang làm, chưa signoff xong.** Tài liệu này ghi lại tình trạng giữa chừng để tiện theo dõi. Con số có thể còn thay đổi vì layout vẫn đang được sửa.

## Mục tiêu và chính sách

IP `gemm_ip` gồm core GEMM 32x32 và vỏ AXI, chạy 50 MHz (chu kỳ 20 ns) ở corner TT. Layout gốc là run `ip_v3r` của OpenLane 1.0.2, với vòng route 1 được giữ lại.

Một layout được coi là signoff khi đạt đủ các điều kiện sau:
- **Antenna:** ARC báo 0 chân.
- **DRC:** router 0 lỗi; Magic 0 lỗi thật. Cờ Magic cạnh macro được kiểm lại trên GDS đầy đủ bằng `magic_macro_check.sh`.
- **LVS:** khớp hoàn toàn.
- **Mô phỏng gate-level:** PASS ở cả 3 kích thước ma trận.
- **Timing**, tính bằng lib của mọi macro, propagated clock và SPEF signoff:
  - TT: setup và hold ≥ 0 cho mọi path nội bộ;
  - FF (RC min và max): hold ≥ 0 cho mọi path nội bộ, kể cả path chạm macro;
  - SS: hold ≥ 0 cho path nội bộ. Setup ở SS chỉ báo kèm, để biết fmax;
  - path I/O: báo riêng ở mọi corner, không dùng để đánh trượt IP.
- **DRV:** không net nào vượt giới hạn của lib (mức của SDC chặt hơn và chỉ được báo số lượng).

## Vì sao phải ECO bằng OpenROAD mới

OpenLane 1.0.2 không có detailed route tăng dần. `repair_antennas` của nó chỉ chạy trên kết quả global route, nên mỗi vòng ECO antenna phải route lại cả chip. Mỗi lần route lại như vậy lại sinh vi phạm mới. Ở `ip_v3r`:

| Vòng ECO | Antenna (chân) | Ghi chú |
|---|---|---|
| 0 | 1136 | |
| 1 | 446 | vòng được giữ |
| 2 | 293 | 266 chân là chân mới, không có ở vòng 1; thêm 1 lỗi DRT Metal Spacing cạnh một SRAM |

Vì vậy, ECO được làm bằng OpenROAD trong image LibreLane 3.0.16 (OpenROAD `dcf36133`). Bản này giữ nguyên các net còn dây và chỉ route những net bị sửa. Sau đó DEF được đưa về OpenLane 1.0.2 để kiểm lại bằng đúng công cụ và PDK cũ. Luồng làm và các script nằm ở `tools/eco/README.md`.

Để chạy được trên DEF, cần dựng lại route guide cho mọi net nhiều chân từ chính dây trong DEF, vì DEF không mang guide. Bước kiểm khớp đạt các điểm sau:
- đọc DEF rồi ghi lại cho ra file giống hệt từng byte;
- `check_antennas` của bản mới cho 450 chân, so với 446 chân của ARC trong OL1, trùng nhau 444 chân;
- ECO rỗng (không sửa gì) chỉ làm DRT mới tự sửa 3 chỗ Metal Spacing mà DRT của OL1 không báo, và Magic đã kiểm 3 chỗ đó sạch.

## ip_v3r so với hiện tại

Các mốc của layout hiện tại:
- **Layout mới nhất** có antenna 0 và DRT 0.
- **Timing và DRV** đo trên layout ngay sau ECO hold, trước 2 vòng antenna cuối. Hai vòng đó chèn thêm 253 diode và route lại 236 net.
- **LVS** lần gần nhất chạy trên layout sau ECO antenna đợt đầu, trước các bước đổi cỡ, chèn buffer và sửa hold. **Chưa chạy lại LVS trên layout mới nhất.**

| Mục | ip_v3r | Hiện tại |
|---|---|---|
| Antenna (ARC, OL1) | 446 chân | 0 |
| DRT | 0 | 0 |
| Magic DRC | 0 lỗi thật | 0 (layout mới nhất) |
| LVS | khớp | khớp ở layout sau ECO antenna đợt đầu; chưa chạy lại trên layout mới nhất |
| Setup TT nội bộ, tệ nhất (RC max) | +1,025 ns | +1,511 ns |
| Hold TT nội bộ, tệ nhất | +0,312 ns | +0,323 ns |
| Hold FF nội bộ (RC min / max) | +0,159 / **−0,056** ns | +0,177 / +0,078 ns |
| Hold SS nội bộ, tệ nhất | +0,194 ns | +0,224 ns |
| Setup SS cell→cell (RC max) | +0,484 ns | +1,203 ns |
| Setup SS chạm macro (RC max), chỉ báo | −5,416 ns, 1321 endpoint | −4,769 ns, 1308 endpoint |
| Hold I/O, chỉ báo | FF RC min −0,070 ns (1); SS 551–607 endpoint âm | FF RC min −0,077 ns (1); SS 547–607 endpoint âm |
| DRV cell chuẩn, TT nom | 435 net | 32 net |
| DRV cell chuẩn, SS RC max | 1673 net | 91 net |
| SRAM dout vượt tải (TT nom / SS max) | 539 / 627 net | 0 / 0 (FF RC max: 1) |
| SRAM addr/wmask slew (miễn trừ) | 1440 net | 1440 net |
| Net bị route lại so với ip_v3r | – | 5805 (3,97 %) |
| Cell thêm | – | 1094 diode, 1528 buffer, 1 dlygate; 782 cell đổi cỡ |

Hold âm duy nhất của ip_v3r nằm ở chân `csb1` của SRAM `weight_mem g_bank[0].g_lane[3]`, trên path từ `_56646_/Q`. Path này đã được sửa bằng một `dlygate4sd3_1` nối tiếp một `buf_4` sát chân, nên dlygate không lái thẳng chân SRAM. Hold ở FF RC max của path đi từ −0,052 lên +0,432 ns; setup ở SS của nó vẫn dư khoảng 14 ns.

## Việc còn lại

- **85 net dài vẫn vượt slew hoặc tải.** Một buffer ở driver không đủ cho các net này: 59 net driver đã là `buf_12` (cỡ lớn nhất được dùng, vì `buf_16` thuộc DONT_USE), 9 net do `clkbuf` lái (không phải net clock), và 17 net do row macro lái. Cần chia mỗi net thành nhiều đoạn có buffer.
- **6 net clock vượt slew:** `clknet_9_256/257/258/265/266/81_0_S_AXI_ACLK`. Chưa sửa; đang phân tích trước khi chọn cách.
- **Bộ kiểm cuối trên layout cuối:** LVS, `magic_macro_check.sh` và `spot_check.sh`, STA và DRV theo loại path, mô phỏng gate-level 3 kích thước, công suất ở 50 MHz. Phần này chạy một lần sau khi sửa xong các net dài và net clock.

## Giới hạn cần biết

- **50 MHz chỉ đúng ở corner TT theo lib.** SRAM OpenRAM chỉ có lib TT, nên mọi corner đều dùng lib TT cho SRAM. Corner FF và SS chỉ đổi lib của cell chuẩn.
- **Thực tế đo trên silicon:** SRAM OpenRAM mới được đo chạy được khoảng 34–40 MHz. Con số 50 MHz là theo lib, chưa phải con số đã kiểm trên chip.
- **Không dùng để đánh trượt:** setup ở SS của các path chạm macro, và hold của path I/O, chỉ được báo kèm.
- **Miễn trừ slew ở chân addr/wmask của SRAM:** lib của SRAM chỉ được đặc tính tới slew 40 ps. Mọi chân addr/wmask đều vượt mức này, kể cả chân chỉ nối dây dài 13 µm, nên đây là giới hạn của lib chứ không phải lỗi thiết kế.
- **Phần timing trong README chưa sửa:** README vẫn ghi `core_v11` chạy 100 MHz ở TT. Con số đó chưa kiểm các path đi qua macro; khi kiểm đủ, fmax ở TT chỉ khoảng 53 MHz. README sẽ được sửa khi signoff IP xong.
