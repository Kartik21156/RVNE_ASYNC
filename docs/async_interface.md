# D3 — Asynchronous Interface Specification

**Status:** Frozen — Phase 0 baseline (2026-10-05). Changes only via a new entry in [decisions.md](decisions.md).
**Style:** bundled-data, 4-phase (return-to-zero) handshaking (DEC-01)
**Depends on:** [architecture.md](architecture.md) · [instruction_spec.md](instruction_spec.md)

The system has two interfaces:

1. **CV-X-IF**, between the RISC-V host and the decoder. It is entirely clocked and uses the standard protocol (§2).
2. **The bridge channel** `rvne_ch`, between the clocked decoder and the async coprocessor. It is the clock-domain boundary (§3–§5).

---

## 1. Signal conventions

- `clk_i`: host clock (clocked domain only).
- `rst_ni`: active-low reset, applied asynchronously to both domains (§6).
- `↑` / `↓`: rising / falling transition of a handshake wire.
- `D_x`: a matched-delay element (§5.2).

## 2. CV-X-IF side (clocked)

Host: CV32A60X (DEC-05). Interface: **CV-X-IF v1.0.0** with `X_NUM_RS = 2`, `X_ID_WIDTH = 2`, `X_RFR_WIDTH = X_RFW_WIDTH = 32` (DEC-03). The decoder uses the **issue**, **commit** and **result** interfaces.

- **Operands arrive in the issue cycle.** CVA6 drives the v1.0.0 operand signals (`register_valid`, `register.rs[1:0]`, `register.rs_valid`) combinationally alongside the issue request, with `register_valid = issue_valid`. The decoder therefore latches rs1 and rs2 in the **same cycle** it accepts the instruction. It still drives `register_ready = 1` whenever `issue_ready = 1`, as the v1.0.0 handshake requires.
- **Commit arrives in the same cycle as an accepted issue, and is never a kill.** CV32A60X does not support speculative CV-X-IF execution. The pinned integration generates the commit transaction in the same cycle as an accepted issue and drives `commit_kill = 0`:
  ```systemverilog
  assign commit_valid_o       = issue_valid_o && issue_ready_i;
  assign commit_o.commit_kill = 1'b0;   // "Always commit since speculation in execute is not possible"
  ```
  So in M1, an accepted instruction is committed in the cycle it is accepted. The decoder has **no commit-wait state and no kill path**.
- **Compressed, memory and memory-result interfaces:** not implemented by CV32A60X, and therefore not connected by the RVNE adapter. RVNE instructions are 32-bit uncompressed custom instructions. The coprocessor accesses only its local SPM.

| X-IF interface | Fields used | Decoder behaviour |
|---|---|---|
| issue + register (unsplit) | `instr`, `id`, `hartid`, `rs[0]`, `rs[1]`, `rs_valid` → `accept`, `writeback`, `register_read` | `accept` comes from combinational decode of `instr` **only** (v1.0.0 rule; D2 §3, §5.1). On accepted issue, latch `id`, `hartid`, rs1 and rs2. `issue_ready = register_ready = (state == IDLE)`. |
| commit | `id`, `commit_kill` | Not used for control. Checked only by the platform assertions below. |
| result | `id`, `hartid`, `data`, `rd`, `we` | Exactly one per accepted instruction, held until `result_ready` |

CV-X-IF terminates at this decoder. Nothing from CV-X-IF crosses the async boundary; only the bridge command bundle (§3) does.

**Platform assertions** (the decoder flags any violation of the CV32A60X assumptions):

| # | Assertion |
|---|---|
| X1 | `commit_valid` ⇒ `issue_valid ∧ issue_ready` in the same cycle, with `commit.id == issue_req.id`. CVA6 does not gate commit with `accept`, so it also fires for a rejected issue, and the decoder ignores it. |
| X2 | `commit_valid` ⇒ `commit.commit_kill == 0` |
| X3 | `issue_valid` ⇒ `register_valid`, with `register.id == issue_req.id` (unsplit issue/register) |
| X4 | On an accepted issue, `rs_valid` covers every bit of `register_read` |

