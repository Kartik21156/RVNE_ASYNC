// RVNE-ASYNC — Muller C-element with reset. Contract: docs/rtl_module_spec.md §4.8.
// c_o goes to 1 when both inputs are 1, to 0 when both are 0, and holds otherwise.
// rst_ni = 0 forces c_o = 0 asynchronously (D3 R2).
`timescale 1ns/1ps

module rvne_c_element (
  input  logic rst_ni,
  input  logic a_i,
  input  logic b_i,
  output logic c_o
);

  logic c_q;

  always_latch begin
    if (!rst_ni)         c_q = 1'b0;
    else if (a_i == b_i) c_q = a_i;
  end

  assign c_o = c_q;

endmodule
