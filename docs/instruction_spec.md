# D2 — RVNE Instruction Specification (Milestone 1 subset)

**Status:** Frozen — Phase 0 baseline (2026-10-05). Changes only via a new entry in [decisions.md](decisions.md).
**Depends on:** [architecture.md](architecture.md) §2 for all parameter values · [wvr_svr_spec.md](wvr_svr_spec.md) for exact register effects
**Host interface:** CV-X-IF (OpenHW Core-V eXtension Interface). The CV-X-IF version is pinned in [decisions.md](decisions.md) (DEC-03).

---

## 1. Instruction summary

| Mnemonic | Opcode | funct3 | Format | Effect | GPR write |
|---|---|---|---|---|---|
| `lw.wv  idx, imm(rs1)` | custom-0 | 000 | LDW | WVR[idx] ← SPM word at EA (32 b) | no |
| `lh.wv  idx, imm(rs1)` | custom-0 | 001 | LDH | WVR[idx..idx+3] ← 4 words at EA (128 b) | no |
| `la.wv  0,   imm(rs1)` | custom-0 | 010 | LDH | WVR[0..15] ← 16 words at EA (512 b) | no |
| `lw.sv  idx, imm(rs1)` | custom-0 | 100 | LDW | SVR[idx] ← SPM word at EA | no |
| `lh.sv  idx, imm(rs1)` | custom-0 | 101 | LDH | SVR[idx..idx+3] ← 4 words at EA | no |
| `la.sv  0,   imm(rs1)` | custom-0 | 110 | LDH | SVR[0..15] ← 16 words at EA | no |
| `spm.sw rs2, imm(rs1)` | custom-1 | 000 | S | SPM word at EA ← GPR[rs2] | no |
| `spm.lw rd,  imm(rs1)` | custom-1 | 100 | I | GPR[rd] ← SPM word at EA | yes |
| `rvne.rdwv rd, idx` | custom-1 | 001 | IDX | GPR[rd] ← WVR[idx] | yes |
| `rvne.rdsv rd, idx` | custom-1 | 010 | IDX | GPR[rd] ← SVR[idx] | yes |
| `rvne.status rd, clr` | custom-1 | 011 | IDX | GPR[rd] ← STATUS; if clr, then clear the sticky bits | yes |
| *reserved* | custom-0 | 011, 111 | — | rejected (illegal instruction) | — |
| *reserved* | custom-1 | 101, 110, 111 | — | rejected (illegal instruction) | — |

The six `*.wv`/`*.sv` loads keep the names, granularities and Table II field layout of the reference paper. `spm.sw`, `spm.lw`, `rvne.rdwv`, `rvne.rdsv` and `rvne.status` are **project-defined** support instructions: they fill the SPM, read back state, and read the status register.

Opcode values: custom-0 = `0001011` (0x0B) and custom-1 = `0101011` (0x2B), the major opcodes the RISC-V unprivileged ISA reserves for custom extensions (`inst[6:2]` = `00010` / `01010`).

## 2. Encoding formats

```
 bit:   31            20 19   15 14  12 11  10     7 6      0
 LDW  [   imm[11:0]     |  rs1  |funct3|   idx[4:0]  | opcode ]
 LDH  [   imm[11:0]     |  rs1  |funct3|hint|idx[3:0]| opcode ]
 I    [   imm[11:0]     |  rs1  |funct3|   rd[4:0]   | opcode ]
 IDX  [   imm[11:0]     | 00000 |funct3|   rd[4:0]   | opcode ]
 S    [imm[11:5]| rs2   |  rs1  |funct3|  imm[4:0]   | opcode ]
        31   25 24   20
```

- **LDW / LDH** follow paper Table II exactly: lw.* has a 5-bit index field, and lh.*/la.* have `hint` in bit 11 with a 4-bit index field. `hint` is **not** an extra bit. LDH splits the standard 5-bit `rd` slot (bits 11:7) into `hint` (bit 11) and `idx[3:0]` (bits 10:7). Exact bit positions:

  | Field | LDW bits | LDH bits | Width |
  |---|---|---|---|
  | `imm[11:0]` | 31:20 | 31:20 | 12 |
  | `rs1` | 19:15 | 19:15 | 5 |
  | `funct3` | 14:12 | 14:12 | 3 |
  | `hint` | — | 11 | 1 |
  | `idx` | 11:7 (`idx[4:0]`) | 10:7 (`idx[3:0]`) | 5 / 4 |
  | `opcode` | 6:0 | 6:0 | 7 |
  | **Total** | **32** | **32** | |
- `imm` is sign-extended. The effective address is **EA = GPR[rs1] + sext(imm)**, computed in 32 bits.
- In **IDX** format, `imm[3:0]` is the register index (or the `clr` flag for `rvne.status`). The remaining `imm` bits and the `rs1` field must be zero.

### 2.1 Deviation from the paper: direct indexing (DEC-06)