If the host is changed to one that supports speculation or split register transactions, these assertions fail. The commit-wait and kill handling would then have to be specified and added as a new decision.

**Decoder FSM (one outstanding instruction):**

```
IDLE ──issue+register accepted (rs1/rs2 latched; commit same cycle, kill=0)──► CHECK
  ▲                                                                           │
  │                                         operand error ┌───────────────────┤ ok
  │                                                       ▼                   ▼
  │◄────────── result_ready ─────────────────────────── RESULT ◄──────── BRIDGE (§4)
```

- `issue_ready` and `register_ready` are 1 only in `IDLE`.
- In `CHECK`, the operand-value checks of D2 §5.2 run. A failing command updates `STATUS` and goes straight to `RESULT` without using the bridge.
- `rvne.status` is executed entirely in the decoder (`CHECK` → `RESULT`) and does not use the bridge.
- A non-accepted issue (`accept = 0`) leaves the decoder in `IDLE`. CVA6 then raises the illegal-instruction exception itself (D2 §5.1).

## 3. Bridge channel `rvne_ch`

### 3.1 Wires

| Signal | Width | Direction | Bundled with | Meaning |
|---|---|---|---|---|
| `req` | 1 | sync → async | — | Request (4-phase) |
| `cmd_op` | 4 | sync → async | `req` | Bridge op code (§3.2) |
| `cmd_idx` | 4 | sync → async | `req` | WVR/SVR index (first entry) |
| `cmd_addr` | 14 | sync → async | `req` | SPM byte address (EA[13:0]), already aligned |
| `cmd_wdata` | 32 | sync → async | `req` | Write data (`spm.sw`) |
| `ack` | 1 | async → sync | — | Acknowledge (4-phase) |
| `rsp_rdata` | 32 | async → sync | `ack` | Read data (`spm.lw`, `rvne.rd*`); 0 for other ops |

The channel is **bundled-data**. The data wires are ordinary single-rail signals whose validity is implied by the handshake wire they are bundled with. The command bundle travels with `req`, and the response bundle travels with `ack`. A single channel carries both directions, so each command is exactly one 4-phase cycle.

### 3.2 Bridge op codes

| `cmd_op` | Name | From instruction |
|---|---|---|
| 0x0 | `OP_SPM_SW` | `spm.sw` |
| 0x1 | `OP_SPM_LW` | `spm.lw` |
| 0x2 | `OP_LW_WV` | `lw.wv` |
| 0x3 | `OP_LH_WV` | `lh.wv` |
| 0x4 | `OP_LA_WV` | `la.wv` |
| 0x5 | `OP_LW_SV` | `lw.sv` |
| 0x6 | `OP_LH_SV` | `lh.sv` |
| 0x7 | `OP_LA_SV` | `la.sv` |
| 0x8 | `OP_RD_WV` | `rvne.rdwv` |
| 0x9 | `OP_RD_SV` | `rvne.rdsv` |
| 0xA–0xF | reserved | never generated in M1 |

### 3.3 Protocol rules (normative)

| # | Rule |
|---|---|
| P1 | Idle state: `req = 0`, `ack = 0`. |
| P2 | **Command stability:** the command bundle must be stable from before `req↑` (setup, guaranteed by S1) until `ack↑` is observed by the sync side. |
| P3 | **Response stability:** `rsp_rdata` must be valid before `ack↑` and stable until `req↓`. |
| P4 | Sequence: `req↑ → ack↑ → req↓ → ack↓`. No other order is legal. |
| P5 | `ack↑` means **the command's effect is complete**: SPM, WVR and SVR hold their new values, and `rsp_rdata` is valid. |
| P6 | The async side must not change any architectural state between `ack↑` and the next `req↑`. In particular, it does nothing on `req↓` / `ack↓` except return its control to zero. |
| P7 | Only legal, accepted (and therefore committed, D3 §2) commands are ever sent (D2 §5). The async side has no error response in M1. A reserved `cmd_op` is a protocol violation: an assertion fires and the async side behaves as a no-op. |
| P8 | No new `req↑` until `ack↓` has been observed (the return-to-zero phase is complete). |

