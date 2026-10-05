# D6 Implementation Notes

Tool and process observations made while realising D6. **None of these changes the architecture or the frozen RTL contract** ([rtl_module_spec.md](rtl_module_spec.md)). Anything that does goes into [decisions.md](decisions.md) instead.

## N-1 — Bring-up regrouping of D6.3 / D6.4 (2026-10-05)

`rtl_module_spec.md` §6 schedules the decoder issue decode for D6.3, and the decoder FSM plus `rvne_status` together with `rvne_bridge_sync` for D6.4. As agreed at review:

- **D6.3** = all of `rvne_decoder` (classification + FSM + command formation) plus `rvne_status`. It is tested with a testbench stand-in for the bridge (`sim/tb_rvne_decoder.sv`).
- **D6.4** = `rvne_bridge_sync` only. It is tested against the command stream proven in D6.3.

Every module contract and exit criterion in §4/§6 is unchanged; only the step boundary moved.

## N-2 — xsim 2022.1 findings (DEC-11 watch-list)

| # | Finding | Scope | Handling |
|---|---|---|---|
| X-a | Concurrent SVA with `disable iff`, `|->` and `|=>` works, and failures are reported with the action-block text. | RTL assertions | Confirmed (D6.2, D6.3) |
| X-b | **Boolean `->` inside a property is unsupported and the property is silently ignored** (XSIM 43-4455: "Unsupported feature … 'implication operator'. It will be ignored.") | RTL assertions | Write Boolean implication as `!a \|\| b`. Treat any build warning as a failure (the runners do). `a_cmd_wellformed` was rewritten and then shown to fire under fault injection (`run_d63.py`, FAULT=1). |
| X-c | Sensitivity on an associative array is unsupported (XSIM 43-3980) | Testbench only | Use explicit sensitivity (`always @(issue_instr)`) |
| X-d | `xsim`/`xvlog` are `.bat` wrappers, and `cmd` splits unquoted arguments at `=` | Scripts | Quote plusargs: `-testplusarg "MODE=1"` |
| X-e | `force`/`release` on a variable that `always_comb` drives keeps the forced value until that block's inputs next change | Testbench fault injection | Expected SystemVerilog semantics; explains the double `a_tieoff` report in D6.2 MODE=5 |
| X-f | A hierarchical reference cannot name a type (`dut.state_e'(…)`, VRFC 10-8358) | Testbench only | Force enum state with a sized literal and a comment naming the state |
| X-g | Concurrent assertions sample preponed values, so a fault injected in the first cycle of a state can be invisible to `$fell`/`$past` (FAULT=3 initially missed `a_P4_sync`) | Testbench fault injection | Expected SVA semantics; inject at least one cycle into the state |

Rule derived from X-b: **every assertion added in D6 must be shown to fire at least once under deliberate fault injection.** Passing quietly is not evidence that it is checking anything.

Fault-injection coverage so far:
- Shown to fire: `a_X1`–`a_X4`, `a_tieoff`, `a_cmd_wellformed`, `a_S1`, `a_P8_sync`, `a_P4_sync`, `a_S3`, `a_rsp_pulse`.
- **Outstanding:** `a_issue_ready_state`, `a_cmd_stable`, `a_result_stable`, `a_one_cmd`, `a_err_xor_clr`, `a_rsp_in_wait` (decoder), and `a_set_clr_excl`, `a_one_err` (status). These all compile without the X-b warning, so they are active, but none has yet been made to fire. To close before D6.7.

## N-3 — Erratum in rtl_module_spec.md §4.5 (informative text only)

§4.5 says: "Minimum latency from `cmd_valid` to `rsp_valid` is 6 cycles plus the async operation time." The FSM in that same section gives **7 edges** from the handshake edge to `rsp_valid` when the async time approaches 0:

| Edges | Step |
|---|---|
| +1 | `req` rises |
| +2 | `ack_s` rises |
| +1 | sample |
| +1 | `req` falls |
| +2 | `ack_s` falls |

D6.4 measures exactly 7 (directed D1). The normative FSM table is correct; only the informative latency sentence is off by one. It changes no behaviour. To be corrected through a decision entry if the frozen text is to be edited.

## N-4 — Verification status

| Step | Runner | Result |
|---|---|---|
| D6.1 | `run_xsim.bat rvne_top elab` | Elaborates with no warnings; `$bits` guard fires on a wrong layout |
| D6.2 | `python sim/run_d62.py` | 46,089 issue vectors through the adapter; X1–X4 and `a_tieoff` each fire under injection |
| D6.3 | `python sim/run_d63.py` | Part A 46,089/46,089 classifications across all 11 D2 §5.1 categories; Part B 8,126/8,126 transactions (6,691 bridge commands, 896 operand errors with no command, 294 rejections, 245 STATUS reads); `a_cmd_wellformed` fires under injection; D6.2 regression passes |
| D6.4 | `python sim/run_d64.py` | All 6,691 D6.3-proven commands plus 59 directed transactions cross the boundary with the exact D5 response; the cycle schedule (S1–S5) is checked on 6,749 transactions with `ack` at arbitrary phases (0.1–60 ns); fast-path latency is exactly 7 edges; spurious `ack` holds off `cmd_ready`; reset mid-transaction aborts with no `rsp_valid`; all 5 bridge assertions fire alone under injection; D6.3/D6.2 regression passes |
