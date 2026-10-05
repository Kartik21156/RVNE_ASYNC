// RVNE-ASYNC — Muller C-element with reset. Contract: docs/rtl_module_spec.md §4.8.
// D6.1 STUB: ports only; output held at 0.
`timescale 1ns/1ps

module rvne_c_element (
  input  logic rst_ni,
  input  logic a_i,
  input  logic b_i,
  output logic c_o
);

  assign c_o = 1'b0;

endmodule