### 3.4 Waveform

```
             ┌──────────────────────┐
 req   ──────┘                      └──────────────────────
       ════╤═══════════════════════════╤═══════════════════
 cmd_* ════╡  cmd stable (P2)          ╞═══ don't care ════
       ════╧═══════════════════════════╧═══════════════════
                         ┌───────────────────────┐
 ack   ──────────────────┘                       └─────────
       ══════════════════╤══════════════════╤══════════════
 rsp_* ══ don't care ════╡ rsp stable (P3)  ╞══ don't care
       ══════════════════╧══════════════════╧══════════════
           ①       ②     ③    ④ ⑤          ⑥      ⑦
```

- ① Data flops are loaded. ② `req↑`, one clock later (S1).
- ③ The async side completes the operation and raises `ack↑`. ④ After 2 FF stages, the sync side sees `ack_s = 1`. ⑤ It captures `rsp_rdata` and drops `req↓`.
- ⑥ The async side returns to zero: `ack↓`. ⑦ The sync side sees `ack_s = 0`, and the channel is idle.

## 4. Sync half (`rvne_async_if`, clocked)

| # | Rule |
|---|---|
| S1 | The command bundle flops load in cycle *n*. The `req` flop is set in cycle *n+1*. Both are driven **directly from flops**: no combinational logic sits between a flop and the boundary. This gives ≥ 1 `clk_i` period of setup before `req↑`, which satisfies P2. |
| S2 | `ack` is passed through a **2-flop synchroniser** to give `ack_s`. No other async → sync signal is synchronised. |
| S3 | `rsp_rdata` is sampled **only** in the cycle `ack_s` first becomes 1. By then `rsp_rdata` has been stable for ≥ 2 cycles, which satisfies P3, so it is safe to sample without synchronising it. |
| S4 | `req` is cleared in the cycle after the capture. The command bundle may change only after `ack_s = 1`. |
| S5 | The bridge reports `done` to the decoder after `ack_s` returns to 0. Only then can the decoder issue the X-IF result and accept a new instruction (P8). |

Minimum bridge latency is about 5 clock cycles plus the async operation time (`T_op`). This is a functional figure; the bridge is not optimised in M1.

## 5. Async half (controller, SPM, loaders, registers)

### 5.1 Control

The controller is built from **Muller C-elements** and matched delays. Its sequence:

```
req↑ ─► [decode: D_dec] ─► SPM access enable ─► [D_spm] ─► data valid
      ─► (if *.wv / *.sv) register write-enable pulse ─► [D_wr]
      ─► ack↑                                   (rsp_rdata driven before ack↑)
req↓ ─► write enables already low; control returns to zero ─► ack↓
```

| # | Rule |
|---|---|
| A1 | All internal sequencing uses req/ack handshakes and matched delays. There is no clock and no free-running oscillator. |
| A2 | **SPM access:** a read reads one full 512 b row (all 16 banks in parallel); a write writes one 32 b word (one bank). Row = `cmd_addr[13:6]`, bank = `cmd_addr[5:2]`. |
| A3 | **WVR/SVR** are level-sensitive latch arrays. The write-enable pulse for each selected entry is opened only after the SPM data is valid (after `D_spm`) and closed before `ack↑` (after `D_wr`). Entry selection is given in D4. |
| A4 | `rsp_rdata` is driven from the selected word (`OP_SPM_LW`) or the selected entry (`OP_RD_*`) before `ack↑`, and is held until `req↓` (P3). For other ops it is 0. |
| A5 | Write-enable and SPM-enable outputs must be glitch-free, so they are derived from handshake signals and not from decoded data. Decoded data only *selects* which enable is passed through. |

