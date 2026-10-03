#!/usr/bin/env python3
"""Prepare and run a controlled OpenLane 1 macro-placement experiment.

Usage on the user's AlmaLinux machine:
  python3 ~/Downloads/gemm_macro_spaced_v2.py --prepare
  python3 ~/Downloads/gemm_macro_spaced_v2.py --run

--run prepares (or verifies) the files, runs the full flow while checking the
first completed macro DEF, and stops its container if placement is invalid.
"""

import argparse
import itertools
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


DESIGN_REL = Path("designs/GemmAccelerator")
BASE_TAG = "area7000x5500_density38_iobalanced_v2"
NEW_TAG = "area7000x5500_density40_macrospaced_v2"
CFG_NAME = "config_macro_spaced_v2.tcl"
PLACEMENT_NAME = "macro_placement_spaced_v2.cfg"
MACRO = "sky130_sram_2kbyte_1rw1r_128x128_128"
LEF_REL = Path("macros") / MACRO / (MACRO + ".lef")
EXPECTED = {
    "u_input_buffer.u_feature_buffer_sram.u_sram0",
    "u_input_buffer.u_feature_buffer_sram.u_sram1",
    "u_input_buffer.u_weight_buffer_sram.u_sram0",
    "u_input_buffer.u_weight_buffer_sram.u_sram1",
    "u_buffer_feeder.u_feature_feeder_sram.u_sram0",
    "u_buffer_feeder.u_feature_feeder_sram.u_sram1",
    "u_buffer_feeder.u_weight_feeder_sram.u_sram0",
    "u_buffer_feeder.u_weight_feeder_sram.u_sram1",
    *(f"u_output_buffer.u_output_buffer_sram.u_sram{i}" for i in range(8)),
}
LEFT = [
    "u_input_buffer.u_feature_buffer_sram.u_sram0",
    "u_buffer_feeder.u_feature_feeder_sram.u_sram0",
    "u_input_buffer.u_feature_buffer_sram.u_sram1",
    "u_buffer_feeder.u_feature_feeder_sram.u_sram1",
    "u_input_buffer.u_weight_buffer_sram.u_sram0",
    "u_buffer_feeder.u_weight_feeder_sram.u_sram0",
    "u_input_buffer.u_weight_buffer_sram.u_sram1",
    "u_buffer_feeder.u_weight_feeder_sram.u_sram1",
]
RIGHT = [f"u_output_buffer.u_output_buffer_sram.u_sram{i}" for i in range(8)]
POSITIONS = {
    name: (float(x), float(350 + 600 * i), "N")
    for x, group in [(400, LEFT), (5700, RIGHT)]
    for i, name in enumerate(group)
}
CORE = (200., 200., 6800., 5300.)


def stop(message):
    raise SystemExit("DỪNG: " + message)


def read_lef_size(path):
    s = path.read_text()
    m = re.search(r"\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;", s)
    if m is None:
        stop(f"Không đọc được SIZE trong LEF: {path}")
    return float(m[1]), float(m[2])


def def_macros(path):
    """Read named macro components and actual lower-left DEF positions."""
    units = None
    in_components = False
    record = ""
    result = {}
    for raw in path.open(errors="replace"):
        line = raw.strip()
        if line.startswith("UNITS DISTANCE MICRONS "):
            units = int(line.split()[3])
        if line.startswith("COMPONENTS "):
            in_components = True
            continue
        if line == "END COMPONENTS":
            break
        if not in_components:
            continue
        if line.startswith("- "):
            record = line
        elif record:
            record += " " + line
        if record and ";" in record:
            m = re.match(r"-\s+(\S+)\s+(\S+)", record)
            if m and m[2] == MACRO:
                p = re.search(
                    r"\+\s+(FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)",
                    record,
                )
                if p is None or units is None:
                    stop(f"SRAM thiếu vị trí hoặc DEF thiếu UNITS: {path}")
                if m[1] in result:
                    stop("Instance SRAM trùng trong DEF: " + m[1])
                result[m[1]] = (int(p[2]) / units, int(p[3]) / units, p[4])
            record = ""
    return result


