# Decision Log

The project baseline (spec §17) requires architectural changes to be **explicit decisions**. Each entry below records one decision.

Status values:
- **Frozen**: decided for M1; change only through a new entry.
- **Open**: deliberately undecided.
- **Check**: decided, but needs confirmation against an external source.

| ID | Decision | Rationale | Status |
|---|---|---|---|
| DEC-01 | The coprocessor uses **bundled-data, 4-phase** asynchronous logic. | This is the spec's candidate protocol. It is single-rail, so it costs about half the wiring of QDI, and it can be simulated in standard SystemVerilog using `#` delay models. Timing assumptions are listed explicitly in D3 §5.2. | Frozen |
| DEC-02 | Vector data comes from a **local 16 KiB SPM** in the async domain (16 banks × 32 b, 512 b row). | All coprocessor memory traffic stays inside the async domain, so no bus crosses the clock boundary. This mirrors the paper's SPM (§IV-C). | Frozen |
| DEC-03 | **Host/coprocessor interface.** The host communicates with the RVNE command decoder over the **CV-X-IF v1.0.0 (ratified)** issue, commit and result interfaces exposed by CV32A60X. Instruction operands reach the decoder **in the issue cycle**: CVA6 drives the unsplit v1.0.0 register transaction with `register_valid = issue_valid`. **Commit is generated in the same cycle as an accepted issue**, `commit_valid = issue_valid && issue_ready`, with `commit_kill = 0` always. CV32A60X does not support speculative CV-X-IF execution, so RVNE has no commit-wait state and no kill path (D3 §2, assertions X1–X4). The compressed interface is present in the pinned RTL and driven by CVA6; the adapter ties it off with `compressed_ready = 1`, `accept = 0`, `instr = '0` (DEC-14). The memory and memory-result interfaces are not implemented by CV32A60X and are not connected. Adapter parameters: `X_NUM_RS = 2`, `X_ID_WIDTH = 2`, `X_RFR_WIDTH = 32`, `X_RFW_WIDTH = 32`. CV-X-IF terminates at the clocked RVNE command decoder. The asynchronous boundary begins only after legality checking and architectural command formation (D1 §4, D3 §3). | It is the ratified OpenHW coprocessor interface, so no core fork is needed. v1.0.0 rules: `accept` may depend only on `instr`; each accepted, committed instruction gets exactly one result. Verified against the v1.0.0 spec text and CVA6 `cv32a60x-v6.0.0` (`b1f80bd`): `cvxif_issue_register_commit_if_driver.sv`, `cvxif_fu.sv`, `cvxif_types.svh`, `id_stage.sv`, `cvxif_compressed_if_driver.sv`. Amended by DEC-14. | Frozen |
| DEC-04 | `W_BITS` = 4 (signed) in the architecture. It is an RTL parameter with default 4. Granularities are defined in bits. | This matches the 4-bit operand width the paper uses. Making it a parameter allows later quantisation studies without changing the ISA. | Frozen |
| DEC-05 | **Host processor: OpenHW CORE-V CV32A60X.** Pinned to configuration `CV32A60X`, release `cv32a60x-v6.0.0`, git commit `b1f80bd`, XLEN = 32. CV-X-IF v1.0.0 is enabled through `CVA6ConfigCvxifEn` (`CvxifEn = 1`). | CV32A60X provides a documented implementation of the ratified CV-X-IF v1.0.0 spec, supports two 32-bit source operands, and provides the issue, commit and result interfaces RVNE needs. M1 needs no XIF memory interface, because RVNE instructions access the coprocessor's local SPM. The larger CVA6-derived host is accepted deliberately, as the price of a ratified CV-X-IF and a mature 32-bit application-core configuration. This supersedes the earlier CV32E40X recommendation. | Frozen |
| DEC-06 | **Direct** WVR/SVR indexing: the `rd` field *is* the index. This deviates from the paper, which uses indirect indexing through a GPR. | M1 uses direct WVR/SVR indexing. The selected CV32A60X configuration provides two source operands, rs1 and rs2, which is enough for M1. Future indirect-indexed instructions that need an additional source operand would require a platform/configuration change to `X_NUM_RS = 3`, so they are not part of the frozen M1 interface. | Frozen for M1 |
| DEC-07 | Errors: **encoding errors** are rejected at issue (illegal-instruction trap). **Operand-value errors** make the instruction a no-op and set a sticky bit in `STATUS`. The async domain never sees an invalid command. | M1 does not report RVNE operand-value errors as exceptions. Encoding errors use `accept = 0`, which lets CVA6 generate its own illegal-instruction exception (`cvxif_fu.sv`: `x_exception_o.valid = x_illegal_i`). Operand-value errors are architecturally successful no-ops with sticky RVNE `STATUS` bits. Basis: `accept` may depend only on `instr` (v1.0.0), and the v1.0.0 result packet CVA6 consumes (`id`, `data`, `rd`, `we`) has no field for a coprocessor-originated exception. | Frozen |
| DEC-08 | M1 allows **one outstanding instruction**, executed in order. | Simplest correct ordering: no fences are needed and the protocol is easy to verify. Pipelining is deferred to the optimisation phase. | Frozen for M1 |
| DEC-09 | SPM fill is through the project-defined `spm.sw` instruction. Whether DMA fill is also needed is **undecided**. | `spm.sw` is enough for M1 tests and keeps everything inside the ISA. DMA is a bandwidth question for Phase 5 and later. | Open |
| DEC-10 | Implementation of matched delays on FPGA or ASIC (delay chains, constrained LUT chains, or a clocked emulation). | Spec §13: FPGA is a later feasibility experiment. | Open |
| DEC-11 | **Simulator for M1: Vivado Simulator (xsim), Vivado 2022.1** (installed at `C:\Xilinx\Vivado\2022.1`; flow `xvlog -sv` → `xelab` → `xsim`). Testbenches compare RTL against D5 golden vectors exported from `model/rvne_reference.py` as files and read with `$readmemh` / `$fscanf`. No live Python co-simulation, because xsim has no supported cocotb/VPI flow. This decision holds unless D6 exposes a concrete incompatibility; any such incompatibility is recorded as a new entry that names the construct and the xsim error. | xsim is an event-driven simulator, so it honours `#` delays for the matched-delay models (D3 §5.2). It supports SystemVerilog assertions for D3 P1–P8 and X1–X4, it is already installed, and it is the same toolchain as the later FPGA feasibility work (DEC-10). Items to confirm while writing D6: the C-element `always @*` hold style, `#` delays inside modules, and concurrent SVA in the bridge. | Frozen (conditional on D6) |
| DEC-12 | Neuron model, synaptic-engine operation, NSR/SOR formats. | These belong to Phases 3–4 (spec §14). | Open |
| DEC-13 | SPM contents are **not reset** (undefined after power-up). WVR, SVR and `STATUS` are reset. | This is realistic for SRAM. Tests must initialise the SPM before reading it. | Frozen |

