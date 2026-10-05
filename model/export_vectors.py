"""Export D5 reference-model results as xsim vector files (rtl_module_spec.md §5).

Serialisation only: every expected value written here is computed by
rvne_reference; this script adds no behaviour.

  python model/export_vectors.py [outdir]      (default: sim/vectors)

issue.hex — one line per instruction word, all fields hex:
    <instr:8> <accept:1> <writeback:1> <register_read:1> <category:x>
  register_read bit 0 = rs1, bit 1 = rs2 (CV-X-IF readregflags_t order).
  category is a coverage label derived *independently* from the D2 §5.1 rule
  text (CATEGORIES below) and cross-checked against issue(): a disagreement
  aborts the export.

txn.hex — one line per instruction of a deterministic program, all fields hex:
    <instr> <rs1> <rs2> <accept> <has_cmd> <op> <idx> <addr> <wdata> <rsp_rdata>
    <has_result> <we> <rd> <data> <status_after>
  rsp_rdata is what the bridge must return for that command (D3 rsp_rdata).
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from rvne_reference import (  # noqa: E402
    OPC_CUSTOM0, OPC_CUSTOM1, SPM_BYTES, UNDEF, RvneState, encode, issue,
)

# ---------------------------------------------------------------- categories (D2 §5.1 wording)
CATEGORIES = {
    0x0: "LEGAL_CUSTOM0",
    0x1: "LEGAL_CUSTOM1",
    0x2: "LEGAL_LDH_HINT1",       # legal custom-0 LDH with hint = 1 (hint is ignored)
    0x3: "ILL_OPCODE",            # not custom-0 / custom-1
    0x4: "ILL_RSVD_FUNCT3",       # custom-0 011/111, custom-1 101/110/111
    0x5: "ILL_LDW_IDX",           # lw.* idx[4] = 1
    0x6: "ILL_LH_IDX",            # lh.* idx % 4 != 0
    0x7: "ILL_LA_IDX",            # la.* idx != 0
    0x8: "ILL_IDX_RS1",           # IDX format with rs1 != 0
    0x9: "ILL_IDX_IMM_HI",        # IDX format with imm[11:4] != 0
    0xA: "ILL_STATUS_IMM",        # rvne.status with imm[3:1] != 0
}


def category(w):
    """Classify by D2 §5.1 rule text, without calling the model."""
    opc, f3 = w & 0x7F, (w >> 12) & 7
    f117, rs1, imm = (w >> 7) & 0x1F, (w >> 15) & 0x1F, (w >> 20) & 0xFFF
    if opc == OPC_CUSTOM0:
        if f3 in (0b011, 0b111):
            return 0x4
        if f3 in (0b000, 0b100):
            return 0x5 if f117 & 0x10 else 0x0
        idx, hint = f117 & 0xF, f117 >> 4
        if f3 in (0b001, 0b101) and idx % 4:
            return 0x6
        if f3 in (0b010, 0b110) and idx:
            return 0x7
        return 0x2 if hint else 0x0
    if opc == OPC_CUSTOM1:
        if f3 in (0b101, 0b110, 0b111):
            return 0x4
        if f3 in (0b001, 0b010, 0b011):
            if rs1:
                return 0x8
            if imm >> 4:
                return 0x9
            if f3 == 0b011 and (imm >> 1) & 0x7:
                return 0xA
        return 0x1
    return 0x3


# ---------------------------------------------------------------- issue.hex
DOCUMENTED = [
    0x0105018B, 0x0405120B, 0x0400200B, 0x1000410B, 0x0005D40B, 0x0005E00B,
    0x04051A0B, 0x0465022B, 0x044543AB, 0x001012AB, 0x002022AB, 0x001032AB,
    0x0000300B, 0x0000700B, 0x0000502B, 0x0000602B, 0x0000702B,
    encode("lw.wv", idx=16), encode("lh.wv", idx=5), encode("la.wv", idx=4),
    encode("rvne.rdwv", rd=1, rs1=3), encode("rvne.rdsv", rd=1) | (1 << 24),
    encode("rvne.status", rd=1, imm=2), 0x00000013,
]
SWEEP_OPCODES = [OPC_CUSTOM0, OPC_CUSTOM1, 0b0010011, 0b0110011, 0b1011011, 0b1111011]
SWEEP_RS1 = [0, 1, 31]
SWEEP_IMM = [0x000, 0x001, 0x002, 0x00E, 0x00F, 0x010, 0x0FF, 0x100, 0x800, 0xFFF]


def sweep():
    for opc in SWEEP_OPCODES:
        for f3 in range(8):
            for f117 in range(32):
                for rs1 in SWEEP_RS1:
                    for imm in SWEEP_IMM:
                        yield (imm << 20) | (rs1 << 15) | (f3 << 12) | (f117 << 7) | opc


def issue_lines(words):
    seen = set()
    for w in words:
        if w in seen:
            continue
        seen.add(w)
        r = issue(w)
        cat = category(w)
        if r.accept != (cat <= 0x2):
            raise SystemExit(f"category/model disagreement on {w:08x}: cat {CATEGORIES[cat]}, accept {r.accept}")
        rr = (1 if "rs1" in r.register_read else 0) | (2 if "rs2" in r.register_read else 0)
        yield f"{w:08x} {int(r.accept):x} {int(r.writeback):x} {rr:x} {cat:x}"


# ---------------------------------------------------------------- txn.hex
def txn_program(seed=0x5EED):
    """Deterministic instruction stream: (word, rs1_value, rs2_value)."""
    rng = random.Random(seed)
    prog = []
    # 1. fully initialise the SPM (DEC-13: undefined after reset)
    for a in range(0, SPM_BYTES, 4):
        prog.append((encode("spm.sw", rs1=1, rs2=2), a, rng.getrandbits(32)))
    # 2. D2 §8 software example
    for a in range(0x7C, 0x3C, -4):
        prog.append((encode("spm.sw", rs1=11, rs2=0), a, 0))
    prog += [(encode("spm.sw", rs1=10, rs2=6, imm=0), 0x40, 0x76543210),
             (encode("spm.sw", rs1=10, rs2=6, imm=4), 0x40, 0xFEDCBA98),
             (encode("spm.sw", rs1=10, rs2=6, imm=60), 0x40, 0x80000001),
             (encode("la.wv", idx=0, rs1=10), 0x40, 0),
             (encode("rvne.rdwv", rd=5, idx=1), 0, 0),
             (encode("rvne.status", rd=7, imm=1), 0, 0)]
    # 3. D4 V5-style operand errors, then status read/clear
    prog += [(encode("lh.wv", idx=4, rs1=1), 0x44, 0),
             (encode("la.sv", idx=0, rs1=12), 0x4000, 0),
             (encode("spm.lw", rd=9, rs1=1, imm=1), 0, 0),
             (encode("rvne.status", rd=3, imm=0), 0, 0),
             (encode("rvne.status", rd=3, imm=1), 0, 0),
             (encode("rvne.status", rd=3, imm=0), 0, 0),
             (encode("lw.wv", idx=1, rs1=1, imm=0x50), 0xFFFFFFF0, 0),   # 32-bit EA wrap -> 0x40
             (encode("lh.wv", idx=5), 0, 0)]                            # rejected at issue
    # 4. random mix
    loads = [("lw", 4, 1), ("lh", 16, 4), ("la", 64, 16)]
    for _ in range(4000):
        r = rng.random()
        if r < 0.45:
            g, al, n = rng.choice(loads)
            m = f"{g}.{rng.choice(['wv', 'sv'])}"
            idx = 0 if g == "la" else (rng.randrange(0, 16, 4) if g == "lh" else rng.randrange(16))
            word = encode(m, idx=idx, rs1=rng.randrange(32), imm=rng.choice([0, 0, al, -al, 4, 0x7C0]),
                          hint=rng.getrandbits(1) if g != "lw" else 0)
            base = _addr(rng, al)
        elif r < 0.65:
            word = encode("spm.sw", rs1=rng.randrange(32), rs2=rng.randrange(32), imm=rng.choice([0, 4, -4, 0x10]))
            base = _addr(rng, 4)
        elif r < 0.75:
            word = encode("spm.lw", rd=rng.randrange(32), rs1=rng.randrange(32), imm=rng.choice([0, 4, -4, 2]))
            base = _addr(rng, 4)
        elif r < 0.87:
            word = encode(rng.choice(["rvne.rdwv", "rvne.rdsv"]), rd=rng.randrange(32), idx=rng.randrange(16))
            base = 0
        elif r < 0.93:
            word = encode("rvne.status", rd=rng.randrange(32), imm=rng.getrandbits(1))
            base = 0
        else:                                   # illegal encodings must stay rejected mid-stream
            word = rng.choice([0x0000300B, 0x0000702B, encode("lw.sv", idx=17), encode("la.sv", idx=8),
                               encode("rvne.rdwv", rd=1, rs1=4), 0x00000013])
            base = rng.getrandbits(32)
        prog.append((word, base, rng.getrandbits(32)))
    return prog


def _addr(rng, align):
    r = rng.random()
    if r < 0.75:
        return rng.randrange(0, SPM_BYTES, align)                  # legal
    if r < 0.85:
        return rng.randrange(0, SPM_BYTES, 4) | rng.choice([1, 2, 3, align // 2 if align > 4 else 1])  # misaligned
    if r < 0.95:
        return rng.choice([SPM_BYTES, SPM_BYTES + align, 0x8000, 0xFFFFFFC0, 0x7FFFFFC0])  # out of range
    return SPM_BYTES - align                                      # last legal slot


def txn_lines(prog):
    s = RvneState()
    for word, rs1, rs2 in prog:
        o = s.step(word, rs1=rs1, rs2=rs2)
        b = o.bridge
        if o.bridge_rdata is UNDEF or (o.result and o.result.data is UNDEF):
            raise SystemExit("txn program reads undefined SPM state; initialise it first")
        res = o.result
        yield " ".join(f"{v:x}" for v in [
            word, rs1 & 0xFFFFFFFF, rs2 & 0xFFFFFFFF, int(o.issue.accept),
            int(b is not None), b.op if b else 0, b.idx if b else 0, b.addr if b else 0, b.wdata if b else 0,
            o.bridge_rdata if b else 0,
            int(res is not None), int(res.we) if res else 0, res.rd if res else 0, res.data if res else 0,
            s.status])


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent.parent / "sim" / "vectors"
    out.mkdir(parents=True, exist_ok=True)

    lines = list(issue_lines(list(DOCUMENTED) + list(sweep())))
    (out / "issue.hex").write_text("\n".join(lines) + "\n")
    counts = {}
    for l in lines:
        c = int(l.split()[4], 16)
        counts[c] = counts.get(c, 0) + 1
    missing = [CATEGORIES[c] for c in CATEGORIES if c not in counts]
    if missing:
        raise SystemExit(f"issue.hex missing categories: {missing}")
    print(f"issue.hex: {len(lines)} vectors; " + ", ".join(f"{CATEGORIES[c]}={counts[c]}" for c in sorted(counts)))

    tl = list(txn_lines(txn_program()))
    (out / "txn.hex").write_text("\n".join(tl) + "\n")
    f = [l.split() for l in tl]
    print(f"txn.hex: {len(tl)} instructions; accepted={sum(x[3] == '1' for x in f)} "
          f"bridge_cmds={sum(x[4] == '1' for x in f)} "
          f"operand_errors={sum(x[3] == '1' and x[4] == '0' and int(x[0], 16) & 0x707F != 0x302B for x in f)}")


if __name__ == "__main__":
    main()
