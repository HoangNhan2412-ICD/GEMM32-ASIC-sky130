# Chuẩn bị commit và push

## 1. Đặt bundle vào repository

```bash
project="$HOME/Downloads/GEMM_final_DSP_OPENLANE_ASIC"
cd "$project"
```

Thư mục `OPENLANE_REPRODUCE_MACROSPACED_V2` phải nằm ngay trong `$project`.

## 2. Sinh evidence nhỏ

```bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/02_capture_for_push.sh "$PWD"
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/05_extract_shell_history.sh
```

Mở và kiểm tra file history trước khi commit:

```bash
sed -n '1,240p' OPENLANE_REPRODUCE_MACROSPACED_V2/evidence/historical_commands_from_shell.txt
```

## 3. Không đưa run 8–10 GiB lên GitHub

Nếu `.gitignore` chưa loại `runs/`, thêm các dòng trong `gitignore_openlane.txt` vào `.gitignore` của repository. Không dùng lệnh xóa run; chỉ để Git bỏ qua output sinh tự động.

## 4. Kiểm tra nội dung sẽ commit

```bash
git status --short
git diff -- . ':!designs/GemmAccelerator/runs'
```

Danh sách tối thiểu cần commit:

```text
designs/GemmAccelerator/src/
designs/GemmAccelerator/macros/
designs/GemmAccelerator/config.tcl
designs/GemmAccelerator/pin_order.cfg
designs/GemmAccelerator/config_macro_spaced_v2.tcl
designs/GemmAccelerator/macro_placement_spaced_v2.cfg
OPENLANE_REPRODUCE_MACROSPACED_V2/
```

## 5. Commit và push

```bash
git add \
  designs/GemmAccelerator/src \
  designs/GemmAccelerator/macros \
  designs/GemmAccelerator/config.tcl \
  designs/GemmAccelerator/pin_order.cfg \
  designs/GemmAccelerator/config_macro_spaced_v2.tcl \
  designs/GemmAccelerator/macro_placement_spaced_v2.cfg \
  OPENLANE_REPRODUCE_MACROSPACED_V2 \
  .gitignore

git diff --cached --stat
git diff --cached --check
git commit -m "Add reproducible OpenLane macrospaced_v2 flow"
git push origin "$(git branch --show-current)"
```

Nếu repository chưa có remote hoặc chưa biết branch đích, kiểm tra trước:

```bash
git remote -v
git branch --show-current
```

