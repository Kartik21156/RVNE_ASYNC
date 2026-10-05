// RVNE-ASYNC — Spike Vector Register, 16 x 32 b latch array.
// Contract: docs/rtl_module_spec.md §4.12.
// D6.1 STUB: ports only; contents read as reset value 0.
`timescale 1ns/1ps

module rvne_svr
  import rvne_pkg::*;
(
  input  logic        rst_ni,
  input  logic [15:0] we_i,
  input  vec_t        wdata_i,
  output vec_t        q_o
);

  assign q_o = '0;

endmodule