### 5.2 Timing assumptions (bundled-data)

These are the **only** timing assumptions in the design. Each one must be checked against post-synthesis timing.

| # | Assumption | Simulation model |
|---|---|---|
| T1 | `D_dec` ≥ the worst-case delay from `cmd_*` to a stable decode | `#(D_DEC)` parameter |
| T2 | `D_spm` ≥ the worst-case SPM read access, or write cycle | `#(D_SPM)` parameter |
| T3 | `D_wr` ≥ the latch minimum pulse width plus the latch D→Q delay | `#(D_WR)` parameter |
| T4 | The bridge flop → boundary skew between `cmd_*` and `req` is less than one `clk_i` period | Guaranteed by S1 |
| T5 | The `ack` synchroniser has an MTBF acceptable for the target `clk_i` | Standard 2-FF |

Matched delays are separate, parameterised modules (`rvne_delay #(.D(...))`). Simulation models them with `#` delays, and the FPGA or ASIC implementation replaces them (open item DEC-10). Simulation must also run a **delay-violation check**: the testbench shrinks each `D_*` below the modelled logic delay and confirms that an assertion fires.

## 6. Reset

| # | Rule |
|---|---|
| R1 | `rst_ni = 0` is applied asynchronously to both domains. |
| R2 | **Async domain, during reset:** `ack = 0`, all internal C-elements are reset to 0, all write enables are 0, and WVR and SVR are cleared to 0. SPM contents are **not** reset and are undefined after power-up. |
| R3 | **Clocked domain, during reset:** `req = 0`, the decoder is `IDLE` with `issue_ready = 0`, `STATUS` holds its reset value (D2 §6), and the synchroniser flops are 0. |
| R4 | Deassertion of `rst_ni` is synchronised to `clk_i` (2-FF reset synchroniser). `issue_ready` rises no earlier than 2 cycles after the synchronised release. |
| R5 | Reset asserted in the middle of a transaction aborts it. After reset, the state of that transaction's target entries is the reset value for WVR and SVR, and **undefined** for the targeted SPM word. |

## 7. Event-by-event transactions

In each table, "C" marks a clocked event (with its cycle number) and "A" marks an async event. All examples start from idle.

### 7.1 `lw.wv 3, 0x10(x10)` with x10 = 0x100 (EA = 0x110)

| # | Domain | Event |
|---|---|---|
| 1 | C0 | X-IF issue + register: `instr = 0x0105018B`, rs[0] = 0x100. Decode is legal, so `accept = 1`, `register_read = rs1`, `writeback = 0`. The commit from CVA6 arrives in the same cycle with `commit_kill = 0` (X1, X2). The decoder latches id and rs1. |
| 2 | C1 | `issue_ready → 0`. |
| 3 | C1 | CHECK: EA = 0x110. It is aligned and below 16384, so the check passes. |
| 4 | Cn | Bridge loads `cmd_op = 0x2`, `cmd_idx = 3`, `cmd_addr = 0x0110`, `cmd_wdata = 0`. |
| 5 | Cn+1 | `req↑` |
| 6 | A | Decode (`D_dec`) → SPM row 0x04 read (`D_spm`) → bank 4 word selected → WVR[3] write-enable pulse (`D_wr`). |
| 7 | A | `rsp_rdata = 0`, then `ack↑`. WVR[3] = word(0x110). |
| 8 | Cm, Cm+1 | `ack` passes through the synchroniser. `ack_s = 1` at Cm+1. |
| 9 | Cm+2 | `req↓` |
| 10 | A | `ack↓` |
| 11 | Cp | `ack_s = 0`, so the bridge reports `done`. |
| 12 | Cp+1 | X-IF result: `id`, `we = 0`. When `result_ready` is seen, `issue_ready → 1`. |

