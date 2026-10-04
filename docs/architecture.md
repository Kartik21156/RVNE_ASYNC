# D1 — System Architecture Specification

**Project:** RVNE-ASYNC — asynchronous neuromorphic coprocessor for a RISC-V host
**Document:** D1, System Architecture Specification
**Status:** Frozen — Phase 0 baseline (2026-10-05). Changes only via a new entry in [decisions.md](decisions.md).
**Scope:** Milestone 1 (weight and spike loading). Blocks for later phases are shown as *reserved*.

Related documents:
[instruction_spec.md](instruction_spec.md) (D2) ·
[async_interface.md](async_interface.md) (D3) ·
[wvr_svr_spec.md](wvr_svr_spec.md) (D4) ·
[decisions.md](decisions.md)

---

## 1. Architectural position

| Aspect | Decision | Ref |
|---|---|---|
| Host processor | **OpenHW CORE-V CV32A60X**, synchronous, XLEN = 32. Release `cv32a60x-v6.0.0`, commit `b1f80bd`, `CVA6ConfigCvxifEn` enabled | DEC-05 |
| Host ↔ coprocessor link | **CV-X-IF v1.0.0 (ratified)**: the issue (with its unsplit register transaction), commit and result interfaces, which are the only ones CV32A60X implements. Operands arrive in the issue cycle. Commit is generated in the same cycle as an accepted issue, with `commit_kill = 0`. Terminates at the clocked command decoder | DEC-03 |
| Clock-domain boundary | Sync/async bridge carrying one **4-phase bundled-data** channel | DEC-01, D3 |
| Coprocessor | Asynchronous, bundled-data, 4-phase handshakes internally | DEC-01 |
| Coprocessor data source | **Local scratchpad memory (SPM)** inside the async domain | DEC-02 |
| Programming model | RVNE custom instructions in RISC-V custom-0 / custom-1 opcode space | D2 |
| Hardware classification | Heterogeneous hardware + unified RVNE programming interface + asynchronous neuromorphic execution | Spec §3.2 |

## 2. Frozen Milestone-1 parameters

This table is the **single source of truth** for parameter values. D2–D4 refer to these names and do not redefine them. It will be transcribed directly into `rtl/rvne_pkg.sv`.

| Name | Value | Meaning |
|---|---|---|
| `XLEN` | 32 | Host register width (CV32A60X) |
| `X_NUM_RS` | 2 | CV-X-IF source operands (rs1, rs2) |
| `X_ID_WIDTH` | 2 | CV-X-IF instruction ID width (at most 4 IDs in flight on the host side; RVNE accepts 1, D1 §6) |
| `X_RFR_WIDTH` | 32 | CV-X-IF register read width |
| `X_RFW_WIDTH` | 32 | CV-X-IF register write width |
| `W_BITS` | 4 (RTL parameter) | Synaptic weight width, signed two's complement |
| `WVR_ENTRY_BITS` | 32 | Bits per WVR entry |
| `N_WVR` | 16 | Number of WVR entries (512 b total) |
| `WEIGHTS_PER_ENTRY` | `WVR_ENTRY_BITS / W_BITS` = 8 | Derived |
| `SVR_ENTRY_BITS` | 32 | Bits per SVR entry (1 bit per spike) |
| `N_SVR` | 16 | Number of SVR entries (512 spikes total) |
| `SPM_BYTES` | 16384 (16 KiB) | Scratchpad size |
| `SPM_BANKS` | 16 | Banks, each 32 b wide |
| `SPM_ROW_BITS` | 512 | One row = one word from each bank |
| `SPM_ROWS` | 256 | `SPM_BYTES / 64` |
| `SPM_AW` | 14 | SPM byte-address width |
| SPM address split | bank = `a[5:2]`, row = `a[13:6]`, `a[1:0]` = byte in word | Word-interleaved |
| Byte order | Little-endian | Byte `a` → bits `[7:0]` of word |
| Load granularities | **lw** = 32 b (1 entry) · **lh** = 128 b (4 entries) · **la** = 512 b (16 entries) | Defined in bits, so they are independent of `W_BITS` |

