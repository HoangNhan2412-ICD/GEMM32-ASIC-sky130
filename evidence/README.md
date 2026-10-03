# Evidence sinh trên máy tác giả

Chạy:

```bash
bash ../scripts/02_capture_for_push.sh /duong/dan/toi/GEMM_final_DSP_OPENLANE_ASIC
```

Script sẽ tạo các file nhỏ:

- `environment.txt`: OS, CPU, RAM, công cụ, container image và PDK.
- `input_sha256.txt`: checksum RTL, config và SRAM views.
- `run_config_snapshot.tcl`: config đóng băng trong run hiện có.
- `macro_placement_snapshot.cfg`: macro placement thực tế.
- `run_status.txt`: stage đạt được, lỗi và số congestion marker.
- `historical_commands_from_shell.txt`: chỉ sinh khi chạy script trích history riêng.

Kiểm tra nội dung trước khi commit. Không đưa token, mật khẩu, registry login hoặc thông tin riêng tư vào repository.

