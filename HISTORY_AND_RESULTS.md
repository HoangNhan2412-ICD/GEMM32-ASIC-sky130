# Lịch sử các phương án trước `macrospaced_v2`

| Run | Thay đổi chính | Kết quả đã ghi nhận |
|---|---|---|
| `area5000x6000_density45_fast` | Die 5000 × 6000 µm, density 0.45, macro tự động | `GRT-0119`; CTS có 103,416 sinks và 14,122 clock buffers |
| `area7000x5500_density40_iobalanced_v1` | Tăng die lên 7000 × 5500 µm, density 0.40, cân bằng IO | 6,173 congestion markers; overflow 33,063 |
| `area7000x5500_density38_iobalanced_v2` | Giảm density xuống 0.38 | 6,615 markers; không cải thiện theo chỉ số marker |
| `area7000x5500_density40_macrospaced_v2` | Density trở lại 0.40; đặt thủ công 16 SRAM thành 8 macro trái và 8 macro phải | 5,557 markers; overflow 34,313; vẫn dừng `GRT-0119` |

`macrospaced_v2` được xem là mốc tốt nhất theo số congestion marker trong nhóm run đã so sánh. Overflow của nó không thấp nhất, nên không được mô tả là đã giải quyết routing.

## Bố trí SRAM của `macrospaced_v2`

- Cột trái: `x = 400 µm`.
- Cột phải: `x = 5700 µm`.
- Mỗi cột có các tọa độ `y = 350, 950, 1550, 2150, 2750, 3350, 3950, 4550 µm`.
- Orientation: `N`.
- Kích thước mỗi macro theo LEF: `683.1 × 416.54 µm`.
- Khoảng cách đứng giữa hai macro liên tiếp: khoảng `183.46 µm` trước khi tính halo.
- Halo yêu cầu: `20 µm`.

## Phân nhóm 16 macro

| Nhóm | Số macro |
|---|---:|
| Input feature | 2 |
| Input weight | 2 |
| Feeder feature | 2 |
| Feeder weight | 2 |
| Output buffer | 8 |
| Tổng | 16 |

## Trạng thái hoàn thành

| Stage | Trạng thái đã ghi nhận |
|---|---|
| Lint/Synthesis | Hoàn thành |
| Floorplan/Macro placement | Hoàn thành |
| Placement | Hoàn thành |
| CTS | Hoàn thành |
| Routing resizer/global routing | Dừng vì `GRT-0119` |
| Detailed routing/signoff | Chưa hoàn thành |
| Final GDS | Chưa có |

Các số trên là mốc lịch sử để đối chiếu. Kết quả chạy lại chỉ nên được so sánh sau khi image, PDK, RTL, config và SRAM views có checksum khớp với snapshot trong `evidence/`.