---

## Decisions raised during D6

Template: Problem · Evidence · Options · Decision · Impact. A **Proposed** entry does not change any frozen document until it is approved; once approved it is marked Frozen and the affected documents are updated citing it.

### DEC-14 — CV-X-IF compressed interface must be tied off, not left unconnected
**Status:** Frozen (approved 2026-10-05)

**Problem.** DEC-03, D1 §1/§4 and D3 §2 say the compressed CV-X-IF interface is "not implemented by CV32A60X and not connected by the RVNE adapter". **When CV-X-IF is enabled, the pinned CVA6 RTL instantiates the compressed-interface driver, which can stall when `compressed_ready` is low; therefore the RVNE adapter must provide a defined response even though M1 implements no compressed instructions.** For this implementation-specific decision the pinned RTL takes precedence over the CVA6 documentation.

**Evidence** (CVA6 `cv32a60x-v6.0.0`, `b1f80bd`):
- `core/include/cvxif_types.svh`: `CVXIF_REQ_T` has members `compressed_valid` and `compressed_req`; `CVXIF_RESP_T` has `compressed_ready` and `compressed_resp {instr[31:0], accept}`.
- `core/id_stage.sv`: `if (CVA6Cfg.CvxifEn) … cvxif_compressed_if_driver i_cvxif_compressed_if_driver_i (…)`, wired to `compressed_ready_i`/`compressed_resp_i`.
- `core/cvxif_compressed_if_driver.sv`:
  - `compressed_valid_o = is_illegal_i`, i.e. any 16-bit instruction CVA6's own decoder finds illegal is offered to the coprocessor.
  - `stall_o` depends on `~compressed_ready_i`.
  - `is_illegal_o = ~compressed_resp_i.accept`.
