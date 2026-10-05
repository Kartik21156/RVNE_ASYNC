# D6 — RTL Module Specification (RTL contract)

**Status:** Frozen — D6 RTL contract (2026-10-05). Changes only via a new entry in [decisions.md](decisions.md).
**Realises:** D1–D4 (frozen), DEC-14, DEC-15 · **Oracle:** D5 (`model/rvne_reference.py`) · **Simulator:** xsim 2022.1 (DEC-11)

This is the contract between the architecture and the RTL. For every module it fixes the following:

1. parameters
2. domain and reset
3. ports and widths
4. handshake semantics
5. state ownership
6. sampling edge or event
7. output validity
8. reset behaviour
9. assertions
10. requirement trace

It **adds no architecture**. Where the RTL refines a spec-level state or rule, the refinement is marked **[refinement]** and shown to satisfy the cited rule. Anything that cannot be realised as specified becomes a new DEC entry.

---

## 1. Global conventions

| Item | Rule |
|---|---|
| Language | SystemVerilog-2012. Every `` `ifndef SYNTHESIS `` block is simulation-only (`#` delays, assertions, checkers). |
| Timescale | `` `timescale 1ns/1ps `` in every file |
| Clocked logic | `always_ff @(posedge clk_i or negedge rst_ni)`. Async assert, synchronous release (§3.1). |
| Clocked handshakes | Local valid/ready: a transfer happens at the `posedge` where `valid ∧ ready`. `valid` must not depend on `ready`, and the payload is stable while `valid ∧ ¬ready`. |
| Async logic | No clocked logic. Storage is `always_latch`, with one exception: the `rvne_spm` behavioural SRAM model samples on its write-strobe edge (§4.11). Control comes from `rvne_c_element` and `rvne_delay`. |
| Boundary | Only the D3 §3.1 wires cross between `rvne_bridge_sync` and `rvne_bridge_async`. |
| Names | `_i` / `_o` ports, `_q` storage, `_n` active-low |
| Assertions | Named `a_<rule>` after the spec rule. Clocked assertions are concurrent SVA with `disable iff (!rst_ni)`. Async assertions are immediate assertions in event-triggered `always` blocks. |

## 2. Module inventory and hierarchy (DEC-15)

```
rvne_top
├── rvne_sync2 (u_rst_sync)          clocked   reset release
├── rvne_if                          clocked   CV-X-IF adapter (wiring + X1–X4)
├── rvne_decoder                     clocked
│   └── rvne_status                  clocked
├── rvne_bridge_sync                 clocked
│   └── rvne_sync2 (u_ack_sync)      clocked
├── rvne_bridge_async                async
│   ├── rvne_delay ×3 (u_d_dec, u_d_spm, u_d_wr)
│   └── rvne_c_element (u_ack_c)
├── rvne_exec                        async (combinational routing; no execution engine, DEC-15)
├── rvne_spm                         async
├── rvne_wvr                         async
└── rvne_svr                         async
rvne_pkg (package, compiled first)
```

## 3. Shared definitions

### 3.1 Reset scheme (D3 §6)

- `rst_ni` is the external reset, active-low and asynchronous.
- `rst_sync_n` is the output of `u_rst_sync` (`d_i = 1'b1`, reset by `rst_ni`). It **asserts asynchronously** with `rst_ni` and **releases on the second `posedge clk_i`** after `rst_ni` rises. All clocked modules use `rst_sync_n` as their `rst_ni` port.
- The async modules use raw `rst_ni` (R1).
- **[refinement R4]** The decoder holds `issue_ready = 0` for 2 cycles after `rst_sync_n` releases (§4.3, state `INIT`). `rvne_bridge_sync` also refuses a command until `ack_s = 0` (§4.5). Together these guarantee that the first transaction starts with both domains idle.

### 3.2 `rvne_pkg`