In the paper, the `rd` field of a load names a **GPR whose value** is the WVR/SVR index (indirect indexing). In M1 the field **is** the index (direct indexing).

**Rationale:** the selected CV32A60X configuration provides two source operands (`X_NUM_RS = 2`: rs1 and rs2), which is enough for M1. Direct indexing also keeps the index visible in the instruction word, so bad indices can be rejected deterministically at issue (§5). Future indirect-indexed instructions that need an additional source operand, such as the paper's `conv*`/`dot*` with indirect `rs1`, `rs2` and `rd`, would require a platform/configuration change to `X_NUM_RS = 3`. They are not part of the frozen M1 interface. See DEC-06.

### 2.2 Example encodings (machine-checked)

| Assembly | Word |
|---|---|
| `lw.wv 3, 0x10(x10)` | `0x0105018B` |
| `lh.wv 4, 0x40(x10)` | `0x0405120B` |
| `la.wv 0, 0x40(x0)` | `0x0400200B` |
| `lw.sv 2, 0x100(x0)` | `0x1000410B` |
| `lh.sv 8, 0(x11)` | `0x0005D40B` |
| `la.sv 0, 0(x11)` | `0x0005E00B` |
| `lh.wv 4, 0x40(x10)` with hint = 1 | `0x04051A0B` (only bit 11 differs) |
| `spm.sw x6, 0x44(x10)` | `0x0465022B` |
| `spm.lw x7, 0x44(x10)` | `0x044543AB` |
| `rvne.rdwv x5, 1` | `0x001012AB` |
| `rvne.rdsv x5, 2` | `0x002022AB` |
| `rvne.status x5, 1` | `0x001032AB` |

## 3. CV-X-IF issue response per instruction

| Instruction | `accept` | `register_read` | `writeback` |
|---|---|---|---|
| `lw/lh/la.wv`, `lw/lh/la.sv` | 1 if legal (§5.1) | rs1 | 0 |
| `spm.sw` | 1 if legal | rs1, rs2 | 0 |
| `spm.lw` | 1 if legal | rs1 | 1 |
| `rvne.rdwv`, `rvne.rdsv`, `rvne.status` | 1 if legal | none | 1 |
| anything else in custom-0/custom-1 | 0 | — | — |

Instructions outside custom-0 and custom-1 are never accepted.

## 4. Semantics

Notation:
- `word(a)` = SPM bytes `a..a+3`, little-endian.
- `SPM_BYTES`, `N_WVR` and the other parameters are as defined in D1 §2.
- `STATUS` is defined in §6.

Every instruction below runs only after it has been **accepted** at CV-X-IF issue. On CV32A60X, the register operands and a non-kill commit arrive in that same cycle (D3 §2). A non-accepted instruction changes no RVNE state.

### 4.1 Vector loads

```
lw.wv idx, imm(rs1):            # LDW, idx in 0..15 (idx[4] must be 0, checked at issue)
    EA = GPR[rs1] + sext(imm)
    if EA % 4 != 0:      STATUS.ERR_ALIGN = 1; no-op
    elif EA >= SPM_BYTES: STATUS.ERR_RANGE = 1; no-op
    else:                WVR[idx] = word(EA)

lh.wv idx, imm(rs1):            # LDH, idx in {0,4,8,12} (checked at issue)
    EA = GPR[rs1] + sext(imm)
    if EA % 16 != 0:     STATUS.ERR_ALIGN = 1; no-op
    elif EA >= SPM_BYTES: STATUS.ERR_RANGE = 1; no-op
    else: for k in 0..3:  WVR[idx+k] = word(EA + 4k)

la.wv 0, imm(rs1):              # LDH, idx must be 0 (checked at issue)
    EA = GPR[rs1] + sext(imm)
    if EA % 64 != 0:     STATUS.ERR_ALIGN = 1; no-op
    elif EA >= SPM_BYTES: STATUS.ERR_RANGE = 1; no-op
    else: for k in 0..15: WVR[k] = word(EA + 4k)
```

The `*.sv` forms are identical, with SVR in place of WVR. For all six loads:

- `hint` is **ignored** in M1. It is reserved for the paper's prefetch hint, and any value is accepted.
- No GPR is written.
- WVR/SVR entries outside the written range keep their values.

Because EA is aligned to the access size, the whole access lies within one SPM row. The range check on EA therefore covers the full access.

### 4.2 SPM access

```
spm.sw rs2, imm(rs1):
    EA = GPR[rs1] + sext(imm)
    if EA % 4 != 0:      STATUS.ERR_ALIGN = 1; no-op
    elif EA >= SPM_BYTES: STATUS.ERR_RANGE = 1; no-op
    else:                word(EA) = GPR[rs2]

spm.lw rd, imm(rs1):
    EA = GPR[rs1] + sext(imm)
    if EA % 4 != 0:      STATUS.ERR_ALIGN = 1; GPR[rd] = 0
    elif EA >= SPM_BYTES: STATUS.ERR_RANGE = 1; GPR[rd] = 0
    else:                GPR[rd] = word(EA)
```

