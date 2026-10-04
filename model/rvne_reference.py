"""RVNE-ASYNC Milestone-1 reference model (deliverable D5).

Derived strictly from the frozen Phase-0 specifications:
  D1 docs/architecture.md      parameters (§2), ordering (§6)
  D2 docs/instruction_spec.md  encodings (§2), issue response (§3), semantics (§4),
                               error model (§5), STATUS (§6), completion (§7)
  D3 docs/async_interface.md   bridge command/response bundles and op codes (§3)
  D4 docs/wvr_svr_spec.md      register organisation, element layout, load semantics

This model is independent of the RTL. It models architectural state and the
transaction-level contract only (one instruction at a time, D1 §6); it does not
model timing or handshakes. Where a spec says a value is undefined (SPM after
reset, DEC-13), the model tracks it as UNDEF rather than choosing a value.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

# ----------------------------------------------------------------------------
# D1 §2 parameters
# ----------------------------------------------------------------------------
XLEN = 32
W_BITS = 4
WVR_ENTRY_BITS = 32
N_WVR = 16
SVR_ENTRY_BITS = 32
N_SVR = 16
SPM_BYTES = 16384
SPM_BANKS = 16
SPM_AW = 14

MASK32 = 0xFFFF_FFFF
STATUS_VERSION = 0x01

# Major opcodes (D2 §1)
OPC_CUSTOM0 = 0b0001011  # 0x0B
OPC_CUSTOM1 = 0b0101011  # 0x2B


class _Undef:
    """Marker for an undefined value (D2/D4: SPM not reset, DEC-13)."""

    _inst = None

    def __new__(cls):
        if cls._inst is None:
            cls._inst = super().__new__(cls)
        return cls._inst

    def __repr__(self) -> str:
        return "UNDEF"


UNDEF = _Undef()

# ----------------------------------------------------------------------------
# D2 §1 instruction table: mnemonic -> (opcode, funct3, format)
# ----------------------------------------------------------------------------
INSTRUCTIONS = {
    "lw.wv":       (OPC_CUSTOM0, 0b000, "LDW"),
    "lh.wv":       (OPC_CUSTOM0, 0b001, "LDH"),
    "la.wv":       (OPC_CUSTOM0, 0b010, "LDH"),
    "lw.sv":       (OPC_CUSTOM0, 0b100, "LDW"),
    "lh.sv":       (OPC_CUSTOM0, 0b101, "LDH"),
    "la.sv":       (OPC_CUSTOM0, 0b110, "LDH"),
    "spm.sw":      (OPC_CUSTOM1, 0b000, "S"),
    "rvne.rdwv":   (OPC_CUSTOM1, 0b001, "IDX"),
    "rvne.rdsv":   (OPC_CUSTOM1, 0b010, "IDX"),
    "rvne.status": (OPC_CUSTOM1, 0b011, "IDX"),
    "spm.lw":      (OPC_CUSTOM1, 0b100, "I"),
}
_BY_OPC_F3 = {(o, f): m for m, (o, f, _) in INSTRUCTIONS.items()}

# D3 §3.2 bridge op codes
BRIDGE_OP = {
    "spm.sw": 0x0, "spm.lw": 0x1,
    "lw.wv": 0x2, "lh.wv": 0x3, "la.wv": 0x4,
    "lw.sv": 0x5, "lh.sv": 0x6, "la.sv": 0x7,
    "rvne.rdwv": 0x8, "rvne.rdsv": 0x9,
}

# Access size in bytes / number of entries written, per load (D1 §2, D4 §3)
_LOAD_WORDS = {"lw": 1, "lh": 4, "la": 16}


# ----------------------------------------------------------------------------
# Bit helpers
# ----------------------------------------------------------------------------
def _bits(w: int, hi: int, lo: int) -> int:
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def _sext12(v: int) -> int:
    return v - 0x1000 if v & 0x800 else v


def _imm12(v: int) -> int:
    if not -2048 <= v <= 2047:
        raise ValueError(f"immediate {v} does not fit in 12 signed bits")
    return v & 0xFFF


# ----------------------------------------------------------------------------
# D2 §2 encoder / field decoder
# ----------------------------------------------------------------------------
def encode(mnemonic: str, *, idx: int = 0, rd: int = 0, rs1: int = 0,
           rs2: int = 0, imm: int = 0, hint: int = 0) -> int:
    """Encode one RVNE instruction (D2 §2).

    Loads: idx, rs1, imm, hint (LDH only). spm.sw: rs2, rs1, imm.
    spm.lw: rd, rs1, imm. rvne.rdwv/rdsv: rd, idx. rvne.status: rd, imm=clr.
    Field-width checks only; legality (e.g. lh idx % 4) is NOT enforced here so
    that illegal encodings can be generated for negative tests.
    """
    opc, f3, fmt = INSTRUCTIONS[mnemonic]
    if fmt == "LDW":
        if not 0 <= idx < 32:
            raise ValueError("LDW idx is 5 bits")
        return (_imm12(imm) << 20) | (rs1 << 15) | (f3 << 12) | (idx << 7) | opc
    if fmt == "LDH":
        if not 0 <= idx < 16 or hint not in (0, 1):
            raise ValueError("LDH idx is 4 bits, hint is 1 bit")
        return (_imm12(imm) << 20) | (rs1 << 15) | (f3 << 12) | (hint << 11) | (idx << 7) | opc
    if fmt == "S":
        i = _imm12(imm)
        return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1F) << 7) | opc
    if fmt == "I":
        return (_imm12(imm) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
    if fmt == "IDX":
        field_val = imm if mnemonic == "rvne.status" else idx
        return (_imm12(field_val) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
    raise AssertionError(fmt)


@dataclass(frozen=True)
class Decoded:
    """Fields of an instruction word, interpreted per its D2 §2 format."""
    word: int
    mnemonic: Optional[str]   # None: reserved funct3 or not custom-0/1
    fmt: Optional[str]
    rs1: int
    rs2: int
    rd: int
    idx: int                  # LDW: [11:7]; LDH: [10:7]; IDX: imm[3:0]
    hint: int
    imm: int                  # sign-extended immediate (I/S/LDW/LDH), raw for IDX


def decode(word: int) -> Decoded:
    word &= MASK32
    opc, f3 = _bits(word, 6, 0), _bits(word, 14, 12)
    m = _BY_OPC_F3.get((opc, f3))
    fmt = INSTRUCTIONS[m][2] if m else None
    rs1, rs2, rd = _bits(word, 19, 15), _bits(word, 24, 20), _bits(word, 11, 7)
    if fmt == "S":
        imm = _sext12((_bits(word, 31, 25) << 5) | _bits(word, 11, 7))
    elif fmt == "IDX":
        imm = _bits(word, 31, 20)
    else:
        imm = _sext12(_bits(word, 31, 20))
    if fmt == "LDH":
        idx, hint = _bits(word, 10, 7), _bits(word, 11, 11)
    elif fmt == "LDW":
        idx, hint = _bits(word, 11, 7), 0
    elif fmt == "IDX":
        idx, hint = _bits(word, 23, 20), 0
    else:
        idx, hint = 0, 0
    return Decoded(word, m, fmt, rs1, rs2, rd, idx, hint, imm)


# ----------------------------------------------------------------------------
# D2 §3 / §5.1 issue-time decision (instruction word only)
# ----------------------------------------------------------------------------
@dataclass(frozen=True)
class IssueResp:
    accept: bool
    register_read: tuple   # subset of ("rs1", "rs2")
    writeback: bool


_REJECT = IssueResp(False, (), False)


def issue(word: int) -> IssueResp:
    """CV-X-IF issue response; depends on the instruction word only (D2 §5.1)."""
    d = decode(word)
    m = d.mnemonic
    if m is None:
        return _REJECT
    if d.fmt == "LDW" and d.idx >= 16:                 # idx[4] = 1
        return _REJECT
    if m in ("lh.wv", "lh.sv") and d.idx % 4 != 0:
        return _REJECT
    if m in ("la.wv", "la.sv") and d.idx != 0:
        return _REJECT
    if d.fmt == "IDX":
        if d.rs1 != 0 or _bits(word, 31, 24) != 0:     # imm[11:4] must be 0
            return _REJECT
        if m == "rvne.status" and _bits(word, 23, 21) != 0:  # imm[3:1] must be 0
            return _REJECT
    if d.fmt in ("LDW", "LDH"):
        return IssueResp(True, ("rs1",), False)
    if m == "spm.sw":
        return IssueResp(True, ("rs1", "rs2"), False)
    if m == "spm.lw":
        return IssueResp(True, ("rs1",), True)
    return IssueResp(True, (), True)                   # rvne.rdwv / rdsv / status


# ----------------------------------------------------------------------------
# Transaction outcome
# ----------------------------------------------------------------------------
@dataclass(frozen=True)
class BridgeCmd:
    """D3 §3.1 command bundle (only legal, operand-checked commands)."""
    op: int
    idx: int
    addr: int
    wdata: int


@dataclass(frozen=True)
class Result:
    """CV-X-IF result transaction (D2 §7)."""
    we: bool
    rd: int
    data: object   # int, or UNDEF when reading undefined SPM-derived state


@dataclass(frozen=True)
class Outcome:
    issue: IssueResp
    bridge: Optional[BridgeCmd]          # None: bridge not used
    bridge_rdata: object                 # D3 rsp_rdata for that command (0 if unused)
    result: Optional[Result]             # None iff not accepted


# ----------------------------------------------------------------------------
# Architectural state and execution (D2 §4, §5.2, §6; D4 §3)
# ----------------------------------------------------------------------------
@dataclass
class RvneState:
    spm: list = field(default_factory=lambda: [UNDEF] * SPM_BYTES)   # bytes, DEC-13
    wvr: list = field(default_factory=lambda: [0] * N_WVR)
    svr: list = field(default_factory=lambda: [0] * N_SVR)
    err_align: int = 0
    err_range: int = 0
    last_err_op: int = 0

    # -- reset (D3 §6 R2/R3): WVR, SVR, STATUS reset; SPM unchanged -----------
    def reset(self) -> None:
        self.wvr = [0] * N_WVR
        self.svr = [0] * N_SVR
        self.err_align = self.err_range = self.last_err_op = 0

    # -- STATUS (D2 §6) -------------------------------------------------------
    @property
    def status(self) -> int:
        return ((STATUS_VERSION << 24) | ((self.last_err_op & 0xF) << 8)
                | (self.err_range << 1) | self.err_align)

    # -- SPM word access (little-endian, D1 §2) -------------------------------
    def spm_word(self, a: int):
        b = self.spm[a:a + 4]
        if any(x is UNDEF for x in b):
            return UNDEF
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)

    def _spm_store(self, a: int, v: int) -> None:
        for k in range(4):
            self.spm[a + k] = (v >> (8 * k)) & 0xFF

    def _check_ea(self, mnemonic: str, ea: int, align: int) -> bool:
        """D2 §5.2: alignment first, then range; set sticky bits on failure."""
        if ea % align != 0:
            self.err_align = 1
        elif ea >= SPM_BYTES:
            self.err_range = 1
        else:
            return True
        self.last_err_op = BRIDGE_OP[mnemonic]
        return False

    # -- one instruction ------------------------------------------------------
    def step(self, word: int, rs1: int = 0, rs2: int = 0) -> Outcome:
        """Execute one offloaded instruction.

        rs1/rs2 are the GPR operand values CV32A60X supplies with the issue
        (D3 §2); they are ignored unless the instruction reads them.
        """
        resp = issue(word)
        if not resp.accept:
            return Outcome(resp, None, 0, None)          # CVA6 raises illegal-instr
        d = decode(word)
        m = d.mnemonic
        rs1 &= MASK32
        rs2 &= MASK32

        if m == "rvne.status":                           # decoder-only, no bridge
            value = self.status
            if d.imm & 1:
                self.err_align = self.err_range = 0
            return Outcome(resp, None, 0, Result(True, d.rd, value))

        if m in ("rvne.rdwv", "rvne.rdsv"):
            reg = self.wvr if m == "rvne.rdwv" else self.svr
            data = reg[d.idx]
            cmd = BridgeCmd(BRIDGE_OP[m], d.idx, 0, 0)
            return Outcome(resp, cmd, data, Result(True, d.rd, data))

        ea = (rs1 + d.imm) & MASK32

        if m == "spm.sw":
            if not self._check_ea(m, ea, 4):
                return Outcome(resp, None, 0, Result(False, 0, 0))
            self._spm_store(ea, rs2)
            cmd = BridgeCmd(BRIDGE_OP[m], 0, ea & ((1 << SPM_AW) - 1), rs2)
            return Outcome(resp, cmd, 0, Result(False, 0, 0))

        if m == "spm.lw":
            if not self._check_ea(m, ea, 4):
                return Outcome(resp, None, 0, Result(True, d.rd, 0))
            data = self.spm_word(ea)
            cmd = BridgeCmd(BRIDGE_OP[m], 0, ea & ((1 << SPM_AW) - 1), 0)
            return Outcome(resp, cmd, data, Result(True, d.rd, data))

        # vector loads (D2 §4.1, D4 §3)
        gran, target = m.split(".")
        nwords = _LOAD_WORDS[gran]
        if not self._check_ea(m, ea, 4 * nwords):
            return Outcome(resp, None, 0, Result(False, 0, 0))
        reg = self.wvr if target == "wv" else self.svr
        for k in range(nwords):
            reg[d.idx + k] = self.spm_word(ea + 4 * k)
        cmd = BridgeCmd(BRIDGE_OP[m], d.idx, ea & ((1 << SPM_AW) - 1), 0)
        return Outcome(resp, cmd, 0, Result(False, 0, 0))


# ----------------------------------------------------------------------------
# D4 §2 element interpretation
# ----------------------------------------------------------------------------
def weight(entry: int, j: int, w_bits: int = W_BITS) -> int:
    """Signed weight j of a WVR entry."""
    v = (entry >> (w_bits * j)) & ((1 << w_bits) - 1)
    return v - (1 << w_bits) if v >> (w_bits - 1) else v


def weights(wvr: list, w_bits: int = W_BITS) -> list:
    """All weights in global index order n = i*(32/W_BITS) + j."""
    per = WVR_ENTRY_BITS // w_bits
    return [weight(wvr[i], j, w_bits) for i in range(len(wvr)) for j in range(per)]


def fired_neurons(svr: list) -> list:
    """Input-neuron indices 32*i + j with SVR[i][j] = 1."""
    return [32 * i + j for i, e in enumerate(svr) for j in range(32) if (e >> j) & 1]


if __name__ == "__main__":
    import subprocess
    import sys
    from pathlib import Path
    sys.exit(subprocess.call([sys.executable,
                              str(Path(__file__).with_name("test_rvne_reference.py"))]))
