# D4 — WVR / SVR Specification

**Status:** Frozen — Phase 0 baseline (2026-10-05). Changes only via a new entry in [decisions.md](decisions.md).
**Depends on:** [architecture.md](architecture.md) §2 (parameters) · [instruction_spec.md](instruction_spec.md) §4 (instruction semantics)

**Acceptance criterion (spec §8):** a testbench can work out *exactly* what every load instruction must produce. Sections 3 to 5 are that definition, and §6 gives the worked vectors.

---

## 1. Organisation

| | WVR (Weight Vector Register) | SVR (Spike Vector Register) |
|---|---|---|
| Entries | `N_WVR` = 16 | `N_SVR` = 16 |
| Entry width | 32 b | 32 b |
| Total | 512 b | 512 b |
| Element | signed `W_BITS`-bit weight (default 4) | 1-bit spike (1 = spike) |
| Elements per entry | `32 / W_BITS` = 8 | 32 |
| Total elements | 128 weights | 512 spikes |
| Index field | `idx` (D2 §2), direct | `idx`, direct |
| Reset value | all entries 0 | all entries 0 |
| Implementation | latch array, async domain (D3 A3) | same |
| Read ports | `rvne.rdwv`; compute engine (Phase 3) | `rvne.rdsv`; compute engine |

## 2. Element layout inside an entry

**WVR.** For entry `i` and element `j` (with `0 ≤ j < 32/W_BITS`):

```
w(i, j) = signed( WVR[i][W_BITS*j + W_BITS-1 : W_BITS*j] )
global weight index n = i * (32/W_BITS) + j          # used by la.wv / lh.wv
```

With `W_BITS = 4`, weight 0 is in bits [3:0] and weight 7 is in bits [31:28]. In the SPM byte at address `a`, the low nibble holds the even-numbered weight and the high nibble the odd-numbered one.

**SVR.** For entry `i` and bit `j`:

```
spike(i, j) = SVR[i][j]
input neuron index = 32*i + j
```

In the SPM byte at address `a`, bit `t` is the spike of neuron `8*(a - EA_base) + t`, where `EA_base` is the load's EA and `EA_base` maps to SVR[idx].

**Changing `W_BITS`.** The bit layout of entries and the load semantics (§3) are defined in bits, so they do **not** change. Only the interpretation in this section changes. For example, with `W_BITS = 8`, entry `0x76543210` holds weights 0x10, 0x32, 0x54, 0x76.

## 3. Load semantics (normative)

Let `word(a)` = `{SPM[a+3], SPM[a+2], SPM[a+1], SPM[a]}` (little-endian). Let `R` be WVR for `*.wv` and SVR for `*.sv`. These apply only when the D2 legality checks pass; failing loads leave `R` unchanged (D2 §5).

| Instruction | Precondition (legal) | Entries written | Value |
|---|---|---|---|
| `lw.*  idx, EA` | `idx < 16`, `EA % 4 = 0` | `R[idx]` | `word(EA)` |
| `lh.*  idx, EA` | `idx ∈ {0,4,8,12}`, `EA % 16 = 0` | `R[idx+k]`, k = 0..3 | `word(EA + 4k)` |
| `la.*  0,   EA` | `idx = 0`, `EA % 64 = 0` | `R[k]`, k = 0..15 | `word(EA + 4k)` |

In terms of SPM structure (D1 §2):
- `lw` reads bank `EA[5:2]` of row `EA[13:6]`.
- `lh` reads banks `EA[5:4]*4 + 0..3` of that row.
- `la` reads the whole row: bank k → `R[k]`.

All other entries of `R`, and every entry of the other register file, are **unchanged**.

## 4. Write timing and visibility

- All entries written by a single load take their new values **before** that command's `ack↑` (D3 P5). No partial state is ever observable by a later instruction.
- Writes to WVR and SVR happen only for accepted loads, which CV32A60X commits in the issue cycle (D3 §2). Rejected loads have no effect.

## 5. Read-back

`rvne.rdwv rd, idx` returns `WVR[idx]` as a 32-bit value, and `rvne.rdsv rd, idx` returns `SVR[idx]`. Neither has side effects. These are the verification hooks D7 uses to check loads from software.

## 6. Worked vectors (seed for D5 reference model and D7 tests)

**Initial state:** after reset; then SPM row 1 (0x40–0x7F) is zeroed with `spm.sw`, then:

| `spm.sw` address | Data |
|---|---|
| 0x040 | `0x76543210` |
| 0x044 | `0xFEDCBA98` |
| 0x07C | `0x80000001` |
| 0x100 | `0x00008001` |

**V1: `la.wv 0, 0x40(x0)`**

| Entry | Value | Weights (`W_BITS = 4`) |
|---|---|---|
| WVR[0] | `0x76543210` | w0..w7 = 0, 1, 2, 3, 4, 5, 6, 7 |
| WVR[1] | `0xFEDCBA98` | w8..w15 = −8, −7, −6, −5, −4, −3, −2, −1 |
| WVR[2..14] | `0x00000000` | w16..w119 = 0 |
| WVR[15] | `0x80000001` | w120 = 1, w121..w126 = 0, w127 = −8 |

**V2: `lh.wv 4, 0x40(x0)`**, starting from reset: WVR[4] = `0x76543210`, WVR[5] = `0xFEDCBA98`, WVR[6] = WVR[7] = 0. All other entries stay 0.

**V3: `lw.sv 2, 0x100(x0)`**, starting from reset: SVR[2] = `0x00008001`, which means input neurons **64** and **79** spiked. All other SVR entries stay 0. WVR is untouched.

**V4: `lw.wv 3, 0x44(x0)`** after V1: WVR[3] = `0xFEDCBA98`. WVR[0..2] and WVR[4..15] keep their V1 values.

**V5: error cases** (each starting from the state after V1)

| Instruction | Result |
|---|---|
| `lh.wv 4, 0x44(x0)` | `ERR_ALIGN`; WVR unchanged |
| `la.sv 0, 0(x12)` with x12 = 0x4000 | `ERR_RANGE`; SVR unchanged |
| `lh.wv 5, 0x40(x0)` | rejected at issue (`idx % 4 ≠ 0`), giving an illegal-instruction trap |
| `lw.wv 16, 0x40(x0)` | rejected at issue (`idx[4] = 1`) |

V1 to V3 were checked by a script that recomputes them from the formulas in §2 and §3.
