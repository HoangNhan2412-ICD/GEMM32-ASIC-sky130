#!/usr/bin/env python3
"""
axi_overhead.py - what the AXI interface adds to the GEMM core.

usage: axi_overhead.py <core run> <shell_thin run> <shell_reg run> [--md out.md] [--lib <hd tt .lib>]
                       [--row <row run>]

core run  : the core_v11 run (designs/gemm_core/runs/core_v11)
shell runs: gemm_axi_shell runs of the two stream variants (run_flow.sh axi-shell)

Prints one table (markdown): cell count, flops, standard-cell area, timing
per corner, vectorless power, for the core and each shell variant, and the
shell as a percentage of the core. Every number is read from the run
directories; a value that is not there prints as "-" (never guessed).

Where the numbers come from
  cells, flops                : reports/synthesis/*.stat.rpt (Yosys), sky130_fd_sc_hd
                                cells of the top module only (rows/SRAM macros not counted)
  core std cells incl. rows    : the core's own cells + (row macros in the core) x the
                                std-cell area of one row (--row, the row_v1 run). The
                                core's top-level cells alone are a small part of the
                                logic: the PEs are inside the row macros.
  std-cell area               : those cell counts x the cell areas of the
                                sky130_fd_sc_hd tt liberty (--lib, or found under
                                $PDK_ROOT, ~/.ciel, ~/.volare), so macros never enter it
                                even if their .lib was given to synthesis
  layout area                 : last "Design area" OpenROAD printed before
                                filler insertion (shell: its placed cells)
  die                         : metrics.csv DIEAREA_mm^2
  timing                      : multi-corner signoff logs (*-rcx_mcsta.{max,min}.log):
                                worst slack per corner of the paths INSIDE the block
                                and, apart, of the paths that start or end at a port
                                (core_v11 waives its I/O paths: no pad ring yet)
  power                       : reports/power/vectorless.design.rpt (OpenSTA
                                default activity, tt/25C/1.80V, 100 MHz):
                                tools/power.sh for the core,
                                tools/axi_shell_power.sh for the shells
"""
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "openlane"))
try:
    from check_openlane_run import hold_slack, sta_paths  # noqa: E402
except Exception:                                          # pragma: no cover
    hold_slack = sta_paths = None


def metrics(run):
    p = os.path.join(run, "reports", "metrics.csv")
    if not os.path.exists(p):
        return {}
    return next(csv.DictReader(open(p)), {})


def num(x):
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return None if v == -1 else v


def synth_stat(run, top):
    """(cell count, flop count, {cell: count}) of the sky130_fd_sc_hd cells of module `top`"""
    fs = sorted(glob.glob(os.path.join(run, "reports", "synthesis", "*.stat.rpt")))
    if not fs or not top:
        return None, None, None
    text = open(fs[-1], errors="ignore").read()
    blk = None
    for b in re.split(r"\n(?====)", "\n" + text):
        m = re.match(r"=== (\S+) ===", b.strip())
        if m and m.group(1).lstrip("\\") == top:
            blk = b
    if blk is None:
        return None, None, None
    counts = {}
    for m in re.finditer(r"^\s+(sky130_fd_sc_hd__\w+)\s+(\d+)\s*$", blk, re.M):
        counts[m.group(1)] = counts.get(m.group(1), 0) + int(m.group(2))
    rows = re.search(r"^\s+\\?ProcessingElementRow\s+(\d+)\s*$", blk, re.M)
    counts["__rows__"] = int(rows.group(1)) if rows else 0
    if len(counts) == 1:
        return None, None, None
    # flip-flops and latches: df[xrsb]*, edf*, sdf*, dlx*, dlr* (not dlygate/dlymetal)
    flops = sum(n for c, n in counts.items()
                if re.match(r"sky130_fd_sc_hd__(e?df[xrsb]|sdf|dl[xr])", c))
    return sum(n for c, n in counts.items() if c != "__rows__"), flops, counts


def find_lib(arg):
    if arg:
        return arg
    for root in (os.environ.get("PDK_ROOT"), os.path.expanduser("~/.ciel"), os.path.expanduser("~/.volare")):
        if not root:
            continue
        direct = os.path.join(root, "sky130A", "libs.ref", "sky130_fd_sc_hd", "lib",
                              "sky130_fd_sc_hd__tt_025C_1v80.lib")
        if os.path.exists(direct):
            return direct
        hits = glob.glob(os.path.join(root, "**", "sky130A", "libs.ref", "sky130_fd_sc_hd", "lib",
                                      "sky130_fd_sc_hd__tt_025C_1v80.lib"), recursive=True)
        if hits:
            return hits[0]
    return None