| Item | Value | Source |
|---|---|---|
| `XLEN`, `W_BITS`, `N_WVR`, `N_SVR`, `ENTRY_BITS` | 32, 4, 16, 16, 32 | D1 §2 |
| `SPM_BYTES`, `SPM_BANKS`, `SPM_ROWS`, `SPM_AW` | 16384, 16, 256, 14 | D1 §2 |
| `OPC_CUSTOM0`, `OPC_CUSTOM1` | `7'b0001011`, `7'b0101011` | D2 §1 |
| `bridge_op_e` | `OP_SPM_SW=0` … `OP_RD_SV=9` (4 bits) | D3 §3.2 |
| `bridge_cmd_t` | packed `{op[3:0], idx[3:0], addr[13:0], wdata[31:0]}`, 54 b | D3 §3.1 |
| `STATUS_VERSION` | `8'h01` | D2 §6 |
| `X_NUM_RS`, `X_ID_WIDTH`, `X_RFR_WIDTH`, `X_RFW_WIDTH` | 2, 2, 32, 32 | DEC-03 |
| `X_HARTID_WIDTH` | 32 (= XLEN, `build_config_pkg.sv`) | CVA6 `b1f80bd` |
| `readregflags_t`, `writeregflags_t` | `logic [1:0]`, `logic [0:0]` (`X_DUALREAD = X_DUALWRITE = 0`) | CVA6 `b1f80bd` |
| CV-X-IF structs | Member order exactly as in `core/include/cvxif_types.svh` (table below) | CVA6 `b1f80bd` |

| Type | Members (in order) |
|---|---|
| `x_compressed_req_t` | `instr[15:0]`, `hartid` |
| `x_compressed_resp_t` | `instr[31:0]`, `accept` |
| `x_issue_req_t` | `instr[31:0]`, `hartid`, `id` |
| `x_issue_resp_t` | `accept`, `writeback`, `register_read` |
| `x_register_t` | `hartid`, `id`, `rs[1:0][31:0]`, `rs_valid` |
| `x_commit_t` | `hartid`, `id`, `commit_kill` |
| `x_result_t` | `hartid`, `id`, `data[31:0]`, `rd[4:0]`, `we` |
| `cvxif_req_t` | `compressed_valid`, `compressed_req`, `issue_valid`, `issue_req`, `register_valid`, `register`, `commit_valid`, `commit`, `result_ready` |
| `cvxif_resp_t` | `compressed_ready`, `compressed_resp`, `issue_ready`, `issue_resp`, `register_ready`, `result_valid`, `result` |

### 3.3 Simulation timing parameters (realise D3 §5.2; not architecture)

| Param | Default (ns) | Meaning | Owner |
|---|---|---|---|
| `D_DEC` | 1.0 | Matched delay T1 | `rvne_bridge_async` |
| `D_SPM` | 2.0 | Matched delay T2 | `rvne_bridge_async` |
| `D_WR` | 1.0 | Matched delay T3 | `rvne_bridge_async` |
| `T_EXEC` | 0.3 | **Modelled** decode and routing logic delay | `rvne_exec` |
| `T_SPM` | 1.5 | **Modelled** SPM read access delay | `rvne_spm` |

The defaults satisfy T1 (`D_DEC > T_EXEC`) and T2 (`D_SPM > T_SPM`). The D3 §5.2 delay-violation test sets `D_DEC < T_EXEC` or `D_SPM < T_SPM` and expects a window assertion (W1–W3, §4.7) to fire. Under `SYNTHESIS`, `T_*` and `D_*` have no effect.

---

## 4. Module contracts

### 4.1 `rvne_top`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `type cvxif_req_t = rvne_pkg::cvxif_req_t`; `type cvxif_resp_t = rvne_pkg::cvxif_resp_t`; `realtime D_DEC, D_SPM, D_WR, T_EXEC, T_SPM` (§3.3) |
| 2 | Domain / reset | Mixed. It owns `u_rst_sync` (§3.1). |
| 3 | Ports | `clk_i` (1, in) · `rst_ni` (1, in) · `cvxif_req_i` (`cvxif_req_t`, in) · `cvxif_resp_o` (`cvxif_resp_t`, out) |
| 4 | Handshake | None of its own; all handshakes belong to children. |
| 5 | State | None (instances only). |
| 6 | Sampling | — |
| 7 | Output validity | `cvxif_resp_o` is valid as defined by `rvne_if`. |
| 8 | Reset | Distributes `rst_sync_n` to the clocked children and `rst_ni` to the async children. |
| 9 | Assertions | Elaboration check: `$bits(cvxif_req_t) == $bits(rvne_pkg::cvxif_req_t)`, and likewise for `cvxif_resp_t`, so the layout cannot silently drift from CVA6. |
| 10 | Trace | D1 §3, §4; DEC-15 |