### 4.3 Read-back and status

```
rvne.rdwv rd, idx:   GPR[rd] = WVR[idx]          # idx in 0..15
rvne.rdsv rd, idx:   GPR[rd] = SVR[idx]
rvne.status rd, clr: GPR[rd] = STATUS; if clr: STATUS.ERR_* = 0
```

As usual, a write to `x0` is discarded by the core.

## 5. Error model

Two platform facts shape the error model:

- CV-X-IF v1.0.0 requires `accept` to be decided **from the instruction word only**. This holds even though CV32A60X supplies the operands in the same cycle.
- The exception mechanism in the CV32A60X XIF path is CVA6's own. When an offloaded instruction is not accepted, `cvxif_fu.sv` raises an illegal-instruction exception (`x_exception_o.valid = x_illegal_i`, `cause = ILLEGAL_INSTR`). The v1.0.0 result packet that CVA6 consumes (`id`, `data`, `rd`, `we`) carries no coprocessor-originated exception.

**M1 therefore does not report RVNE operand-value errors as exceptions.** Encoding errors are rejected with `accept = 0`, which lets CVA6 generate its illegal-instruction exception. Operand-value errors are architecturally defined as successful no-op operations that set sticky RVNE `STATUS` bits. The two classes are:

### 5.1 Encoding errors: rejected at issue (`accept = 0`, so CVA6 raises an illegal-instruction exception)

- Reserved funct3 in custom-0 or custom-1.
- `lw.*` with `idx[4] = 1` (`idx ≥ N_WVR` or `idx ≥ N_SVR`).
- `lh.*` with `idx % 4 != 0`.
- `la.*` with `idx != 0`.
- IDX format with `rs1 != 0`, or with any of `imm[11:4]` non-zero.
- `rvne.status` with any of `imm[3:1]` non-zero.

### 5.2 Operand-value errors: accepted, executed as a no-op, sticky status bit set

- Misaligned EA → `STATUS.ERR_ALIGN`.
- `EA ≥ SPM_BYTES`, as an unsigned 32-bit comparison → `STATUS.ERR_RANGE`. If both errors apply, only `ERR_ALIGN` is set.
- The instruction still completes with exactly one X-IF result transaction, as CV-X-IF requires. `spm.lw` returns 0.
- These checks happen in the clocked domain (the decoder). An erroneous command is **never sent** across the async bridge.

Software that needs to detect errors reads `rvne.status`.

## 6. STATUS register (clocked domain)

| Bits | Field | Access | Reset | Meaning |
|---|---|---|---|---|
| 0 | `ERR_ALIGN` | sticky, cleared by `rvne.status rd, 1` | 0 | A command had a misaligned EA |
| 1 | `ERR_RANGE` | sticky, same clear | 0 | A command had an EA outside the SPM |
| 7:2 | reserved | RO | 0 | |
| 11:8 | `LAST_ERR_OP` | RO, updated on each error | 0 | Bridge op code (D3 §3.2) of the most recent erroneous command |
| 23:12 | reserved | RO | 0 | |
| 31:24 | `VERSION` | RO | `0x01` | RVNE-ASYNC M1 |

`rvne.status rd, 1` returns the value from **before** the clear.

## 7. Completion semantics

- Each accepted instruction produces **exactly one** CV-X-IF result transaction, after its effect is complete and visible. On CV32A60X every accepted instruction is committed with `commit_kill = 0` in the same cycle (D3 §2).
  - For load and `spm.sw` instructions, the result has `we = 0`.
  - For `spm.lw`, `rvne.rd*` and `rvne.status`, it has `we = 1`, with `rd` taken from the instruction.
- A non-accepted instruction produces no result.
- Results are returned in order. M1 has one outstanding instruction (D1 §6).
- A load "completes" when every written WVR/SVR entry holds its new value. Any later RVNE instruction therefore observes it.

## 8. Software example

This example fills SPM row 1 and loads it into all WVR entries:

```asm
    li      x10, 0x40            # SPM base of row 1
    li      x11, 0x80            # end of row 1
1:  addi    x11, x11, -4         # SPM is undefined after reset: zero the row
    spm.sw  x0,  0(x11)
    bne     x11, x10, 1b
    li      x6,  0x76543210
    spm.sw  x6,  0(x10)
    li      x6,  0xFEDCBA98
    spm.sw  x6,  4(x10)
    li      x6,  0x80000001
    spm.sw  x6,  60(x10)         # word 15 of the row
    la.wv   0,   0(x10)          # WVR[0..15] <- row 1
    rvne.rdwv x5, 1              # x5 = 0xFEDCBA98
    rvne.status x7, 1            # x7 = 0x01000000 (no errors), clear sticky bits
```

The full expected register state is given in D4 §6.
