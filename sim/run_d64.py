"""D6.4 exit-criterion runner: rvne_bridge_sync (+ rvne_sync2) vs a behavioural async responder.

  python sim/run_d64.py

Pass requires:
  * the full D6.3-proven command stream crosses the boundary with the exact
    D5 response, every S1–S5 cycle check and P2/P3/P8 boundary check holding;
  * directed D1 (fast path), D2 (spurious ack), D3 (reset mid-transaction) pass;
  * no assertion fires and the build has no warnings;
  * each bridge assertion fires, alone, under its fault injection.
Then re-runs D6.3 (which re-runs D6.2).
"""
import re
import subprocess
import sys
from pathlib import Path

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
WORK = SIM / "work"
SETTINGS = r"C:\Xilinx\Vivado\2022.1\settings64.bat"
TOP = "tb_rvne_bridge_sync"
FAULTS = {1: "a_S1", 2: "a_P8_sync", 3: "a_P4_sync", 4: "a_S3", 5: "a_rsp_pulse"}


def sh(cmd, cwd):
    # xsim/xvlog are .bat wrappers: cmd splits unquoted arguments at '='
    r = subprocess.run(f"call {SETTINGS} >nul && {cmd}", cwd=cwd, capture_output=True, text=True, shell=True)
    return r.returncode, r.stdout + r.stderr


def fired(out):
    return sorted(set(re.findall(r"(a_\w+) violated", out)))


def main():
    subprocess.run([sys.executable, str(ROOT / "model" / "export_vectors.py")], check=True)
    rc, out = sh(f"{SIM / 'run_xsim.bat'} {TOP} elab", SIM)
    if rc != 0 or "Built simulation snapshot" not in out:
        print(out[-3000:]); print("D6.4 FAIL: build"); return 1
    warn = [l for l in out.splitlines() if "WARNING" in l]
    print(f"build ok ({len(warn)} warnings)")
    for l in warn:
        print("  ", l)
    ok = not warn

    rc, out = sh(f"xsim {TOP}_snap -R --log d64.log", WORK)
    for l in out.splitlines():
        if l.startswith(("TB_ERROR", "TB_D", "TB_INFO")):
            print(l)
    f = fired(out)
    print("assertions fired:", f or "none")
    m = re.search(r"TB_SUMMARY (.*)", out)
    print("summary:", m.group(1) if m else "none")
    s = dict(kv.split("=") for kv in m.group(1).split()) if m else {}
    n = int(s.get("commands", -1))
    # D1 8 + D2 1 + stream n + D3 50, and every responder transaction accounted for
    good = bool(s) and not f and s["tb_errors"] == "0" and int(s["transactions"]) == n + 59 \
        and int(s["responder_txn"]) == n + 60 and int(s["min_latency_edges"]) == 7
    ok &= good
    print("MODE main:", "PASS" if good else "FAIL")

    for k, target in FAULTS.items():
        rc, out = sh(f'xsim {TOP}_snap -R -testplusarg "FAULT={k}" --log d64_fault{k}.log', WORK)
        f = fired(out)
        good = target in f and all(a == target for a in f)
        ok &= good
        print(f"FAULT={k} ({target}): {'PASS' if good else 'FAIL'}  fired {f}")

    print("D6.4", "PASS" if ok else "FAIL")
    if ok:
        print("\nre-running D6.3 (+D6.2) regression:")
        r = subprocess.run([sys.executable, str(SIM / "run_d63.py")], capture_output=True, text=True)
        tail = [l for l in r.stdout.splitlines() if l.startswith(("D6.", "  D6.", "FAULT", "build"))]
        print("\n".join("  " + l for l in tail))
        ok &= r.returncode == 0
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