### 4.2 `rvne_if`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `type cvxif_req_t`, `type cvxif_resp_t` (from top) |
| 2 | Domain / reset | Clocked. **Combinational** wiring; `clk_i` and `rst_ni` are used only by the assertions. |
| 3 | Ports | **CPU side:** `cvxif_req_i`, `cvxif_resp_o`. **Decoder side, out:** `issue_valid_o`(1), `issue_instr_o`(32), `issue_id_o`(2), `issue_hartid_o`(32), `rs1_o`(32) = `register.rs[0]`, `rs2_o`(32) = `register.rs[1]`, `rs_valid_o`(2), `result_ready_o`(1). **Decoder side, in:** `issue_ready_i`(1), `issue_accept_i`(1), `issue_writeback_i`(1), `issue_register_read_i`(2), `result_valid_i`(1), `result_hartid_i`(32), `result_id_i`(2), `result_data_i`(32), `result_rd_i`(5), `result_we_i`(1). |
| 4 | Handshake | Pass-through of the CV-X-IF issue and result handshakes. `register_ready = issue_ready_i` (unsplit, D3 §2). The commit interface is **not forwarded**; only the assertions read it. |
| 5 | State | None. |
| 6 | Sampling | — (combinational) |
| 7 | Output validity | `issue_resp` is meaningful when `issue_valid ∧ issue_ready` (CV-X-IF v1.0.0). `result` is meaningful when `result_valid`. |
| 8 | Reset | None (combinational). |
| 9 | Assertions | `a_X1`–`a_X4` (D3 §2), sampled at `posedge clk_i`. `a_X4` is stated precisely as: `issue_valid ∧ issue_ready ∧ issue_resp.accept ⇒ (register.rs_valid & issue_resp.register_read) == issue_resp.register_read`. `a_tieoff`: `compressed_ready == 1 ∧ compressed_resp == '0`, always. |
| 10 | Trace | D3 §2; DEC-03; DEC-14. **Tie-off:** `compressed_ready = 1'b1`, `compressed_resp.accept = 1'b0`, `compressed_resp.instr = '0`. |

### 4.3 `rvne_decoder`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | none (uses `rvne_pkg`) |
| 2 | Domain / reset | Clocked; `rst_ni` = `rst_sync_n` |
| 3 | Ports | **`rvne_if` bundle:** mirror of §4.2. **To bridge:** `cmd_valid_o`(1), `cmd_o`(`bridge_cmd_t`), in `cmd_ready_i`(1), in `rsp_valid_i`(1), in `rsp_rdata_i`(32). **To status:** `err_set_o`(1), `err_align_o`(1), `err_range_o`(1), `err_op_o`(4), `clr_o`(1), in `status_i`(32). |
| 4 | Handshake | CV-X-IF issue: accept at the `posedge` where `issue_valid ∧ issue_ready`. Bridge: valid/ready for `cmd`, then a 1-cycle `rsp_valid` pulse. CV-X-IF result: `result_valid` held until the `posedge` with `result_ready`. |
| 5 | State | `state_q`, `init_cnt_q`(2), `instr_q`(32), `id_q`(2), `hartid_q`(32), `rs1_q`(32), `rs2_q`(32), `cmd_q`, `res_data_q`(32), `res_rd_q`(5), `res_we_q`(1) |
| 6 | Sampling | `instr`, `id`, `hartid`, `rs1` and `rs2` are latched at the accepting edge. `rsp_rdata_i` is latched at the edge where `rsp_valid_i = 1`. `status_i` is latched into `res_data_q` at the `CHECK` exit edge (`rvne.status`). |
| 7 | Output validity | `issue_accept = legal_encoding(issue_instr)` and `issue_register_read = required_rs_mask(issue_instr)`, with `issue_writeback` likewise. All three are combinational functions of `issue_instr` **only** (D2 §3, §5.1; DEC-07); they never depend on `rs_valid` or on operand values, and they equal `rvne_reference.issue()`. **Operand sufficiency at acceptance** is a platform guarantee, not an accept condition: `issue_accept ⇒ (rs_valid & register_read) == register_read` (`a_X4`, §4.2). The decoder may therefore latch `rs1`/`rs2` unconditionally at the accepting edge. `cmd_o` is valid while `cmd_valid_o`. The result fields are valid while `result_valid_o`. |
| 8 | Reset | `state_q = INIT`, `init_cnt_q = 0`, all payload registers 0, all outputs inactive |
| 9 | Assertions | `a_issue_ready_state`: `issue_ready ↔ state == IDLE`. `a_cmd_stable`: `cmd_valid ∧ ¬cmd_ready ⇒ $stable(cmd_o)` next cycle. `a_result_stable`: `result_valid ∧ ¬result_ready ⇒` result fields stable. `a_one_cmd`: `cmd_valid` only in `BRIDGE_REQ`. `a_err_xor_clr`: `¬(err_set ∧ clr)`. |
| 10 | Trace | D2 §2–§7; D3 §2; D1 §6 |

