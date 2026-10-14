#!/usr/bin/env python3
"""timing_gate.py <run dir> [--ref <reference run dir>]

Timing verdict of a finished run, from its signoff STA reports:
  setup, Typical (reports/signoff/*-rcx_sta.max.rpt):
      internal paths (no I/O port)  worst slack >= 0          -> else FAIL
      paths touching an I/O port    worst slack >= 0, or not worse than the
                                    same paths of --ref       -> else FAIL
  hold, every library corner and RC min/max (logs/signoff/*-rcx_mcsta.{min,max}.log)
      and Typical (*-rcx_sta.min.rpt): worst slack >= 0       -> else FAIL
  setup, Slowest / Fastest: printed, never judged (the clock of the slow corner
      is a separate decision).
  max slew / cap / fanout counts (*-rcx_sta.checks.rpt): printed next to --ref.
Exit 0 = PASS, 1 = FAIL, 2 = reports missing.
"""
import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sta_summary import blocks  # noqa: E402


def paths(text):
    out = []
    for b in blocks(text):
        st = re.search(r"Startpoint: (\S+) \(([^)]*)\)", b)
        en = re.search(r"Endpoint: (\S+) \(([^)]*)\)", b)
        sl = re.search(r"(-?\d+\.\d+)\s+slack \((VIOLATED|MET)\)", b)
        if st and en and sl:
            port = "input port" in st.group(2) or "output port" in en.group(2)
            out.append((float(sl.group(1)), port, st.group(1), en.group(1)))
    return out


def worst(ps, port):
    s = [p for p in ps if p[1] == port]
    return (min(s, key=lambda p: p[0]), sum(1 for p in s if p[0] < 0)) if s else (None, 0)


def last(run, pattern):
    f = sorted(glob.glob(os.path.join(run, pattern)))
    return f[-1] if f else None


def corners(log, cmd):
    """{corner name: report text} of one report_checks block of a multi-corner log"""
    text = open(log, errors="ignore").read()
    i = text.find(cmd)
    if i < 0:
        return {}
    j = text.find("\nreport_checks", i + len(cmd))
    sec = text[i:j if j > 0 else len(text)]
    return {c.split()[0]: c for c in sec.split("======================= ")[1:]}


def checks(run):
    f = last(run, "reports/signoff/*-rcx_sta.checks.rpt")
    if not f:
        return {}
    return {m.group(1): int(m.group(2)) for m in
            re.finditer(r"max (slew|fanout|cap) violation count (\d+)", open(f, errors="ignore").read())}


def fmt(w, n):
    return "no paths listed" if w is None else f"worst {w[0]:+.2f} ns ({n} violating), {w[2]} -> {w[3]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--ref", help="reference run (I/O waiver and max slew/cap counts)")
    a = ap.parse_args()
    fails = []
    print(f"timing gate: {a.run}" + (f"  (reference {a.ref})" if a.ref else ""))

    smax = last(a.run, "reports/signoff/*-rcx_sta.max.rpt")
    smin = last(a.run, "reports/signoff/*-rcx_sta.min.rpt")
    if not smax or not smin:
        print("  MISSING  reports/signoff/*-rcx_sta.{max,min}.rpt")
        return 2
    ps = paths(open(smax, errors="ignore").read())
    wi, ni = worst(ps, False)
    wo, no = worst(ps, True)
    ok = wi is None or wi[0] >= 0
    print(f"  {'PASS' if ok else 'FAIL'}     setup Typical, internal: {fmt(wi, ni)}")
    if not ok:
        fails.append("setup Typical internal")
    ref_io = None
    if a.ref:
        r = last(a.ref, "reports/signoff/*-rcx_sta.max.rpt")
        if r:
            ref_io = worst(paths(open(r, errors="ignore").read()), True)[0]
    if wo is None or wo[0] >= 0:
        print(f"  PASS     setup Typical, I/O: {fmt(wo, no)}")
    elif ref_io is not None and wo[0] >= ref_io[0]:
        print(f"  PASS     setup Typical, I/O: {fmt(wo, no)} - not worse than the reference ({ref_io[0]:+.2f})")
    else:
        print(f"  FAIL     setup Typical, I/O: {fmt(wo, no)}"
              + (f" - reference {ref_io[0]:+.2f}" if ref_io is not None else ""))
        fails.append("setup Typical I/O")

    hold = [("Typical (rcx_sta)", paths(open(smin, errors="ignore").read()))]
    for rc in ("min", "max"):
        log = last(a.run, f"logs/signoff/*-rcx_mcsta.{rc}.log")
        if not log:
            print(f"  MISSING  logs/signoff/*-rcx_mcsta.{rc}.log")
            fails.append(f"hold RC {rc} missing")
            continue
        for c, t in corners(log, "report_checks -path_delay min").items():
            hold.append((f"{c}, RC {rc}", paths(t)))
        for c, t in corners(log, "report_checks -path_delay max").items():
            if c != "Typical":
                w = [p for p in paths(t)]
                m = min(w, key=lambda p: p[0]) if w else None
                print(f"  info     setup {c}, RC {rc} (not judged): "
                      + ("no paths listed" if m is None else
                         f"worst {m[0]:+.2f} ns, {sum(1 for p in w if p[0] < 0)} violating listed"))
    for name, ps in hold:
        m = min(ps, key=lambda p: p[0]) if ps else None
        ok = m is None or m[0] >= 0
        print(f"  {'PASS' if ok else 'FAIL'}     hold {name}: "
              + ("no paths listed" if m is None else
                 f"worst {m[0]:+.2f} ns ({sum(1 for p in ps if p[0] < 0)} violating), {m[2]} -> {m[3]}"))
        if not ok:
            fails.append(f"hold {name}")

    c, rc = checks(a.run), checks(a.ref) if a.ref else {}
    if c:
        print("  info     max slew / cap / fanout violations: "
              + ", ".join(f"{k} {c.get(k, '?')}" + (f" (ref {rc[k]})" if k in rc else "")
                          for k in ("slew", "cap", "fanout")))
    print(f"RESULT: {'FAIL (' + ', '.join(fails) + ')' if fails else 'PASS'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
