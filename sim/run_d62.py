"""D6.2 exit-criterion runner: rvne_if against D5 issue vectors + X1–X4/DEC-14.

  python sim/run_d62.py

1. Regenerates sim/vectors/issue.hex from the D5 model.
2. Compiles and elaborates tb_rvne_if (xsim, DEC-11).
3. MODE=0 must pass: every vector handshaked, 0 TB errors, no assertion fires.
4. MODE=1..5 must each fire exactly their target assertion and no other one.
"""
import re
import subprocess
import sys
from pathlib import Path

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
WORK = SIM / "work"
SETTINGS = r"C:\Xilinx\Vivado\2022.1\settings64.bat"
TOP = "tb_rvne_if"
ASSERTS = ["a_X1", "a_X2", "a_X3", "a_X4", "a_tieoff"]
EXPECT = {1: "a_X1", 2: "a_X2", 3: "a_X3", 4: "a_X4", 5: "a_tieoff"}


def sh(cmd, cwd):
    # xsim/xvlog are .bat wrappers: cmd splits unquoted arguments at '=', so plusargs must be quoted
    full = f"call {SETTINGS} >nul && {cmd}"
    r = subprocess.run(full, cwd=cwd, capture_output=True, text=True, shell=True)
    return r.returncode, r.stdout + r.stderr


def main():
    subprocess.run([sys.executable, str(ROOT / "model" / "export_vectors.py")], check=True)

    rc, out = sh(f"{SIM / 'run_xsim.bat'} {TOP} elab", SIM)
    if rc != 0 or "Built simulation snapshot" not in out:
        print(out[-3000:])
        print("D6.2 FAIL: build")
        return 1
    warn = [l for l in out.splitlines() if "WARNING" in l]
    print(f"build ok ({len(warn)} warnings)")
    for l in warn:
        print("  ", l)

    ok = True
    for mode in range(6):
        rc, out = sh(f'xsim {TOP}_snap -R -testplusarg "MODE={mode}" --log mode{mode}.log', WORK)
        fired = {a: len(re.findall(rf"\b{a} violated", out)) for a in ASSERTS}
        summ = next((l for l in out.splitlines() if l.startswith("TB_SUMMARY")), "")
        tb_err = int(re.search(r"tb_errors=(\d+)", summ).group(1)) if summ else -1
        if mode == 0:
            m = re.search(r"vectors=(\d+) handshakes=(\d+)", summ)
            passed = bool(m) and m.group(1) == m.group(2) and tb_err == 0 and not any(fired.values())
            detail = f"{summ.removeprefix('TB_SUMMARY ')}"
        else:
            target = EXPECT[mode]
            others = {a: n for a, n in fired.items() if a != target and n}
            passed = fired[target] > 0 and not others
            detail = f"{target} fired x{fired[target]}" + (f"; unexpected {others}" if others else "")
        ok &= passed
        print(f"MODE={mode}: {'PASS' if passed else 'FAIL'}  {detail}")
        if not passed:
            print("\n".join(l for l in out.splitlines() if "Error" in l or "TB_" in l)[:3000])

    print("D6.2", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