**FSM** **[refinement of D3 §2]**: `INIT` realises R4, and `BRIDGE_REQ`/`BRIDGE_WAIT` together realise the spec-level `BRIDGE`.

| State | Outputs | Next |
|---|---|---|
| `INIT` | `issue_ready = 0` | After 2 cycles → `IDLE` |
| `IDLE` | `issue_ready = 1` | At `issue_valid ∧ accept`: latch → `CHECK`. At `issue_valid ∧ ¬accept`: stay in `IDLE` (CVA6 raises the illegal-instruction exception). |
| `CHECK` | EA = `rs1_q + sext(imm)` combinationally; D2 §5.2 checks | `rvne.status`: `res_data_q ← status_i`, `clr_o = imm[0]` → `RESULT`. Operand error: `err_set_o = 1` with bits and op → `RESULT` (`spm.lw` data 0). Otherwise `cmd_q ←` D3 §3.1 bundle → `BRIDGE_REQ`. `rvne.rd*` always go to the bridge. |
| `BRIDGE_REQ` | `cmd_valid = 1`, `cmd_o = cmd_q` | When `cmd_ready` → `BRIDGE_WAIT` |
| `BRIDGE_WAIT` | — | When `rsp_valid`: `res_data_q ← rsp_rdata` (writeback ops) → `RESULT` |
| `RESULT` | `result_valid = 1`, `{hartid_q, id_q, res_data_q, res_rd_q, res_we_q}` | When `result_ready` → `IDLE` |

**`rvne.status` ordering.** For `rvne.status`, `res_data_q` captures the current `status_i` **before** the effect of `clr_o`: the capture and the clear happen at the same `CHECK`-exit edge, and `status_i` is the registered output of `rvne_status` from before that edge. The returned value is therefore the pre-clear STATUS value (D2 §6). An implementation must not route `clr_o` combinationally into `status_i`.

The command bundle is: `op` from D3 §3.2; `idx` = instruction index (0 for `spm.*`); `addr = EA[13:0]`; `wdata = rs2_q` for `spm.sw`, else 0. The result has `we = 1` and `rd` from the instruction for writeback ops; otherwise `we = 0`, `rd = 0` and `data = 0`. Both must equal D5's `Outcome.bridge` and `Outcome.result` field for field.

### 4.4 `rvne_status`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | none |
| 2 | Domain / reset | Clocked; `rst_sync_n` |
| 3 | Ports | in `err_set_i`(1), `err_align_i`(1), `err_range_i`(1), `err_op_i`(4), `clr_i`(1); out `status_o`(32) |
| 4 | Handshake | None (single-cycle strobes) |
| 5 | State | `err_align_q`, `err_range_q`, `last_err_op_q`(4) |
| 6 | Sampling | `posedge clk_i`. On `err_set_i`: `err_align_q |= err_align_i`, `err_range_q |= err_range_i`, `last_err_op_q = err_op_i`. On `clr_i`: `err_align_q = err_range_q = 0` (`LAST_ERR_OP` is kept). |
| 7 | Output validity | Always valid: `status_o = {8'h01, 12'b0, last_err_op_q, 6'b0, err_range_q, err_align_q}` from registers. A read in the same cycle as `clr_i` therefore returns the pre-clear value (D2 §6). |
| 8 | Reset | All 0 (`status_o = 32'h0100_0000`) |
| 9 | Assertions | `a_set_clr_excl`: `¬(err_set_i ∧ clr_i)`. `a_one_err`: `err_set_i ⇒ (err_align_i ^ err_range_i)`, since only one bit is set per error (D2 §5.2 precedence). |
| 10 | Trace | D2 §5.2, §6 |