- `cv32a60x_config_pkg.sv`: `RVC: bit'(1)`, `CvxifEn: bit'(1)`.
- The CVA6 user doc (`CVX_Interface_Coprocessor.rst`) says the compressed interface is "not yet implemented". The pinned RTL contradicts that.

**Consequence if unconnected.** `compressed_ready` floats or is 0, so the core stalls fetch forever on the first illegal compressed instruction.

**Options.**
- (a) Tie off: `compressed_ready = 1`, `compressed_resp.accept = 0`, `compressed_resp.instr = '0`. The core then raises its normal illegal-instruction exception.
- (b) Implement compressed RVNE instructions. Rejected: none are defined.

**Decision.** (a). The adapter drives the tie-off constants. RVNE still defines no compressed instructions.

**Impact.**
- DEC-03: replace "not implemented … not connected" for the compressed interface with "present in the pinned RTL and driven by CVA6; tied off by the adapter with `ready = 1`, `accept = 0`". Memory and memory-result stay "not implemented / not connected"; their members are absent from `CVXIF_REQ_T`/`CVXIF_RESP_T`.
- D1 §1, §4 adapter row and host-side notes; D3 §2 bullet. No change to D2, D4 or D5.

### DEC-15 — RTL module decomposition and file names for D6
**Status:** Frozen (approved 2026-10-05)

**Problem.** D1 §4 maps blocks to the spec §9.2 file names (`rvne_coprocessor.sv`, `async_controller.sv`, `weight_loader.sv`, `spike_loader.sv`, `wvr.sv`, `svr.sv`, `rvne_async_if.sv`, `rvne_command_decoder.sv`). The agreed D6 layout uses different names and a different split.

**Evidence.** D6 module list as requested (2026-10-05), plus three support modules that D1/D3 already require (`rvne_pkg.sv` per D1 §2, `rvne_delay` per D3 §5.2, a 2-FF synchroniser per D3 S2/R4).

**Decision.** The RTL realises the D1 blocks with the files in [rtl_module_spec.md](rtl_module_spec.md) §2. Mapping:

| D1 §4 block | D6 file(s) |
|---|---|
| CV-X-IF adapter (`rvne_if.sv`) | `rvne_if.sv` |
| Command decoder (`rvne_command_decoder.sv`) | `rvne_decoder.sv` + `rvne_status.sv` |
| Bridge, sync half (`rvne_async_if.sv`) | `rvne_bridge_sync.sv` + `rvne_sync2.sv` |
| Bridge, async half + controller (`rvne_async_if.sv`, `async_controller.sv`) | `rvne_bridge_async.sv` + `rvne_c_element.sv` + `rvne_delay.sv` |
| Weight loader + spike loader | `rvne_exec.sv` (routing only) |
| SPM, WVR, SVR | `rvne_spm.sv`, `rvne_wvr.sv`, `rvne_svr.sv` |
| Top (`rvne_coprocessor.sv`) | `rvne_top.sv` |
| Parameters (`rvne_pkg.sv`) | `rvne_pkg.sv` |

Block responsibilities and the clocked/async partition are unchanged; only the files differ. File decomposition is not architectural decomposition.

`rvne_exec.sv` contains **no independent architectural execution engine** in M1. It performs routing and control between the decoded command and the async-domain resources (SPM, WVR, SVR). It is not a conventional synchronous execution unit.

**Impact.** D1 §4 "RTL file" column. Spec §9.2 file names are superseded for RTL (the docs/ and model/ names are unchanged).
