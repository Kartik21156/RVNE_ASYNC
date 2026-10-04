"""Self-test of the D5 reference model against the concrete examples in D2–D4.

Run:  python model/test_rvne_reference.py      (also collectable by pytest)
Every expected value below is quoted from a frozen spec section, cited inline.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from rvne_reference import (  # noqa: E402
    BRIDGE_OP, INSTRUCTIONS, N_WVR, SPM_BYTES, UNDEF, BridgeCmd, RvneState,
    decode, encode, fired_neurons, issue, weight, weights,
)


def fresh():
    """Reset state with SPM row 1 zeroed (D4 §6 initial state)."""
    s = RvneState()
    for a in range(0x40, 0x80, 4):
        s.step(encode("spm.sw", rs1=0, rs2=0, imm=a))
    return s


def d4_initial():
    s = fresh()
    for a, v in [(0x40, 0x76543210), (0x44, 0xFEDCBA98), (0x7C, 0x80000001), (0x100, 0x00008001)]:
        s.step(encode("spm.sw", rs1=10, rs2=6, imm=0), rs1=a, rs2=v)
    return s


# --- D2 §1/§2 -----------------------------------------------------------------
def test_no_opcode_funct3_overlap():
    keys = [(o, f) for o, f, _ in INSTRUCTIONS.values()]
    assert len(keys) == len(set(keys))


def test_ldh_ldw_fields_tile_32_bits():
    # D2 §2 bit-position table
    for fields in ([(31, 20), (19, 15), (14, 12), (11, 7), (6, 0)],            # LDW
                   [(31, 20), (19, 15), (14, 12), (11, 11), (10, 7), (6, 0)]):  # LDH
        bits = sorted(b for h, l in fields for b in range(l, h + 1))
        assert bits == list(range(32))


def test_d2_example_encodings():
    # D2 §2.2
    table = [
        (encode("lw.wv", idx=3, rs1=10, imm=0x10), 0x0105018B),
        (encode("lh.wv", idx=4, rs1=10, imm=0x40), 0x0405120B),
        (encode("la.wv", idx=0, rs1=0, imm=0x40), 0x0400200B),
        (encode("lw.sv", idx=2, rs1=0, imm=0x100), 0x1000410B),
        (encode("lh.sv", idx=8, rs1=11, imm=0), 0x0005D40B),
        (encode("la.sv", idx=0, rs1=11, imm=0), 0x0005E00B),
        (encode("lh.wv", idx=4, rs1=10, imm=0x40, hint=1), 0x04051A0B),
        (encode("spm.sw", rs1=10, rs2=6, imm=0x44), 0x0465022B),
        (encode("spm.lw", rd=7, rs1=10, imm=0x44), 0x044543AB),
        (encode("rvne.rdwv", rd=5, idx=1), 0x001012AB),
        (encode("rvne.rdsv", rd=5, idx=2), 0x002022AB),
        (encode("rvne.status", rd=5, imm=1), 0x001032AB),
    ]
    for got, want in table:
        assert got == want, (hex(got), hex(want))
        assert decode(got).mnemonic is not None


def test_decode_round_trip_fields():
    d = decode(0x04051A0B)
    assert (d.mnemonic, d.imm, d.rs1, d.hint, d.idx) == ("lh.wv", 0x40, 10, 1, 4)
    d = decode(0x0465022B)
    assert (d.mnemonic, d.imm, d.rs1, d.rs2) == ("spm.sw", 0x44, 10, 6)
    assert decode(encode("lw.wv", idx=0, rs1=1, imm=-4)).imm == -4


# --- D2 §3 / §5.1 issue decisions --------------------------------------------
def test_issue_response_table():
    # D2 §3
    r = issue(encode("lw.wv", idx=0))
    assert (r.accept, r.register_read, r.writeback) == (True, ("rs1",), False)
    r = issue(encode("spm.sw"))
    assert (r.accept, r.register_read, r.writeback) == (True, ("rs1", "rs2"), False)
    r = issue(encode("spm.lw", rd=1))
    assert (r.accept, r.register_read, r.writeback) == (True, ("rs1",), True)
    for m in ("rvne.rdwv", "rvne.rdsv", "rvne.status"):
        r = issue(encode(m, rd=1))
        assert (r.accept, r.register_read, r.writeback) == (True, (), True)


def test_issue_rejections():
    # D2 §5.1
    rejected = [
        0x0000300B,                                   # custom-0 funct3 011 reserved
        0x0000700B,                                   # custom-0 funct3 111 reserved
        0x0000502B, 0x0000602B, 0x0000702B,           # custom-1 funct3 101/110/111
        encode("lw.wv", idx=16), encode("lw.sv", idx=31),     # idx[4] = 1
        encode("lh.wv", idx=5), encode("lh.sv", idx=2),       # idx % 4 != 0
        encode("la.wv", idx=4), encode("la.sv", idx=1),       # la idx != 0
        encode("rvne.rdwv", rd=1, idx=0, rs1=3),              # IDX rs1 != 0
        encode("rvne.rdsv", rd=1, idx=0) | (1 << 24),         # IDX imm[4] != 0
        encode("rvne.status", rd=1, imm=2),                   # status imm[1] != 0
        0x00000013,                                   # addi (not custom-0/1)
    ]
    for w in rejected:
        assert not issue(w).accept, hex(w)
    # hint is ignored: any value accepted (D2 §4.1)
    assert issue(encode("lh.wv", idx=4, hint=1)).accept
    assert issue(encode("la.sv", idx=0, hint=1)).accept


def test_rejected_instruction_has_no_effect():
    s = d4_initial()
    before = (list(s.wvr), list(s.svr), s.status)
    out = s.step(encode("lh.wv", idx=5, imm=0x40))
    assert out.result is None and out.bridge is None
    assert (list(s.wvr), list(s.svr), s.status) == before


# --- D4 §6 worked vectors -----------------------------------------------------
def test_v1_la_wv():
    s = d4_initial()
    out = s.step(encode("la.wv", idx=0, rs1=0, imm=0x40))
    assert s.wvr[0] == 0x76543210 and s.wvr[1] == 0xFEDCBA98
    assert all(s.wvr[i] == 0 for i in range(2, 15)) and s.wvr[15] == 0x80000001
    w = weights(s.wvr)
    assert w[0:8] == list(range(8)) and w[8:16] == list(range(-8, 0))
    assert w[120] == 1 and all(x == 0 for x in w[121:127]) and w[127] == -8
    assert all(x == 0 for x in w[16:120])
    assert out.bridge == BridgeCmd(0x4, 0, 0x040, 0)
    assert out.result.we is False


def test_v2_lh_wv():
    s = d4_initial()
    s.step(encode("lh.wv", idx=4, imm=0x40))
    assert s.wvr[4:8] == [0x76543210, 0xFEDCBA98, 0, 0]
    assert all(s.wvr[i] == 0 for i in range(N_WVR) if not 4 <= i < 8)


def test_v3_lw_sv():
    s = d4_initial()
    s.step(encode("lw.sv", idx=2, imm=0x100))
    assert s.svr[2] == 0x00008001
    assert fired_neurons(s.svr) == [64, 79]
    assert all(e == 0 for e in s.wvr)


def test_v4_lw_wv_after_v1():
    s = d4_initial()
    s.step(encode("la.wv", idx=0, imm=0x40))
    v1 = list(s.wvr)
    s.step(encode("lw.wv", idx=3, imm=0x44))
    assert s.wvr[3] == 0xFEDCBA98
    assert [e for i, e in enumerate(s.wvr) if i != 3] == [e for i, e in enumerate(v1) if i != 3]


def test_v5_error_cases():
    s = d4_initial()
    s.step(encode("la.wv", idx=0, imm=0x40))
    v1_wvr, v1_svr = list(s.wvr), list(s.svr)
    out = s.step(encode("lh.wv", idx=4, imm=0x44))
    assert s.err_align == 1 and s.last_err_op == BRIDGE_OP["lh.wv"] == 0x3
    assert out.bridge is None and out.result.we is False and s.wvr == v1_wvr
    out = s.step(encode("la.sv", idx=0, rs1=12, imm=0), rs1=0x4000)
    assert s.err_range == 1 and out.bridge is None and s.svr == v1_svr
    assert issue(encode("lh.wv", idx=5, imm=0x40)).accept is False
    assert issue(encode("lw.wv", idx=16, imm=0x40)).accept is False


def test_w_bits_8_interpretation():
    # D4 §2
    assert [weight(0x76543210, j, 8) for j in range(4)] == [0x10, 0x32, 0x54, 0x76]


# --- D2 §5.2 / §6 STATUS ------------------------------------------------------
def test_reset_status_value():
    assert RvneState().status == 0x01000000


def test_align_takes_precedence_over_range():
    s = RvneState()
    s.step(encode("lw.wv", idx=0, rs1=1), rs1=0x4002)    # misaligned AND out of range
    assert (s.err_align, s.err_range) == (1, 0)


def test_status_read_then_clear():
    s = RvneState()
    s.step(encode("spm.lw", rd=1, rs1=1), rs1=0x8000)    # range error
    out = s.step(encode("rvne.status", rd=7, imm=1))
    assert out.result.data == 0x01000002 | (BRIDGE_OP["spm.lw"] << 8)   # pre-clear value
    assert out.bridge is None                             # decoder-only (D3 §2)
    assert (s.err_align, s.err_range) == (0, 0)
    assert s.last_err_op == BRIDGE_OP["spm.lw"]           # LAST_ERR_OP is not cleared
    assert s.step(encode("rvne.status", rd=7, imm=0)).result.data == 0x01000100


def test_spm_lw_error_returns_zero():
    s = RvneState()
    out = s.step(encode("spm.lw", rd=9, rs1=1, imm=1), rs1=0)
    assert out.result == type(out.result)(True, 9, 0) and s.err_align == 1


def test_ea_is_32_bit_wraparound():
    # D2 §2: EA computed in 32 bits; 0xFFFFFFF0 + 0x10 wraps to 0, which is legal
    s = fresh()
    s.step(encode("spm.sw", rs1=1, rs2=2), rs1=0x40, rs2=0x12345678)
    out = s.step(encode("lw.wv", idx=1, rs1=1, imm=0x50), rs1=0xFFFFFFF0)
    assert out.bridge.addr == 0x40 and s.wvr[1] == 0x12345678
    assert s.status == 0x01000000


def test_ea_upper_boundary():
    s = RvneState()
    s.step(encode("spm.sw", rs1=1, rs2=2), rs1=SPM_BYTES - 4, rs2=0xA5A5A5A5)
    assert s.err_range == 0 and s.spm_word(SPM_BYTES - 4) == 0xA5A5A5A5
    s.step(encode("spm.sw", rs1=1, rs2=2), rs1=SPM_BYTES, rs2=1)
    assert s.err_range == 1


# --- D2 §8 software example, D3 §7 traces ------------------------------------
def test_d2_software_example():
    s = RvneState()
    x10 = 0x40
    for x11 in range(0x7C, 0x3C, -4):                    # zeroing loop
        s.step(encode("spm.sw", rs1=11, rs2=0, imm=0), rs1=x11, rs2=0)
    s.step(encode("spm.sw", rs1=10, rs2=6, imm=0), rs1=x10, rs2=0x76543210)
    s.step(encode("spm.sw", rs1=10, rs2=6, imm=4), rs1=x10, rs2=0xFEDCBA98)
    s.step(encode("spm.sw", rs1=10, rs2=6, imm=60), rs1=x10, rs2=0x80000001)
    s.step(encode("la.wv", idx=0, rs1=10, imm=0), rs1=x10)
    r = s.step(encode("rvne.rdwv", rd=5, idx=1)).result
    assert (r.we, r.rd, r.data) == (True, 5, 0xFEDCBA98)
    r = s.step(encode("rvne.status", rd=7, imm=1)).result
    assert (r.rd, r.data) == (7, 0x01000000)


def test_d3_trace_bridge_bundles():
    s = fresh()
    # 7.1 lw.wv 3, 0x10(x10), x10 = 0x100 -> EA 0x110
    s.step(encode("spm.sw", rs1=1, rs2=2), rs1=0x110, rs2=0xCAFEF00D)
    out = s.step(0x0105018B, rs1=0x100)
    assert out.bridge == BridgeCmd(0x2, 3, 0x0110, 0) and s.wvr[3] == 0xCAFEF00D
    assert (0x110 >> 6, (0x110 >> 2) & 0xF) == (0x04, 4)            # row 4, bank 4
    # 7.3 spm.sw x6, 0x44(x10), x10 = 0, x6 = 0xDEADBEEF
    out = s.step(encode("spm.sw", rs1=10, rs2=6, imm=0x44), rs1=0, rs2=0xDEADBEEF)
    assert out.bridge == BridgeCmd(0x0, 0, 0x0044, 0xDEADBEEF)
    # 7.4 rvne.rdwv x5, 1
    s.wvr[1] = 0x0BADC0DE
    out = s.step(encode("rvne.rdwv", rd=5, idx=1))
    assert out.bridge == BridgeCmd(0x8, 1, 0, 0) and out.bridge_rdata == 0x0BADC0DE
    assert (out.result.rd, out.result.we, out.result.data) == (5, True, 0x0BADC0DE)


# --- DEC-13 undefined SPM -----------------------------------------------------
def test_undefined_spm_propagates():
    s = RvneState()
    s.step(encode("lw.sv", idx=0, imm=0x200))
    assert s.svr[0] is UNDEF
    assert s.step(encode("rvne.rdsv", rd=1, idx=0)).result.data is UNDEF
    assert s.step(encode("spm.lw", rd=1, rs1=1), rs1=0x300).result.data is UNDEF


def test_reset_preserves_spm():
    s = d4_initial()
    s.step(encode("la.wv", idx=0, imm=0x40))
    s.reset()
    assert all(e == 0 for e in s.wvr) and s.spm_word(0x40) == 0x76543210


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_")]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS  {name}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  {name}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
