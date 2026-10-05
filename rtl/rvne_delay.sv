// RVNE-ASYNC — matched delay element. Contract: docs/rtl_module_spec.md §4.9.
// D6.1 STUB: ports and parameter only; output held at 0.
`timescale 1ns/1ps

module rvne_delay #(
  parameter realtime D = 1.0
) (
  input  logic rst_ni,
  input  logic in_i,
  output logic out_o
);

  assign out_o = 1'b0;

endmodule