These match the reference paper's configuration: 128 weights / 512 spikes for `la.*`, a 512 b WVR, and a 16 KiB, 16-bank SPM with 512 b bandwidth. With `W_BITS = 4` the weight counts are 8 / 32 / 128, the same as the paper's `lw.wv/lh.wv/la.wv`.

## 3. Block diagram

```
 ┌──────────────────────────── CLOCKED DOMAIN (clk_i) ─────────────────────────────┐
 │                                                                                 │
 │  ┌──────────────┐ CV-X-IF 1.0┌────────────────────────────────────────────────┐ │
 │  │  RISC-V host │ issue+rs ─►│ rvne_command_decoder  (rvne_if.sv adapter)     │ │
 │  │  CV32A60X    │ commit ───►│  • decodes custom-0 / custom-1                 │ │
 │  │  RV32 + RVNE │ (same cyc, │  • issue-time legality (accept / reject)       │ │
 │  │              │   kill=0)  │  • latches rs1/rs2 at accepted issue           │ │
 │  │              │ ◄── result │                                                │ │
 │  └──────────────┘            │  • operand checks → sticky STATUS (no-op)      │ │
 │                              │  • STATUS register (rvne.status)               │ │
 │                              └───────────────────────┬────────────────────────┘ │
 │                                                      │ cmd bundle / rsp bundle  │
 │                              ┌───────────────────────▼────────────────────────┐ │
 │                              │ rvne_async_if  — SYNC half                     │ │
 │                              │  flopped req · 2-FF ack synchroniser           │ │
 │                              └───────────────────────┬────────────────────────┘ │
 └──────────────────────────────────────────────────────┼──────────────────────────┘
          ══════════ req / ack + bundled data (D3) ═════╪═══════════ boundary
 ┌──────────────────────────────────────────────────────┼──────────────────────────┐
 │  ASYNCHRONOUS DOMAIN (no clock)                      │                          │
 │                              ┌───────────────────────▼────────────────────────┐ │
 │                              │ rvne_async_if — ASYNC half / async_controller  │ │
 │                              │  C-element handshake control, matched delays   │ │
 │                              └───┬───────────────┬───────────────┬────────────┘ │
 │                                  │               │               │              │
 │                      ┌───────────▼──┐   ┌────────▼──────┐  ┌─────▼──────────┐   │
 │                      │ SPM 16 KiB   │   │ weight_loader │  │ spike_loader   │   │
 │                      │ 16 × 32b bank│──►│  → wvr (16×32)│  │  → svr (16×32) │   │
 │                      └──────────────┘   └───────────────┘  └────────────────┘   │
 │                                                                                 │
 │   reserved (Phase 3–4):  synaptic engine · neuron/state engine · SOR · NSR      │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

## 4. Synchronous / asynchronous partition

| Block | Domain | RTL file (spec §9.2) | Responsibility |
|---|---|---|---|
| RISC-V host | Clocked | external (CV32A60X @ `b1f80bd`) | Runs software, offloads RVNE instructions over CV-X-IF v1.0.0, handles control flow and traps |
| CV-X-IF adapter | Clocked | `rvne_if.sv` | CV-X-IF v1.0.0 port bundle (`X_NUM_RS = 2`, `X_ID_WIDTH = 2`, `X_RFR_WIDTH = X_RFW_WIDTH = 32`): issue, register (unsplit), commit and result signals only. The compressed, memory and memory-result interfaces are not implemented by CV32A60X and are not present in the adapter |
| Command decoder | Clocked | `rvne_command_decoder.sv` | Issue-time decode and accept/reject; latches rs1/rs2, which arrive in the issue cycle; checks the platform commit assumptions with assertions (D3 §2); operand-value checks; owns the STATUS register; builds the bridge command; returns the X-IF result. **CV-X-IF terminates here** |
| Bridge, sync half | Clocked | `rvne_async_if.sv` | Drives `req` and the command bundle from flops; synchronises `ack`; captures the response bundle |
| Bridge, async half + controller | Async | `rvne_async_if.sv`, `async_controller.sv` | Accepts `req`, sequences SPM access and register writes through matched delays, raises `ack` with the response bundle |
| SPM | Async | inside `rvne_coprocessor.sv` (`spm` submodule) | 16 banks × 256 words; one row read or one word write per command |
| Weight loader | Async | `weight_loader.sv` | Routes SPM read data to the selected WVR entries; generates their write enables |
| Spike loader | Async | `spike_loader.sv` | Same as the weight loader, for SVR |
| WVR | Async | `wvr.sv` | 16 × 32 b latch array; read port for `rvne.rdwv` and future compute |
| SVR | Async | `svr.sv` | 16 × 32 b latch array; read port for `rvne.rdsv` and future compute |
| Top | Both | `rvne_coprocessor.sv` | Integrates everything; exposes CV-X-IF, `clk_i`, `rst_ni` |
| Synaptic engine, neuron engine, SOR | Async | reserved | Phase 3–4; not specified here |

**Partition rule.** CV-X-IF terminates at the clocked command decoder. Anything that depends on the CPU's instruction or register stream (decode, legality, commit, status) lives in the clocked domain. The asynchronous boundary begins only **after** legality checking and the formation of the architectural command (the bridge command bundle, D3 §3). As a result, the async domain only ever receives **legal, committed** commands and needs no error path in M1.

**Host-side notes.**
- **Compressed instructions.** The compressed CV-X-IF interface is not implemented by CV32A60X, so the RVNE adapter does not connect it. RVNE instructions are 32-bit uncompressed custom instructions. RVC being enabled in the CPU does not imply that the compressed XIF interface exists.
- **No speculation.** CV32A60X does not support speculative CV-X-IF execution. Its integration (`cvxif_issue_register_commit_if_driver.sv`) generates the commit transaction in the same cycle as an accepted issue, `commit_valid = issue_valid && issue_ready`, and always drives `commit_kill = 0`. An accepted instruction is therefore already committed, and RVNE needs no commit-wait or kill handling.
- **IDs.** With `X_ID_WIDTH = 2` the host can track up to 4 offloaded IDs, but RVNE accepts only one at a time (§6), so the decoder only needs to store the single active `id`.

## 5. Milestone-1 dataflow

```
 software                          clocked domain                    async domain
 ────────                          ──────────────                    ────────────
 spm.sw  x_data, off(x_base)  ──►  decode, accept, check EA      ──► SPM[EA] ← data
   … repeat to fill a region …
 la.wv   0, 0(x_base)         ──►  decode, accept, check EA      ──► row ← SPM[EA row]
                                                                      WVR[0..15] ← row
 lw.sv   3, 0x100(x0)         ──►  ...                           ──► SVR[3] ← SPM word
 rvne.rdwv x5, 1              ──►  ...                           ──► rdata ← WVR[1]
                              ◄──  X-IF result (rd=x5, we=1)     ◄── ack + rdata
```

## 6. Ordering and concurrency model (M1)

- **One outstanding instruction.** From the cycle the decoder accepts an instruction until its result transaction completes, the decoder holds `issue_ready = 0`.
- As a result, all RVNE instructions take effect in **program order**. A load that follows an `spm.sw` always sees the stored data, and `rvne.rdwv` always sees the latest `*.wv` load. Software needs no fences between RVNE instructions.
- RVNE instructions do **not** access host memory, so there is no ordering between them and ordinary RISC-V loads and stores. Data reaches the SPM only through `spm.sw`.
- Pipelining (more than one outstanding command) is deferred to a later phase. The bridge protocol (D3) does not preclude it.

## 7. Reset and clocking

- One active-low reset, `rst_ni`, asserted asynchronously to both domains. Its deassertion is synchronised to `clk_i` in the clocked domain. Details in D3 §6.
- The coprocessor has **no clock input** to its async domain. `clk_i` reaches only the decoder and the sync half of the bridge.

## 8. Out of scope for this document

The synaptic computation, neuron model, NSR/SOR formats, DMA fill of the SPM, and multi-outstanding pipelining. All are listed as open in [decisions.md](decisions.md).