def lib_areas(path):
    """{cell name: area um^2} from a liberty file"""
    if not path or not os.path.exists(path):
        return {}
    areas, cell = {}, None
    for line in open(path, errors="ignore"):
        m = re.match(r'\s*cell\s*\(\s*"?([\w]+)"?\s*\)', line)
        if m:
            cell = m.group(1)
            continue
        m = re.match(r"\s*area\s*:\s*([\d.]+)", line)
        if m and cell and cell not in areas:
            areas[cell] = float(m.group(1))
    return areas


def layout_area(run):
    """last 'Design area' before fill insertion"""
    logs = sorted(glob.glob(os.path.join(run, "logs", "*", "*.log")),
                  key=lambda f: (int(re.match(r"(\d+)", os.path.basename(f)).group(1))
                                 if re.match(r"\d+", os.path.basename(f)) else 0))
    val = None
    for f in logs:
        b = os.path.basename(f)
        if "fill" in b or "signoff" in f:
            break                      # fillers are in every later number
        for m in re.finditer(r"Design area ([\d.]+) u\^2", open(f, errors="ignore").read()):
            val = float(m.group(1))
    return val


def corner_slacks(run, kind):
    """{corner: (worst internal slack, worst port slack)} from the multi-corner
    signoff STA, worst over RC min/max. A port path starts at an input port or
    ends at an output port."""
    out = {}
    cmd = "report_checks -path_delay max" if kind == "setup" else "report_checks -path_delay min"
    for rc in ("min", "max"):
        logs = sorted(glob.glob(os.path.join(run, "logs", "signoff", f"*-rcx_mcsta.{rc}.log")))
        if not logs:
            continue
        text = open(logs[-1], errors="ignore").read()
        i = text.find(cmd)
        if i < 0:
            continue
        j = text.find("\nreport_checks", i + len(cmd))
        sec = text[i:j if j > 0 else len(text)]
        for part in sec.split("======================= ")[1:]:
            corner = part.split()[0]
            inner, port = out.get(corner, (None, None))
            for blk in re.split(r"\n(?=Startpoint: )", "\n" + part)[1:]:
                st = re.search(r"Startpoint: \S+ \(([^)]*)\)", blk)
                en = re.search(r"Endpoint: \S+ \(([^)]*)\)", blk)
                sl = re.search(r"(-?\d+\.\d+)\s+slack \((?:VIOLATED|MET)\)", blk)
                if not (st and en and sl):
                    continue
                v = float(sl.group(1))
                if "input port" in st.group(1) or "output port" in en.group(1):
                    port = v if port is None else min(port, v)
                else:
                    inner = v if inner is None else min(inner, v)
            out[corner] = (inner, port)
    return out


def power_total(run, name="vectorless"):
    p = os.path.join(run, "reports", "power", f"{name}.design.rpt")
    if not os.path.exists(p):
        return None
    for line in open(p, errors="ignore"):
        if line.startswith("Total"):
            f = line.split()
            try:
                return float(f[4])
            except (IndexError, ValueError):
                return None
    return None


def io_paths(run):
    """(violating paths touching a port, worst slack among them) in the signoff setup report"""
    if sta_paths is None:
        return None
    P = sta_paths(run, "max")
    if P is None:
        return None
    io = [p for p in P if p[1]]
    bad = [p for p in io if p[0] < 0]
    return len(bad), min((p[0] for p in io), default=None)


def collect(run, areas, row_area=None):
    m = metrics(run)
    cells, flops, counts = synth_stat(run, m.get("design_name"))
    area = None
    if counts and areas:
        missing = [c for c in counts if c != "__rows__" and c not in areas]
        if missing:
            print(f"note: {len(missing)} cell types of {run} not in the liberty (e.g. {missing[0]}); area left out")
        else:
            area = sum(n * areas[c] for c, n in counts.items() if c != "__rows__")
    area_all = area
    if area is not None and counts and counts.get("__rows__") and row_area:
        area_all = area + counts["__rows__"] * row_area
    return {
        "run": run, "name": os.path.basename(run.rstrip("/")),
        "cells": cells, "flops": flops, "area": area, "area_all": area_all,
        "rows": counts.get("__rows__", 0) if counts else 0,
        "layout": layout_area(run),
        "die": num(m.get("DIEAREA_mm^2")),
        "wns_tt": num(m.get("spef_wns")),
        "hold_tt": hold_slack(run) if hold_slack else None,
        "setup_c": corner_slacks(run, "setup"),
        "hold_c": corner_slacks(run, "hold"),
        "pwr": power_total(run),
        "pwr_vcd": next((power_total(run, os.path.basename(f)[:-len(".design.rpt")])
                         for f in sorted(glob.glob(os.path.join(run, "reports", "power", "vcd_*.design.rpt")))),
                        None),
        "io": io_paths(run),
    }


def fmt(v, spec):
    return "-" if v is None else format(v, spec)


def pct(a, b):
    return "-" if a is None or b in (None, 0) else f"{100.0 * a / b:.3f} %"


