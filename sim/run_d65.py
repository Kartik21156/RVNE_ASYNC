"""D6.5 exit-criterion runner: rvne_c_element, rvne_delay, rvne_bridge_async (no storage).

  python sim/run_d65.py

Legal timing configurations must run clean (no assertion, 0 TB errors, all 10
ops, exact E0–E8 event times). Each fault and each delay-violation
configuration must fire its target assertion and nothing else.
Then re-runs D6.4 (which re-runs D6.3 and D6.2).
"""
import re
import subprocess
import sys
from pathlib import Path

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
WORK = SIM / "work"
SETTINGS = r"C:\Xilinx\Vivado\2022.1\settings64.bat"
TOP = "tb_rvne_bridge_async"

# name: (generics, PRIM, expected assertion or None)
CONFIGS = {
    "nominal":   ({"D_DEC": 1.0,  "D_SPM": 2.0,  "D_WR": 1.0},  1, None),
    "legal_A":   ({"D_DEC": 0.35, "D_SPM": 1.55, "D_WR": 0.35}, 0, None),   # 50 ps margins
    "legal_B":   ({"D_DEC": 3.1,  "D_SPM": 4.7,  "D_WR": 2.3},  0, None),
    "legal_C":   ({"D_DEC": 0.6,  "D_SPM": 1.9,  "D_WR": 0.4},  0, None),
    "viol_T1":   ({"D_DEC": 0.2,  "D_SPM": 2.0,  "D_WR": 1.0},  0, "a_W1"),  # D_DEC < T_EXEC
    "viol_T2":   ({"D_DEC": 1.0,  "D_SPM": 0.3,  "D_WR": 1.0},  0, "a_W2"),  # D_SPM < T_SPM (net of slack)
    "viol_rsp":  ({"D_DEC": 0.31, "D_SPM": 1.51, "D_WR": 0.05}, 0, "a_P3"),  # D_TOTAL < 2*T_EXEC + T_SPM
}
FAULTS = {
    1: ("re-request before ack fall", "a_P8"),
    2: ("req dropped before ack", "a_P4_req_fall"),
    3: ("malformed (short) reset mid-transaction", "a_P6"),
    4: ("req glitch while idle", "a_P4_req_fall"),
    5: ("command changed inside req..ack", "a_P2"),
    6: ("response changed inside ack..req-fall", "a_P3"),
    7: ("write strobe held open at ack rise", "a_P5"),
    8: ("write strobe while idle", "a_P6"),
    9: ("reserved op", "a_P7"),
    10: ("ack rise without req", "a_P4_ack_rise"),
    11: ("ack fall while req high", "a_P4_ack_fall"),
}


def sh(cmd, cwd):
    # xsim/xvlog/xelab are .bat wrappers: cmd splits unquoted arguments at '='
    r = subprocess.run(f"call {SETTINGS} >nul && {cmd}", cwd=cwd, capture_output=True, text=True, shell=True)
    return r.returncode, r.stdout + r.stderr


def fired(out):
    return sorted(set(re.findall(r"(a_\w+) violated", out)))


def main():
    subprocess.run([sys.executable, str(ROOT / "model" / "export_vectors.py")], check=True,
                   stdout=subprocess.DEVNULL)
    rc, out = sh(f"{SIM / 'run_xsim.bat'} {TOP} elab", SIM)          # compiles everything
    if rc != 0 or "Built simulation snapshot" not in out:
        print(out[-3000:]); print("D6.5 FAIL: build"); return 1
    warn = [l for l in out.splitlines() if "WARNING" in l]
    ok = not warn
    print(f"build ok ({len(warn)} warnings)")
    for l in warn:
        print("  ", l)

    for name, (gen, prim, expect) in CONFIGS.items():
        g = " ".join(f'-generic_top "{k}={v}"' for k, v in gen.items()) + f' -generic_top "PRIM={prim}"'
        rc, out = sh(f"xelab {TOP} -debug typical -timescale 1ns/1ps {g} -s snap_{name} --log elab_{name}.log", WORK)
        if rc != 0:
            print(out[-2000:]); print(f"{name}: elab FAIL"); ok = False; continue
        rc, out = sh(f"xsim snap_{name} -R --log d65_{name}.log", WORK)
        f = fired(out)
        m = re.search(r"TB_SUMMARY (.*)", out)
        s = dict(kv.split("=") for kv in m.group(1).split()) if m else {}
        if expect is None:
            good = bool(s) and not f and s["tb_errors"] == "0" and s["ops_seen"] == "3ff"
            extra = [l for l in out.splitlines() if l.startswith(("TB_PRIM", "TB_RESET"))]
            detail = (m.group(1) if m else "no summary") + "".join("\n      " + l for l in extra)
        else:
            good = expect in f and all(a == expect for a in f)
            detail = f"expect {expect}, fired {f}"
        if not good:
            print("\n".join(l for l in out.splitlines() if l.startswith("TB_ERROR"))[:2000])
        ok &= good
        print(f"CONFIG {name:9s} {gen}: {'PASS' if good else 'FAIL'}  {detail}")

    for k, (what, target) in FAULTS.items():
        rc, out = sh(f'xsim snap_nominal -R -testplusarg "FAULT={k}" --log d65_fault{k}.log', WORK)
        f = fired(out)
        good = target in f and all(a == target for a in f)
        ok &= good
        print(f"FAULT={k:<2} {what:42s} {'PASS' if good else 'FAIL'}  expect {target}, fired {f}")

    print("D6.5", "PASS" if ok else "FAIL")
    if ok:
        print("\nre-running D6.4 (+D6.3, D6.2) regression:")
        r = subprocess.run([sys.executable, str(SIM / "run_d64.py")], capture_output=True, text=True)
        tail = [l for l in r.stdout.splitlines() if re.match(r"\s*(D6\.\d|build)", l)]
        print("\n".join("  " + l.strip() for l in tail))
        ok &= r.returncode == 0
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