### 4.5 `rvne_bridge_sync`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | none |
| 2 | Domain / reset | Clocked; `rst_sync_n`. Owns `u_ack_sync` (`rvne_sync2`). |
| 3 | Ports | **Decoder side:** in `cmd_valid_i`(1), `cmd_i`(54); out `cmd_ready_o`(1), `rsp_valid_o`(1), `rsp_rdata_o`(32). **Boundary:** out `req_o`(1), `cmd_o`(54); in `ack_i`(1), `rsp_rdata_i`(32). |
| 4 | Handshake | 4-phase master per D3 §3.3. `cmd_ready_o = (state == IDLE) ∧ ¬ack_s`. `rsp_valid_o` is a 1-cycle pulse. |
| 5 | State | `state_q`, `req_q`, `cmd_q`(54), `rsp_q`(32); `ack_s` (inside `u_ack_sync`) |
| 6 | Sampling | `posedge clk_i` only. `ack_i` goes **only** through `u_ack_sync`. `rsp_rdata_i` is sampled **exactly once**: at the `posedge` that ends the first `REQ_HIGH` cycle in which `ack_s = 1`. |
| 7 | Output validity | `req_o = req_q` and `cmd_o = cmd_q`, both direct flop outputs with no logic after them (S1). `rsp_rdata_o = rsp_q` is valid while `rsp_valid_o = 1`. |
| 8 | Reset | `state_q = IDLE`, `req_q = 0`, `cmd_q = 0`, `rsp_q = 0`; `ack_s = 0` |
| 9 | Assertions | `a_S1`: `cmd_q` changes only in `IDLE`. `a_P8_sync`: `$rose(req_q) ⇒ ¬ack_s`. `a_P4_sync`: `$fell(req_q) ⇒` the previous state was `ACK_SEEN`. `a_S3`: `rsp_q` loads only on the `REQ_HIGH ∧ ack_s` edge. |
| 10 | Trace | D3 §3.3, §4 (S1–S5) |

**FSM, cycle-exact** (in this table, "edge k" means the `posedge` that ends cycle k):

| State | `req_o` | `cmd_o` | Action at the end of the cycle | Next |
|---|---|---|---|---|
| `IDLE` | 0 | held | If `cmd_valid_i ∧ cmd_ready_o`: `cmd_q ← cmd_i` | `LATCH_CMD` |
| `LATCH_CMD` | 0 | stable ≥ 1 cycle | `req_q ← 1` (S1: data flops loaded one edge before `req`) | `REQ_HIGH` |
| `REQ_HIGH` | 1 | stable | If `ack_s = 1`: **`rsp_q ← rsp_rdata_i`** (S3) | `ACK_SEEN` |
| `ACK_SEEN` | 1 | stable | `req_q ← 0` (S4) | `REQ_LOW` |
| `REQ_LOW` | 0 | **stable** | If `ack_s = 0`: `rsp_valid_o = 1` during this cycle (S5) | `IDLE` |

- **Why the `rsp_rdata_i` sample is safe.** `ack_s` reaches 1 two edges after `ack_i` rose, and `rsp_rdata_i` was valid before `ack↑` (P3). By the sampling edge, the data has therefore been stable for at least 2 clock periods.
- **[refinement of S4, stricter]** `cmd_q` is held until the FSM leaves `REQ_LOW`, not just until `ack_s = 1`. The async side's combinational `rsp_rdata` therefore remains stable through `req↓` (P3) without any async-side response register.
- Minimum latency from `cmd_valid` to `rsp_valid` is 6 cycles plus the async operation time.

### 4.6 `rvne_sync2`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `logic RESET_VAL = 1'b0` |
| 2 | Domain / reset | Clocked; `rst_ni` port (`rst_ni` for `u_rst_sync`, `rst_sync_n` for `u_ack_sync`) |
| 3 | Ports | `clk_i`, `rst_ni`, `d_i`(1), `q_o`(1) |
| 4–5 | Handshake / state | none / `ff1_q`, `ff2_q` with the `(* ASYNC_REG = "TRUE" *)` attribute |
| 6 | Sampling | `ff1_q ← d_i` and `ff2_q ← ff1_q` at `posedge clk_i`; `q_o = ff2_q` |
| 7 | Output validity | Always valid. It follows `d_i` with a latency of 2 edges. |
| 8 | Reset | `ff1_q = ff2_q = RESET_VAL`, asserted asynchronously |
| 9 | Assertions | none |
| 10 | Trace | D3 S2, T5, R4 |

### 4.7 `rvne_bridge_async`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `realtime D_DEC, D_SPM, D_WR` |
| 2 | Domain / reset | Async (no clock); raw `rst_ni` |
| 3 | Ports | **Boundary:** in `req_i`(1), out `ack_o`(1). **To exec:** out `p_spm_o`(1), `p_wr_o`(1). **Checker inputs** (simulation only; already present at the top level): `cmd_i`(54), `rsp_rdata_i`(32), plus the exec/SPM window signals listed in W1/W2. |
| 4 | Handshake | 4-phase slave, defined by the event contract below |
| 5 | State | Delay-chain nodes `s1`, `s2`, `s3`; the `u_ack_c` C-element state (= `ack_o`) |
| 6 | Sampling | Event-driven: transitions of `req_i` only |
| 7 | Output validity | `rsp_rdata` (from `rvne_exec`) is valid and **stable from `ack↑` until `req↓`** (contract in §4.10; checked by `a_P3`). Strobes are open only inside the windows defined below. |
| 8 | Reset | `rst_ni = 0` forces `s1 = s2 = s3 = 0` **immediately** (§4.9) and `ack_o = 0` (R2) |
| 9 | Assertions | See the event-checker list below |
| 10 | Trace | D3 §3.3 (P1–P8), §5.1 (A1–A5), §5.2 (T1–T3), §6 (R2) |