def main():
    args = sys.argv[1:]
    md = None
    if "--md" in args:
        k = args.index("--md")
        md = args[k + 1]
        del args[k:k + 2]
    lib = None
    if "--lib" in args:
        k = args.index("--lib")
        lib = args[k + 1]
        del args[k:k + 2]
    row_run = None
    if "--row" in args:
        k = args.index("--row")
        row_run = args[k + 1].rstrip("/")
        del args[k:k + 2]
    if len(args) != 3:
        print(__doc__)
        return 2
    lib = find_lib(lib)
    areas = lib_areas(lib)
    if not areas:
        print("note: sky130_fd_sc_hd tt liberty not found (give --lib): no std-cell area")
    row_area = rr = None
    if row_run:
        rr = collect(row_run, areas)
        row_area = rr["area"]
        if row_area is None:
            print(f"note: no std-cell area for the row run {row_run}")
    core, thin, reg = (collect(a.rstrip("/"), areas, row_area) for a in args)
    # the core's cells and flops including the ones inside its row macros
    for k in ("cells", "flops"):
        core[k + "_all"] = (core[k] + core["rows"] * rr[k]
                            if rr and core[k] is not None and rr[k] is not None and core["rows"] else None)

    rows = []

    def row(label, key, spec, overhead=True, get=None):
        g = get or (lambda d: d[key])
        c, t, r = g(core), g(thin), g(reg)
        rows.append([label, fmt(c, spec), fmt(t, spec), fmt(r, spec),
                     pct(t, c) if overhead else "", pct(r, c) if overhead else ""])

    def row_all(label, key, spec):
        c = core[key + "_all"]
        rows.append([label, fmt(c, spec), fmt(thin[key], spec), fmt(reg[key], spec),
                     pct(thin[key], c), pct(reg[key], c)])

    row_all(f"standard cells, core incl. {core['rows']} row macros (synthesis)", "cells", "d")
    row_all(f"flops, core incl. {core['rows']} row macros (synthesis)", "flops", "d")
    row("standard cells, core top level only", "cells", "d", overhead=False)
    row("std-cell area after synthesis, core top level only (um^2)", "area", ".0f", overhead=False)
    rows.append([f"core std-cell area incl. {core['rows']} row macros (um^2)",
                 fmt(core["area_all"] if core["rows"] and row_area else None, ".0f"), "", "",
                 pct(thin["area"], core["area_all"]) if core["rows"] and row_area else "-",
                 pct(reg["area"], core["area_all"]) if core["rows"] and row_area else "-"])
    row("placed area before fill (um^2)", "layout", ".0f", overhead=False)
    rows.append(["die area (mm^2)", fmt(core["die"], ".2f"), "(pin-bound, n/a)", "(pin-bound, n/a)",
                 pct(None if thin["layout"] is None else thin["layout"] / 1e6, core["die"]),
                 pct(None if reg["layout"] is None else reg["layout"] / 1e6, core["die"])])
    for kind, key in (("setup", "setup_c"), ("hold", "hold_c")):
        for corner in ("Slowest", "Typical", "Fastest"):
            row(f"{kind} worst slack inside the block, {corner} (ns)", None, ".2f", overhead=False,
                get=lambda d, c=corner, k=key: d[k].get(c, (None, None))[0])
        for corner in ("Slowest", "Typical", "Fastest"):
            row(f"{kind} worst slack at a port, {corner} (ns)", None, ".2f", overhead=False,
                get=lambda d, c=corner, k=key: d[k].get(c, (None, None))[1])
    rows.append(["violating setup paths at a port", "-",
                 "-" if thin["io"] is None else str(thin["io"][0]),
                 "-" if reg["io"] is None else str(reg["io"][0]), "", ""])
    row("power, vectorless tt 100 MHz (W)", "pwr", ".4g")
    rows.append(["power, core from VCD (W)", fmt(core["pwr_vcd"], ".4g"), "", "",
                 pct(thin["pwr"], core["pwr_vcd"]) + " (shell vectorless)" if core["pwr_vcd"] else "",
                 pct(reg["pwr"], core["pwr_vcd"]) + " (shell vectorless)" if core["pwr_vcd"] else ""])

    head = ["", f"core ({core['name']})", f"shell thin ({thin['name']})", f"shell reg ({reg['name']})",
            "thin / core", "reg / core"]
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    out += ["", "Slack rows: '-' = no such path listed. core_v11 has no pad ring and waives its",
            "port paths (README), so its 'at a port' rows are not signoff numbers.",
            "", f"core : {core['run']}", f"thin : {thin['run']}", f"reg  : {reg['run']}",
            f"row  : {row_run or '(not given: core area = top-level cells only)'}",
            f"cell areas: {lib or 'liberty not found'}"]
    text = "\n".join(out)
    print(text)
    if md:
        with open(md, "w") as f:
            f.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
