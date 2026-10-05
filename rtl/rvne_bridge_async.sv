// RVNE-ASYNC — bridge, asynchronous half (handshake control).
// Contract: docs/rtl_module_spec.md §4.7.
// D6.1 STUB: ports and primitive instances only (delay chain + ack C-element);
// strobes and ack held low.
`timescale 1ns/1ps

module rvne_bridge_async
  import rvne_pkg::*;
#(
  parameter realtime D_DEC = 1.0,
  parameter realtime D_SPM = 2.0,
  parameter realtime D_WR  = 1.0
) (
  input  logic rst_ni,
  // boundary (D3 §3.1)
  input  logic req_i,
  output logic ack_o,
  // to rvne_exec
  output logic p_spm_o,
  output logic p_wr_o
);

  logic s1, s2, s3;
  logic ack_c;

  rvne_delay #(.D(D_DEC)) u_d_dec (.rst_ni(rst_ni), .in_i(req_i), .out_o(s1));
  rvne_delay #(.D(D_SPM)) u_d_spm (.rst_ni(rst_ni), .in_i(s1),    .out_o(s2));
  rvne_delay #(.D(D_WR))  u_d_wr  (.rst_ni(rst_ni), .in_i(s2),    .out_o(s3));

  rvne_c_element u_ack_c (.rst_ni(rst_ni), .a_i(req_i), .b_i(s3), .c_o(ack_c));

  assign ack_o   = 1'b0;
  assign p_spm_o = 1'b0;
  assign p_wr_o  = 1'b0;

endmodule
