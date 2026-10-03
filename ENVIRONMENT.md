# Môi trường build đã sử dụng

| Thành phần | Giá trị |
|---|---|
| Hệ điều hành | AlmaLinux 10.2, x86_64 |
| CPU máy tác giả | Intel Core i7-14700HX, 28 logical CPUs |
| RAM | Khoảng 15 GiB; container giới hạn 14 GiB |
| Container engine | Podman, rootless, `--userns=keep-id` |
| OpenLane | OpenLane v1; image `docker.io/efabless/openlane:2023.12.26` |
| PDK | `sky130A` |
| PDK snapshot | `0fe599b2afb6708d281543108caf8310912f54af` |
| Standard-cell library | `sky130_fd_sc_hd` |
| Clock | `i_clk`, period 10 ns (mục tiêu 100 MHz) |
| Die | `0 0 7000 5500` µm = 7.0 × 5.5 mm |
| Core | `200 200 6800 5300` µm = 6.6 × 5.1 mm |
| Placement density | `0.40` |
| SRAM macro | `sky130_sram_2kbyte_1rw1r_128x128_128` |
| Số macro trong netlist/floorplan | 16 |
| Kích thước macro đọc từ LEF | 683.1 × 416.54 µm |
| Macro halo | 20 µm |
| Tag run | `area7000x5500_density40_macrospaced_v2` |

## Tại sao phải ghim phiên bản

OpenLane, OpenROAD, Yosys, Magic và các file công nghệ thay đổi theo phiên bản. Cùng một RTL nhưng dùng image hoặc PDK khác có thể tạo netlist, timing và routing khác. Do đó run này cố định:

```text
OpenLane image: docker.io/efabless/openlane:2023.12.26
PDK snapshot:   0fe599b2afb6708d281543108caf8310912f54af
```

Script `02_capture_for_push.sh` lưu thêm digest của image thực tế, phiên bản Podman, kernel, checksum RTL/config/macro views vào `evidence/`.

## Dung lượng và tài nguyên

- Cần tối thiểu 20 GiB trống trước khi chạy.
- Một run đầy đủ có thể chiếm khoảng 8–10 GiB.
- Script giới hạn container ở 14 GiB RAM vì máy tác giả có khoảng 15 GiB RAM.
- Không chạy đồng thời container OpenLane khác.

## Cài PDK đúng snapshot

Nếu chưa có Volare:

```bash
python3 -m pip install --user --upgrade --no-cache-dir volare
```

Cài và enable đúng snapshot:

```bash
volare enable --pdk sky130 0fe599b2afb6708d281543108caf8310912f54af
```

Sau khi cài, đường dẫn mà script mong đợi là:

```text
$HOME/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A
```

## Trạng thái kỹ thuật cần hiểu đúng

Run hiện tại chưa hoàn thành detailed routing và signoff. Lỗi dừng đã quan sát là:

```text
[ERROR GRT-0119] Routing congestion too high
```

Kết quả tái lập đúng có thể kết thúc bằng lỗi này. Exit code khác 0 không có nghĩa script tái lập sai nếu log, config, 16 macro và điểm dừng khớp với `HISTORY_AND_RESULTS.md`.

