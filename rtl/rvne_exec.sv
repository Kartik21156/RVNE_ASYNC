// RVNE-ASYNC — async-domain routing (no execution engine, DEC-15).
// Contract: docs/rtl_module_spec.md §4.10.
// D6.1 STUB: ports only; all enables and data 0.
`timescale 1ns/1ps

module rvne_exec
  import rvne_pkg::*;
#(
  parameter realtime T_EXEC = 0.3
) (
  input  bridge_cmd_t cmd_i,
  input  logic        p_spm_i,
  input  logic        p_wr_i,
  input  vec_t        spm_row_i,
  input  vec_t        wvr_q_i,
  input  vec_t        svr_q_i,
  output logic [7:0]  spm_row_addr_o,
  output logic [15:0] spm_bank_we_o,
  output logic [31:0] spm_wdata_o,
  output logic [15:0] wvr_we_o,
  output logic [15:0] svr_we_o,
  output vec_t        vec_wdata_o,
  output logic [31:0] rsp_rdata_o
);

  assign spm_row_addr_o = '0;
  assign spm_bank_we_o  = '0;
  assign spm_wdata_o    = '0;
  assign wvr_we_o       = '0;
  assign svr_we_o       = '0;
  assign vec_wdata_o    = '0;
  assign rsp_rdata_o    = '0;

endmodule
