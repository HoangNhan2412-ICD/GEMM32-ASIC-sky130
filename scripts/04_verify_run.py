#!/usr/bin/env python3
"""Verify the reproducibility-relevant outputs of macrospaced_v2."""

import argparse
import re
from pathlib import Path


TAG = "area7000x5500_density40_macrospaced_v2"
MACRO = "sky130_sram_2kbyte_1rw1r_128x128_128"
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
EXPECTED = {
    name: (float(x), float(350 + 600 * index), "N")
    for x, group in ((400, LEFT), (5700, RIGHT))
    for index, name in enumerate(group)
}


def read_def_macros(path: Path):
    units = None
    in_components = False
    record = ""
    result = {}
    with path.open(errors="replace") as handle:
        for raw in handle:
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
                match = re.match(r"-\s+(\S+)\s+(\S+)", record)
                if match and match[2] == MACRO:
                    placed = re.search(
                        r"\+\s+(?:FIXED|PLACED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)",
                        record,
                    )
                    if placed and units:
                        result[match[1]] = (
                            int(placed[1]) / units,
                            int(placed[2]) / units,
                            placed[3],
                        )
                record = ""
    return result


def choose_def(run: Path):
    preferred = sorted((run / "tmp/placement").glob("*macro*.def"))
    if preferred:
        return preferred[-1]
    candidates = sorted((run / "results").rglob("*.def"))
    return candidates[-1] if candidates else None


def congestion_metrics(path: Path):
    markers = overflow = 0
    for block in path.read_text(errors="replace").split("violation type:")[1:]:
        if "bbox =" not in block:
            continue
        markers += 1
        found = re.search(r"\boverflow:(\d+)", block)
        if found:
            overflow += int(found[1])
    return markers, overflow


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.expanduser().resolve()
    design = project / "designs/GemmAccelerator"
    run = design / "runs" / TAG
    if not run.is_dir():
        raise SystemExit(f"FAIL: Không tìm thấy run: {run}")

    print(f"Run: {run}")

    config = run / "config.tcl"
    if not config.is_file():
        config = run / "config_in.tcl"
    if config.is_file():
        text = config.read_text(errors="replace")
        print("\nThông số cấu hình:")
        for key in (
            "DESIGN_NAME", "CLOCK_PORT", "CLOCK_PERIOD", "PDK",
            "STD_CELL_LIBRARY", "DIE_AREA", "CORE_AREA",
            "PL_TARGET_DENSITY", "MACRO_PLACEMENT_CFG", "MACRO_PLACE_HALO",
        ):
            match = re.search(rf"(?m)^\s*set\s+::env\({key}\)\s+(.+)$", text)
            print(f"  {key}: {match[1].strip() if match else 'KHÔNG TÌM THẤY'}")

    actual_def = choose_def(run)
    if actual_def is None:
        raise SystemExit("FAIL: Không tìm thấy DEF để kiểm tra macro")
    actual = read_def_macros(actual_def)
    missing = sorted(set(EXPECTED) - set(actual))
    extra = sorted(set(actual) - set(EXPECTED))
    wrong = []
    for name, expected in EXPECTED.items():
        if name not in actual:
            continue
        x, y, orient = actual[name]
        ex, ey, eo = expected
        if abs(x - ex) > 2 or abs(y - ey) > 2 or orient != eo:
            wrong.append((name, actual[name], expected))

    print(f"\nDEF kiểm tra: {actual_def}")
    print(f"Số macro {MACRO}: {len(actual)}")
    if missing or extra or wrong or len(actual) != 16:
        print(f"Thiếu: {missing}")
        print(f"Dư: {extra}")
        for name, got, expected in wrong:
            print(f"Sai vị trí: {name}: thực tế={got}, dự kiến={expected}")
        raise SystemExit("FAIL: Macro placement không khớp")
    print("Macro placement: PASS — đúng 16 instance và đúng tọa độ")

    stage_files = {
        "synthesis": list((run / "results/synthesis").glob("*.v")),
        "floorplan": list((run / "results/floorplan").glob("*.def")),
        "placement": list((run / "results/placement").glob("*.def"))
        + list((run / "results/placement").glob("*.odb")),
        "cts": list((run / "results/cts").glob("*.def"))
        + list((run / "results/cts").glob("*.odb")),
        "routing": list((run / "results/routing").glob("*")),
    }
    print("\nStage outputs:")
    for stage, files in stage_files.items():
        print(f"  {stage}: {'CÓ' if files else 'CHƯA CÓ'}")

    congestion = run / "tmp/routing/resizer-routing-design-congestion.rpt"
    if congestion.is_file():
        markers, overflow = congestion_metrics(congestion)
        print(f"\nCongestion markers: {markers}")
        print(f"Overflow sum: {overflow}")
    else:
        print("\nChưa có congestion report")

    grt_hits = []
    routing_logs = run / "logs/routing"
    if routing_logs.is_dir():
        for log in routing_logs.rglob("*.log"):
            for number, line in enumerate(log.read_text(errors="replace").splitlines(), 1):
                if "GRT-0119" in line:
                    grt_hits.append(f"{log.relative_to(run)}:{number}: {line.strip()}")
    print(f"GRT-0119: {'CÓ' if grt_hits else 'KHÔNG'}")
    for hit in grt_hits[:5]:
        print(f"  {hit}")

    final_gds = list((run / "results").rglob("*.gds")) + list((run / "results").rglob("*.gdsii"))
    print(f"Final GDS: {'CÓ' if final_gds else 'CHƯA CÓ'}")
    print("\nVERIFY PASS: cấu hình và macro placement có thể đối chiếu được.")
    if grt_hits and not final_gds:
        print("Trạng thái khớp mốc lịch sử: dừng routing vì GRT-0119, chưa signoff/GDS.")


if __name__ == "__main__":
    main()

