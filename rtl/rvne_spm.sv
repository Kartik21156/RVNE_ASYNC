// RVNE-ASYNC — 16 KiB scratchpad (16 banks x 256 x 32 b), behavioural model.
// Contract: docs/rtl_module_spec.md §4.11.
// D6.1 STUB: ports only; read data 0, no storage.
`timescale 1ns/1ps

module rvne_spm
  import rvne_pkg::*;
#(
  parameter realtime T_SPM = 1.5
) (
  input  logic [7:0]  row_addr_i,
  input  logic [15:0] bank_we_i,
  input  logic [31:0] wdata_i,
  output vec_t        row_o
);

  assign row_o = '0;

endmodule
