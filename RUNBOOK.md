# Quy trình tái lập

## 1. Clone repository

```bash
git clone <URL_REPOSITORY>
cd GEMM_final_DSP_OPENLANE_ASIC
```

Không đổi tên các instance SRAM trong RTL. File macro-placement dùng đúng hierarchical instance name đã tạo trong netlist.

## 2. Cài công cụ host

Trên AlmaLinux/RHEL-compatible:

```bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/00_install_host_tools.sh
```

Script cài Podman, Git, Python 3, pip, ripgrep và các tiện ích cơ bản; sau đó tải image OpenLane đã ghim.

## 3. Cài PDK đúng snapshot

```bash
python3 -m pip install --user --upgrade --no-cache-dir volare
export PATH="$HOME/.local/bin:$PATH"
volare enable --pdk sky130 0fe599b2afb6708d281543108caf8310912f54af
```

## 4. Kiểm tra đầu vào

```bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/01_preflight.sh "$PWD"
```

Preflight xác nhận:

- đúng cấu trúc dự án;
- đủ RTL và SRAM views;
- `DIE_AREA`, `CORE_AREA`, density, clock và PDK đúng;
- LEF có macro đúng tên và kích thước;
- không có container khác đang chạy;
- còn ít nhất 20 GiB.

## 5. Tạo config và macro-placement

```bash
python3 OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/03_reproduce_macrospaced_v2.py \
  --project "$PWD" \
  --prepare
```

Lệnh tạo hai file dưới `designs/GemmAccelerator/`:

```text
config_macro_spaced_v2.tcl
macro_placement_spaced_v2.cfg
```

`config.tcl` gốc không bị sửa.

## 6. Chạy OpenLane

```bash
python3 OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/03_reproduce_macrospaced_v2.py \
  --project "$PWD" \
  --run
```

Lệnh thực tế bên trong script là:

```bash
podman run --rm \
  --name gemm_macrospaced_v2_reproduce \
  --memory=14g \
  --userns=keep-id \
  --security-opt label=disable \
  -v "$PWD:/workspace:Z" \
  -v "$HOME/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af:/pdk:ro" \
  -e PDK_ROOT=/pdk \
  -w /workspace \
  docker.io/efabless/openlane:2023.12.26 \
  bash -lc 'flow.tcl -design /workspace/designs/GemmAccelerator -config_file /workspace/designs/GemmAccelerator/config_macro_spaced_v2.tcl -tag area7000x5500_density40_macrospaced_v2'
```

## 7. Kiểm tra kết quả

```bash
python3 OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/04_verify_run.py \
  --project "$PWD"
```

Kết quả kiểm tra cần cho biết:

- tag đúng;
- config run đúng;
- DEF chứa đúng 16 SRAM macro;
- tọa độ macro đúng với template;
- trạng thái các stage;
- có hoặc không có `GRT-0119`;
- số congestion marker và tổng overflow nếu report tồn tại;
- có hoặc không có GDS cuối.

## 8. Chạy toàn bộ bằng một lệnh

```bash
bash OPENLANE_REPRODUCE_MACROSPACED_V2/scripts/run_all.sh "$PWD"
```

Script vẫn chạy bước verify nếu OpenLane trả exit code khác 0, vì mốc lịch sử hiện tại dừng ở congestion.

