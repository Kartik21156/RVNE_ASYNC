"""D6.3 exit-criterion runner: rvne_decoder (+ rvne_status) against D5.

  python sim/run_d63.py

Pass requires:
  * Part A: every issue.hex vector matches D5 accept/writeback/register_read,
    and every D2 §5.1 category is exercised;
  * Part B: every txn.hex instruction matches D5 (accept, exact bridge command
    or none, result, STATUS), operand errors raise no command (DEC-07);
  * no assertion fires; the build has no warnings.
Then re-runs D6.2 so the shared vector format change is covered.
"""
import re
import subprocess
import sys
from pathlib import Path

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
WORK = SIM / "work"
SETTINGS = r"C:\Xilinx\Vivado\2022.1\settings64.bat"
TOP = "tb_rvne_decoder"
CATS = {0x0: "LEGAL_CUSTOM0", 0x1: "LEGAL_CUSTOM1", 0x2: "LEGAL_LDH_HINT1", 0x3: "ILL_OPCODE",
        0x4: "ILL_RSVD_FUNCT3", 0x5: "ILL_LDW_IDX", 0x6: "ILL_LH_IDX", 0x7: "ILL_LA_IDX",
        0x8: "ILL_IDX_RS1", 0x9: "ILL_IDX_IMM_HI", 0xA: "ILL_STATUS_IMM"}


def sh(cmd, cwd):
    # xsim/xvlog are .bat wrappers: cmd splits unquoted arguments at '='
    r = subprocess.run(f"call {SETTINGS} >nul && {cmd}", cwd=cwd, capture_output=True, text=True, shell=True)
    return r.returncode, r.stdout + r.stderr


def main():
    subprocess.run([sys.executable, str(ROOT / "model" / "export_vectors.py")], check=True)
    rc, out = sh(f"{SIM / 'run_xsim.bat'} {TOP} elab", SIM)
    if rc != 0 or "Built simulation snapshot" not in out:
        print(out[-3000:]); print("D6.3 FAIL: build"); return 1
    warn = [l for l in out.splitlines() if "WARNING" in l]
    print(f"build ok ({len(warn)} warnings)")
    for l in warn:
        print("  ", l)

    rc, out = sh(f"xsim {TOP}_snap -R --log d63.log", WORK)
    fired = sorted(set(re.findall(r"(a_\w+) violated", out)))
    for l in out.splitlines():
        if l.startswith("TB_ERROR"):
            print(l)
    ok = not warn and not fired
    print("assertions fired:", fired or "none")

    print("Part A by D2 §5.1 category:")
    seen = set()
    for c, tot, pas in re.findall(r"TB_PARTA_CAT (\w+) total=(\d+) pass=(\d+)", out):
        c = int(c, 16); seen.add(c)
        good = tot == pas
        ok &= good
        print(f"  {CATS.get(c, c):16s} {pas:>6}/{tot:<6} {'PASS' if good else 'FAIL'}")
    missing = [CATS[c] for c in CATS if c not in seen]
    if missing:
        print("  missing categories:", missing); ok = False

    m = re.search(r"TB_SUMMARY (.*)", out)
    summ = dict(kv.split("=") for kv in m.group(1).split()) if m else {}
    print("Part B:", m.group(1) if m else "no summary")
    txn_expected = sum(1 for _ in open(SIM / "vectors" / "txn.hex"))
    ok &= bool(summ) and summ["partA_mismatch"] == "0" and summ["tb_errors"] == "0" \
        and int(summ["partB_txn"]) == txn_expected and summ["bridge_cmds"] == summ["cmd_handshakes"]

    # fault injection: a_cmd_wellformed must be live (xsim ignores '->', see rvne_decoder.sv)
    rc, fout = sh(f'xsim {TOP}_snap -R -testplusarg "FAULT=1" --log d63_fault.log', WORK)
    ffired = sorted(set(re.findall(r"(a_\w+) violated", fout)))
    fgood = "a_cmd_wellformed" in ffired and all(a in ("a_cmd_wellformed", "a_cmd_stable") for a in ffired)
    ok &= fgood
    print(f"FAULT=1 (malformed bridge cmd): {'PASS' if fgood else 'FAIL'}  fired {ffired}")

    print("D6.3", "PASS" if ok else "FAIL")
    if ok:
        print("\nre-running D6.2 regression:")
        r = subprocess.run([sys.executable, str(SIM / "run_d62.py")], capture_output=True, text=True)
        tail = [l for l in r.stdout.splitlines() if l.startswith(("MODE", "D6.2", "build"))]
        print("\n".join("  " + l for l in tail))
        ok &= r.returncode == 0
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