**Structure.** The chain is `s1 = delay(req_i, D_DEC)`, `s2 = delay(s1, D_SPM)`, `s3 = delay(s2, D_WR)`. The strobes are `p_spm_o = s1 ∧ ¬s2` and `p_wr_o = s2 ∧ ¬s3`, and `ack_o = C(req_i, s3)`.

**Event contract** (times are relative to `req↑` at t = 0, with default parameters):

| # | Event | Cause | Guarantee |
|---|---|---|---|
| E0 | Idle | — | `req = ack = s1..3 = 0`, both strobes 0 (P1) |
| E1 | `req↑` | sync side | `cmd` is stable (P2, S1) |
| E2 | `s1↑` at `D_DEC` | delay | `rvne_exec` decode and routing have settled (T1: `D_DEC ≥ T_EXEC`). **`p_spm` opens.** |
| E3 | `s2↑` at `D_DEC + D_SPM` | delay | **`p_spm` closes.** The SPM write is complete, and the SPM row read data is valid (T2: `D_SPM ≥ T_SPM`). **`p_wr` opens.** |
| E4 | `s3↑` at `D_DEC + D_SPM + D_WR` | delay | **`p_wr` closes.** The WVR/SVR latches hold their new values (T3). |
| E5 | `ack↑` | `C(req = 1, s3 = 1)` | The effect is complete (P5), and `rsp_rdata` is valid and held. It stays held because `cmd` is unchanged (§4.5 refinement) and no strobe can open (P6). |
| E6 | `req↓` | sync side | — |
| E7 | `s1↓`, `s2↓`, `s3↓` in order | delay | Both strobes stay 0: `p_spm = s1 ∧ ¬s2` with `s1` already 0, and `p_wr = s2 ∧ ¬s3` with `s3` still 1 until `s2` has fallen (P6) |
| E8 | `ack↓` | `C(req = 0, s3 = 0)` | Return to zero is complete. A new `req↑` is legal (P8). |