def validate(places, size, expected, tolerance=0):
    if set(places) != expected or len(places) != 16:
        stop(f"Tên SRAM không khớp. Thiếu: {sorted(expected-set(places))}; dư: {sorted(set(places)-expected)}")
    w, h = size
    x0, y0, x1, y1 = CORE
    for name, (x, y, orient) in places.items():
        if orient != "N":
            stop(f"Hướng SRAM khác N: {name}: {orient}")
        if min(x-x0, y-y0, x1-(x+w), y1-(y+h)) < 50 - tolerance:
            stop(f"SRAM sát/ngoài CORE_AREA: {name}: {x}, {y}")
    min_gap = float("inf")
    for (a, (x, y, _)), (b, (X, Y, _)) in itertools.combinations(places.items(), 2):
        gap_x = max(x, X) - min(x+w, X+w)
        gap_y = max(y, Y) - min(y+h, Y+h)
        if gap_x < -tolerance and gap_y < -tolerance:
            stop(f"SRAM bị chồng LEF: {a} và {b}: {gap_x:.3f} × {gap_y:.3f} µm")
        if gap_x < -tolerance:
            min_gap = min(min_gap, gap_y)
            if gap_y < 100 - tolerance:
                stop(f"Kênh giữa {a} và {b} dưới 100 µm: {gap_y:.3f}")
        if gap_y < -tolerance:
            min_gap = min(min_gap, gap_x)
            if gap_x < 100 - tolerance:
                stop(f"Kênh giữa {a} và {b} dưới 100 µm: {gap_x:.3f}")
    return min_gap


def write_once(path, content):
    if path.exists():
        if path.read_text() != content:
            stop(f"File đã có nội dung khác; không ghi đè: {path}")
    else:
        path.write_text(content)


def prepare(project):
    design = project / DESIGN_REL
    old_def = design / "runs" / BASE_TAG / "tmp/placement/7-macros_placed.def"
    if not old_def.is_file():
        stop(f"Không có DEF cũ để xác nhận tên 16 SRAM: {old_def}")
    old_places = def_macros(old_def)
    if set(old_places) != EXPECTED:
        stop("Danh sách SRAM thực tế khác danh sách của bản thử nghiệm")
    lef = design / LEF_REL
    if not lef.is_file():
        stop(f"Không tìm thấy SRAM LEF: {lef}")
    size = read_lef_size(lef)
    if any(abs(a-b)>0.01 for a,b in zip(size, (683.1,416.54))):
        stop(f"Kích thước LEF đã thay đổi: {size}")
    gap = validate(POSITIONS, size, EXPECTED)
    base = design / "config.tcl"
    if not base.is_file() or not (design / "pin_order.cfg").is_file():
        stop("Thiếu config.tcl hoặc pin_order.cfg")
    s = base.read_text()
    for required in [
        'set ::env(DIE_AREA) "0 0 7000 5500"',
        'set ::env(CORE_AREA) "200 200 6800 5300"',
        'set ::env(PL_TARGET_DENSITY) 0.40',
        'set ::env(FP_PIN_ORDER_CFG)',
    ]:
        if required not in s:
            stop("config.tcl khác mốc 0.40 dự kiến: " + required)
    if re.search(r"(?m)^\s*set\s+::env\(MACRO_PLACEMENT_CFG\)", s):
        stop("config.tcl đã có MACRO_PLACEMENT_CFG; kiểm tra thủ công trước")
    cfg_text = (s.rstrip() + "\n\n# Controlled macro spacing experiment\n"
                f'set ::env(MACRO_PLACEMENT_CFG) "$::env(DESIGN_DIR)/{PLACEMENT_NAME}"\n'
                'set ::env(MACRO_PLACE_HALO) "20 20"\n')
    macro_text = "".join(
        f"{name} {int(x)} {int(y)} {o}\n"
        for name,(x,y,o) in POSITIONS.items()
    )
    write_once(design / PLACEMENT_NAME, macro_text)
    write_once(design / CFG_NAME, cfg_text)
    print(f"Config mới: {design/CFG_NAME}")
    print(f"Macro cfg: {design/PLACEMENT_NAME}")
    print(f"16 SRAM: 8 bên trái, 8 bên phải; khe hẹp nhất dự kiến {gap:.2f} µm")
    print("config.tcl và các run cũ không bị sửa.")
    return design, size


def pdk_version():
    root = Path.home() / ".volare/volare/sky130/versions"
    known = root / "0fe599b2afb6708d281543108caf8310912f54af"
    if (known / "sky130A").is_dir():
        return known
    options = [p for p in root.glob("*/sky130A") if p.is_dir()]
    if len(options) != 1:
        stop(f"Không xác định duy nhất PDK sky130A: {options}")
    return options[0].parent


def report(path):
    if not path.is_file():
        return None
    total = hot = overflow = hot_overflow = 0
    for block in path.read_text().split("violation type:")[1:]:
        b = re.search(r"bbox = \(\s*([\d.]+),\s*([\d.]+)\s*\) - \(\s*([\d.]+),\s*([\d.]+)\s*\)", block)
        o = re.search(r"\boverflow:(\d+)", block)
        if not b or not o:
            continue
        x = (float(b[1])+float(b[3]))/2
        y = (float(b[2])+float(b[4]))/2
        total += 1
        overflow += int(o[1])
        if 4750<=x<5500 and 4000<=y<4500:
            hot += 1
            hot_overflow += int(o[1])
    return (total, hot, overflow, hot_overflow)