### 7.2 `la.sv 0, 0(x11)` with x11 = 0x200

This follows 7.1, with these differences:
- Row 0x08 is read.
- The write-enable pulses for SVR[0..15] open simultaneously; SVR[k] = word(0x200 + 4k).
- The `ack` and result handling is identical.

### 7.3 `spm.sw x6, 0x44(x10)` with x10 = 0, x6 = 0xDEADBEEF

- rs1 and rs2 are latched in the issue cycle. The command is `cmd_op = 0x0`, `cmd_addr = 0x0044`, `cmd_wdata = 0xDEADBEEF`.
- Async side: bank 1 of row 1 is written (`D_spm`), then `ack↑`.
- Result: `we = 0`.

### 7.4 `rvne.rdwv x5, 1`

- No operands are needed (`register_read = 0`). After the accepted issue, the bridge command is `cmd_op = 0x8`, `cmd_idx = 1`.
- Async side: WVR[1] is driven onto `rsp_rdata`, then `ack↑`. No write enables fire.
- Sync side: `rsp_rdata` is captured at `ack_s = 1`. Result: `rd = 5`, `we = 1`, `data = WVR[1]`.

### 7.5 Rejected instruction: `lh.wv 5, 0x40(x0)` (encoding error)

- X-IF issue: decode finds `idx % 4 ≠ 0`, so `accept = 0` (D2 §5.1).
- The decoder stays in `IDLE`. **The bridge is not used** and no result is produced. CVA6 raises the illegal-instruction exception internally (`cvxif_fu.sv`: `x_exception_o.valid = x_illegal_i`, `cause = ILLEGAL_INSTR`).
- Architectural state is unchanged.

(Killed instructions cannot occur on CV32A60X; see §2, X2.)

### 7.6 Operand error: `lh.wv 4, 0x44(x0)`

- Accepted at issue: the encoding is legal, because idx 4 is a multiple of 4.
- CHECK: EA = 0x44, and 0x44 % 16 ≠ 0. So `STATUS.ERR_ALIGN = 1` and `LAST_ERR_OP = 0x3`.
- **The bridge is not used.** Result: `we = 0`. WVR is unchanged.

## 8. Answers to spec §6.2

| Question | Answer |
|---|---|
| Bundled-data or encoded/token-based? | Bundled-data, single-rail, 4-phase (§3). |
| How are instruction fields transferred? | The decoder converts them to a bridge command bundle `{op, idx, addr, wdata}` (§3.1). The raw instruction word never crosses the boundary. |
| When is command data stable? | From ≥ 1 `clk_i` period before `req↑` until `ack↑` (P2, S1). |
| Can a second command be accepted while the first is in progress? | No. There is one outstanding instruction in M1 (D1 §6), and `issue_ready = 0` until the result is sent. |
| How is busy/ready represented? | X-IF `issue_ready`. Internally, the channel is busy whenever `req ∨ ack_s` (§4 S5). |
| How does the CPU wait for completion? | The CPU waits through the CV-X-IF result transaction. A subsequent RVNE instruction stalls at issue. A dependent GPR read (after `spm.lw` or `rvne.rd*`) is handled by the core's normal X-IF scoreboarding. |
| How are exceptions or invalid commands reported? | Encoding errors are rejected at issue (`accept = 0`), and CVA6 then raises its own illegal-instruction exception. Operand errors make the instruction a no-op and set sticky `STATUS` bits, read with `rvne.status` (D2 §5). The async side never receives an invalid command (P7). |
| How is reset handled? | §6 (R1–R5). |
| How does the coprocessor access memory? | Only its local SPM. It is filled by `spm.sw`, and DMA fill is open (DEC-09). It has no host-memory port. |
| What timing assumptions are made? | T1–T5 (§5.2). There are no others. |