**Event checkers** (immediate assertions, `` `ifndef SYNTHESIS ``):

| Name | Check |
|---|---|
| `a_P4_ack_rise` | At `ack↑`: `req = 1` |
| `a_P4_ack_fall` | At `ack↓`: `req = 0` |
| `a_P4_req_fall` | At `req↓`: `ack = 1` |
| `a_P8` | At `req↑`: `ack = 0` |
| `a_P2` | On any change of `cmd`: `¬(req ∧ ¬ack)` |
| `a_P3` | On any change of `rsp_rdata`: `¬(ack ∧ req)` |
| `a_P5` | At `ack↑`: `p_spm = p_wr = 0` |
| `a_P6` | At `p_spm↑` or `p_wr↑`: `req ∧ ¬ack` |
| `a_W1` | SPM write inputs (`spm_bank_we` select, `row_addr`, `wdata`) do not change while `p_spm = 1`, and last changed strictly before `p_spm↑` |
| `a_W2` | Vector write inputs (`wvr_we`/`svr_we` select, `vec_wdata`) do not change while `p_wr = 1`, and last changed strictly before `p_wr↑` |
| `a_P7` | At `p_spm↑` or `p_wr↑`: `cmd.op` is not reserved |

W1 and W2 are the delay-violation detectors for the D3 §5.2 shrink test, together with P3, which covers late read data (call it W3).

### 4.8 `rvne_c_element`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | none |
| 2 | Domain / reset | Async; `rst_ni` |
| 3 | Ports | `rst_ni`, `a_i`(1), `b_i`(1), `c_o`(1) |
| 4–5 | Handshake / state | — / `c_q` |
| 6 | Sampling | Level-sensitive: `always_latch if (!rst_ni) c_q = 0; else if (a_i == b_i) c_q = a_i;` |
| 7 | Output validity | `c_o = c_q`. It changes only when both inputs agree, and holds otherwise. |
| 8 | Reset | `c_q = 0` |
| 9 | Assertions | none (covered by `a_P4_*`) |
| 10 | Trace | D3 §5.1. This style is on the DEC-11 xsim watch-list. |

### 4.9 `rvne_delay`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `realtime D = 1.0` |
| 2 | Domain / reset | Async; `rst_ni` |
| 3 | Ports | `rst_ni`, `in_i`(1), `out_o`(1) |
| 4–5 | Handshake / state | none / none |
| 6 | Behaviour | Simulation: `assign #(D) d = in_i; assign out_o = rst_ni & d;`. `d` is an inertial delay of `in_i`. The immediate reset comes from the **output gating**, not from the delay node: the internal `d` is not cleared by reset and may stay high, or have a transition still scheduled, while `rst_ni = 0`, but `out_o` is forced to 0 for as long as `rst_ni = 0`. Once reset releases, `out_o` follows `d`, which by then has settled to the (reset-forced-low) input of this stage after `D`. Synthesis: `out_o = rst_ni & in_i` placeholder (DEC-10); it gives **no timing guarantee**. |
| 7 | Output validity | `out_o` follows `in_i` after `D` when out of reset |
| 8 | Reset | `out_o = 0` while `rst_ni = 0` |
| 9 | Assertions | none |
| 10 | Trace | D3 §5.2; DEC-10 |

### 4.10 `rvne_exec` (routing only; DEC-15)

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `realtime T_EXEC` (simulation-only delay applied to all outputs) |
| 2 | Domain / reset | Async; **combinational**, no state, no reset |
| 3 | Ports | **In:** `cmd_i`(54, the boundary bundle), `p_spm_i`(1), `p_wr_i`(1), `spm_row_i`(16×32), `wvr_q_i`(16×32), `svr_q_i`(16×32). **Out:** `spm_row_addr_o`(8), `spm_bank_we_o`(16), `spm_wdata_o`(32), `wvr_we_o`(16), `svr_we_o`(16), `vec_wdata_o`(16×32), `rsp_rdata_o`(32). |
| 4 | Handshake | None. Strobes come in and gated enables go out (A5). |
| 5 | State | None |
| 6 | Sampling | — |
| 7 | Output validity | Outputs are valid `T_EXEC` after their inputs settle (functions in the table below). **Direct contract:** `rsp_rdata_o` must remain stable from `ack_o↑` until `req_i↓` (D3 P3, needed for S3). This holds because `rsp_rdata_o` depends only on `cmd_i`, `spm_row_i`, `wvr_q_i` and `svr_q_i`; `rvne_bridge_sync` holds `cmd` constant until after `ack↓` (§4.5); and no strobe opens between `ack↑` and the next `req↑` (P6), so the SPM, WVR and SVR do not change. `rsp_rdata_o` must **not** depend on `req_i`, `ack_o`, `p_spm_i` or `p_wr_i`. |
| 8 | Reset | — |
| 9 | Assertions | `a_P7` (also in §4.7) |
| 10 | Trace | D4 §3; D3 A2–A5; D1 §2 |

| Output | Function |
|---|---|
| `spm_row_addr_o` | `cmd.addr[13:6]` |
| `spm_bank_we_o[b]` | `p_spm ∧ (op == OP_SPM_SW) ∧ (b == addr[5:2])` |
| `spm_wdata_o` | `cmd.wdata` |
| `n` (internal) | `OP_L?_*`: 1 / 4 / 16 for lw / lh / la; 0 otherwise |
| `wvr_we_o[e]` | `p_wr ∧ op ∈ {LW_WV, LH_WV, LA_WV} ∧ idx ≤ e < idx + n` |
| `svr_we_o[e]` | `p_wr ∧ op ∈ {LW_SV, LH_SV, LA_SV} ∧ idx ≤ e < idx + n` |
| `vec_wdata_o[e]` | `spm_row[addr[5:2] + (e − idx)]` (meaningful only where `we[e]`; alignment guarantees the bank index is in range) |
| `rsp_rdata_o` | `OP_SPM_LW` → `spm_row[addr[5:2]]`; `OP_RD_WV` → `wvr_q[idx]`; `OP_RD_SV` → `svr_q[idx]`; otherwise `32'h0` |

### 4.11 `rvne_spm`

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | `realtime T_SPM` (simulation-only read access delay) |
| 2 | Domain / reset | Async; **no reset** (DEC-13) |
| 3 | Ports | in `row_addr_i`(8), `bank_we_i`(16), `wdata_i`(32); out `row_o`(16×32) |
| 4 | Handshake | None (driven by strobe-gated enables) |
| 5 | State | `mem[16][256]` × 32 b, one array per bank |
| 6 | Sampling | **Write, on window entry [refinement]:** at `bank_we_i[b]↑` (i.e. `p_spm↑` for the selected bank), bank `b` samples `row_addr_i` and `wdata_i` and writes `mem[b][row_addr_i]`. The write remains effective for the duration of the window; the location does **not** track `wdata_i` while the window is open. This is safe because `a_W1` guarantees that `row_addr_i` and `wdata_i` last changed strictly before `p_spm↑` and do not change while it is open. **Read:** `row_o[b] = mem[b][row_addr_i]`, combinational, delayed by `T_SPM`. |
| 7 | Output validity | `row_o` is valid `T_SPM` after `row_addr_i` (or a written word) settles |
| 8 | Reset | None. Contents are X in simulation, the RTL equivalent of D5's `UNDEF`. |
| 9 | Assertions | `a_one_bank`: `$onehot0(bank_we_i)` |
| 10 | Trace | D1 §2; D3 A2; DEC-13. A behavioural SRAM model (edge-sampled write: `always @(posedge bank_we_i[b])`, simulation and RTL alike); a real macro is for DEC-10. |

### 4.12 `rvne_wvr` / `rvne_svr` (identical structure, separate modules)

| # | Item | Specification |
|---|---|---|
| 1 | Parameters | none (`N = 16`, width 32 from `rvne_pkg`) |
| 2 | Domain / reset | Async; raw `rst_ni` |
| 3 | Ports | in `rst_ni`, `we_i`(16), `wdata_i`(16×32); out `q_o`(16×32) |
| 4 | Handshake | None |
| 5 | State | `q[16]` × 32 b latches |
| 6 | Sampling | Per entry: `always_latch if (!rst_ni) q[e] = '0; else if (we_i[e]) q[e] = wdata_i[e];` |
| 7 | Output validity | `q_o = q`, always (the full contents, for read-back mux and future compute) |
| 8 | Reset | All entries 0 (D4 §1) |
| 9 | Assertions | `a_we_window`: `we_i ≠ 0 ⇒` the corresponding `p_wr = 1` (checked at the top level) |
| 10 | Trace | D4 §1, §3, §4; D3 A3 |

---

## 5. Simulation scaffolding

| File | Purpose |
|---|---|
| `sim/filelist.f` | Compile order: `rvne_pkg.sv` first, then leaves, then `rvne_top.sv` |
| `sim/run_xsim.bat <tb>` | Calls `C:\Xilinx\Vivado\2022.1\settings64.bat`, then `xvlog -sv -f filelist.f <tb>.sv`, then `xelab <tb> -debug typical`, then `xsim <tb> -R` |
| `sim/tb_rvne_decoder.sv` | Issue decode vs `vectors/issue.hex` |
| `sim/tb_rvne_bridge.sv` | `rvne_bridge_sync` + async half + exec + storage, driven at the decoder→bridge interface; vs `vectors/txn.hex` |
| `sim/tb_rvne_top.sv` | CV32A60X driver model (unsplit register, same-cycle commit, `kill = 0`, compressed offers) vs `vectors/txn.hex` |
| `model/export_vectors.py` | Serialises D5 results only (no behaviour): `issue.hex` `{instr, accept, writeback, register_read}`; `txn.hex` `{instr, rs1, rs2, has_cmd, cmd, has_result, we, rd, data_or_X}`; final WVR/SVR dump. `UNDEF` is emitted as an X marker that the testbench skips. |

## 6. Bring-up order

| Step | Content | xsim exit criterion |
|---|---|---|
| D6.1 | All modules with ports per §4; bodies stubbed (`issue_ready = 0`, `ack = 0`, `compressed_ready = 1`) | `xelab` of `rvne_top` with no port or width warnings; `$bits` checks pass |
| D6.2 | `rvne_if` | `tb_rvne_top`: X1–X4 and `a_tieoff` hold; an offered compressed instruction completes without stall |
| D6.3 | Decoder issue decode | 100 % match with `issue.hex`: D2 §2.2 and §5.1 cases, plus a sweep of every custom-0/1 funct3 × idx × rs1/imm-field combination |
| D6.4 | Decoder FSM, `rvne_status`, `rvne_bridge_sync` against a behavioural 4-phase responder | Commands and results match `txn.hex`; all clocked assertions hold |
| D6.5 | `rvne_c_element`, `rvne_delay`, `rvne_bridge_async` | P1–P8 checkers hold; shrink tests (`D_DEC < T_EXEC`, `D_SPM < T_SPM`) make W1/W2/P3 fire |
| D6.6 | `rvne_exec`, `rvne_spm`, `rvne_wvr`, `rvne_svr` | D4 V1–V5 register contents |
| D6.7 | `rvne_top` | D2 §8 program and all of `txn.hex` end to end; final WVR/SVR match D5 |