def run_flow(project, design, size):
    run_dir = design / "runs" / NEW_TAG
    if run_dir.exists():
        stop(f"Run mới đã tồn tại; không ghi đè: {run_dir}")
    if shutil.disk_usage(project).free < 20 * 1024**3:
        stop("Dung lượng trống dưới 20 GiB; chưa chạy")
    ps = subprocess.run(["podman", "ps", "-q"], capture_output=True, text=True, check=True)
    if ps.stdout.strip():
        stop("Có container đang chạy; chưa chạy thêm OpenLane")
    pdk = pdk_version()
    container_name = "gemm_macrospaced_v2"
    common = [
        "podman", "run", "--rm", "--name", container_name,
        "--memory=14g", "--userns=keep-id",
        "--security-opt", "label=disable", "-v", f"{project}:/workspace:Z",
        "-v", f"{pdk}:/pdk:ro", "-e", "PDK_ROOT=/pdk", "-w", "/workspace",
        "docker.io/efabless/openlane:2023.12.26", "bash", "-lc",
    ]
    cmd_base = ("flow.tcl -design /workspace/designs/GemmAccelerator "
                f"-config_file /workspace/designs/GemmAccelerator/{CFG_NAME} -tag {NEW_TAG}")
    print("\n=== Chạy OpenLane; kiểm tra DEF macro ngay khi xuất hiện ===", flush=True)
    proc = subprocess.Popen(common + [cmd_base], cwd=project)
    verified = False
    try:
        while proc.poll() is None:
            candidates = sorted((run_dir / "tmp/placement").glob("*macro*def"))
            for actual_def in reversed(candidates):
                if not actual_def.is_file():
                    continue
                with actual_def.open("rb") as f:
                    f.seek(max(0, actual_def.stat().st_size - 256))
                    if b"END DESIGN" not in f.read():
                        continue  # OpenROAD is still writing the DEF.
                actual = def_macros(actual_def)
                gap = validate(actual, size, EXPECTED, tolerance=0.02)
                for name in EXPECTED:
                    x,y,o = actual[name]
                    X,Y,O = POSITIONS[name]
                    if abs(x-X)>2 or abs(y-Y)>2 or o != O:
                        stop(f"Macro bị đặt khác dự kiến: {name}: {(x,y,o)} thay vì {(X,Y,O)}")
                print(f"DEF thật hợp lệ: {actual_def}")
                print(f"16 SRAM không chồng, khe hẹp nhất {gap:.2f} µm", flush=True)
                verified = True
                break
            if verified:
                break
            time.sleep(5)
    except BaseException:
        subprocess.run(["podman", "stop", "--time", "5", container_name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=False)
        proc.wait()
        raise
    rc = proc.wait()
    if not verified:
        stop("Flow kết thúc trước khi kiểm tra được DEF macro; xem log run mới")
    rpt_rel = Path("tmp/routing/resizer-routing-design-congestion.rpt")
    baseline = report(design / "runs" / BASE_TAG / rpt_rel)
    current = report(run_dir / rpt_rel)
    if baseline:
        print(f"Baseline 0.38: marker={baseline[0]}, vùng cũ={baseline[1]}, overflow={baseline[2]}, vùng cũ={baseline[3]}")
    if current:
        print(f"Run mới:       marker={current[0]}, vùng cũ={current[1]}, overflow={current[2]}, vùng cũ={current[3]}")
    if rc:
        stop(f"OpenLane dừng với exit {rc}. Xem log trong {run_dir}; không coi run này là GDS hoàn chỉnh")
    print(f"OpenLane kết thúc. Kiểm tra STA/DRC/LVS và results/final trong {run_dir}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path,
                        default=Path.home()/"Downloads/GEMM_final_DSP_OPENLANE_ASIC")
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--prepare", action="store_true", help="chỉ tạo và kiểm tra config mới")
    actions.add_argument("--run", action="store_true", help="chuẩn bị, chạy flow và kiểm tra DEF macro khi xuất hiện")
    args = parser.parse_args()
    project = args.project.expanduser().resolve()
    if not project.is_dir():
        stop(f"Không tìm thấy dự án: {project}")
    design, size = prepare(project)
    if args.run:
        run_flow(project, design, size)


if __name__ == "__main__":
    main()
