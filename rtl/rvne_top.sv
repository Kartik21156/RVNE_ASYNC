// RVNE-ASYNC — top-level integration. Contract: docs/rtl_module_spec.md §4.1, §2.
// Instances and wiring only. Clocked children use rst_sync_n; async children
// use raw rst_ni (§3.1). Only req/cmd/ack/rsp_rdata cross the async boundary.
`timescale 1ns/1ps

module rvne_top
  import rvne_pkg::*;
#(
  parameter type     cvxif_req_t  = rvne_pkg::cvxif_req_t,
  parameter type     cvxif_resp_t = rvne_pkg::cvxif_resp_t,
  parameter realtime D_DEC  = 1.0,
  parameter realtime D_SPM  = 2.0,
  parameter realtime D_WR   = 1.0,
  parameter realtime T_EXEC = 0.3,
  parameter realtime T_SPM  = 1.5
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  cvxif_req_t  cvxif_req_i,
  output cvxif_resp_t cvxif_resp_o
);

  // ------------------------------------------------------------ layout guard (§4.1 item 9)
  if ($bits(cvxif_req_t) != $bits(rvne_pkg::cvxif_req_t)) begin : g_req_bits_mismatch
    $error("rvne_top: $bits(cvxif_req_t) != $bits(rvne_pkg::cvxif_req_t) (CV-X-IF layout drift)");
  end
  if ($bits(cvxif_resp_t) != $bits(rvne_pkg::cvxif_resp_t)) begin : g_resp_bits_mismatch
    $error("rvne_top: $bits(cvxif_resp_t) != $bits(rvne_pkg::cvxif_resp_t) (CV-X-IF layout drift)");
  end

  // ------------------------------------------------------------ reset (§3.1)
  logic rst_sync_n;

  rvne_sync2 #(.RESET_VAL(1'b0)) u_rst_sync (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .d_i   (1'b1),
    .q_o   (rst_sync_n)
  );

  // ------------------------------------------------------------ rvne_if <-> rvne_decoder
  logic          issue_valid, issue_ready, issue_accept, issue_writeback;
  logic [31:0]   issue_instr;
  id_t           issue_id;
  hartid_t       issue_hartid;
  logic [31:0]   rs1, rs2;
  readregflags_t rs_valid, issue_register_read;
  logic          result_valid, result_ready, result_we;
  hartid_t       result_hartid;
  id_t           result_id;
  logic [31:0]   result_data;
  logic [4:0]    result_rd;

  rvne_if #(
    .cvxif_req_t (cvxif_req_t),
    .cvxif_resp_t(cvxif_resp_t)
  ) u_if (
    .clk_i                (clk_i),
    .rst_ni               (rst_sync_n),
    .cvxif_req_i          (cvxif_req_i),
    .cvxif_resp_o         (cvxif_resp_o),
    .issue_valid_o        (issue_valid),
    .issue_instr_o        (issue_instr),
    .issue_id_o           (issue_id),
    .issue_hartid_o       (issue_hartid),
    .rs1_o                (rs1),
    .rs2_o                (rs2),
    .rs_valid_o           (rs_valid),
    .result_ready_o       (result_ready),
    .issue_ready_i        (issue_ready),
    .issue_accept_i       (issue_accept),
    .issue_writeback_i    (issue_writeback),
    .issue_register_read_i(issue_register_read),
    .result_valid_i       (result_valid),
    .result_hartid_i      (result_hartid),
    .result_id_i          (result_id),
    .result_data_i        (result_data),
    .result_rd_i          (result_rd),
    .result_we_i          (result_we)
  );

  // ------------------------------------------------------------ rvne_decoder <-> rvne_bridge_sync
  logic        dec_cmd_valid, dec_cmd_ready, dec_rsp_valid;
  bridge_cmd_t dec_cmd;
  logic [31:0] dec_rsp_rdata;

  rvne_decoder u_decoder (
    .clk_i                (clk_i),
    .rst_ni               (rst_sync_n),
    .issue_valid_i        (issue_valid),
    .issue_instr_i        (issue_instr),
    .issue_id_i           (issue_id),
    .issue_hartid_i       (issue_hartid),
    .rs1_i                (rs1),
    .rs2_i                (rs2),
    .rs_valid_i           (rs_valid),
    .result_ready_i       (result_ready),
    .issue_ready_o        (issue_ready),
    .issue_accept_o       (issue_accept),
    .issue_writeback_o    (issue_writeback),
    .issue_register_read_o(issue_register_read),
    .result_valid_o       (result_valid),
    .result_hartid_o      (result_hartid),
    .result_id_o          (result_id),
    .result_data_o        (result_data),
    .result_rd_o          (result_rd),
    .result_we_o          (result_we),
    .cmd_valid_o          (dec_cmd_valid),
    .cmd_o                (dec_cmd),
    .cmd_ready_i          (dec_cmd_ready),
    .rsp_valid_i          (dec_rsp_valid),
    .rsp_rdata_i          (dec_rsp_rdata)
  );

  // ------------------------------------------------------------ async boundary (D3 §3.1)
  logic        req, ack;
  bridge_cmd_t cmd;
  logic [31:0] rsp_rdata;

  rvne_bridge_sync u_bridge_sync (
    .clk_i      (clk_i),
    .rst_ni     (rst_sync_n),
    .cmd_valid_i(dec_cmd_valid),
    .cmd_i      (dec_cmd),
    .cmd_ready_o(dec_cmd_ready),
    .rsp_valid_o(dec_rsp_valid),
    .rsp_rdata_o(dec_rsp_rdata),
    .req_o      (req),
    .cmd_o      (cmd),
    .ack_i      (ack),
    .rsp_rdata_i(rsp_rdata)
  );

  // ------------------------------------------------------------ async domain
  logic        p_spm, p_wr;
  logic [7:0]  spm_row_addr;
  logic [15:0] spm_bank_we, wvr_we, svr_we;
  logic [31:0] spm_wdata;
  vec_t        spm_row, wvr_q, svr_q, vec_wdata;

  rvne_bridge_async #(
    .D_DEC(D_DEC),
    .D_SPM(D_SPM),
    .D_WR (D_WR)
  ) u_bridge_async (
    .rst_ni (rst_ni),
    .req_i  (req),
    .ack_o  (ack),
    .p_spm_o(p_spm),
    .p_wr_o (p_wr)
  );

  rvne_exec #(.T_EXEC(T_EXEC)) u_exec (
    .cmd_i         (cmd),
    .p_spm_i       (p_spm),
    .p_wr_i        (p_wr),
    .spm_row_i     (spm_row),
    .wvr_q_i       (wvr_q),
    .svr_q_i       (svr_q),
    .spm_row_addr_o(spm_row_addr),
    .spm_bank_we_o (spm_bank_we),
    .spm_wdata_o   (spm_wdata),
    .wvr_we_o      (wvr_we),
    .svr_we_o      (svr_we),
    .vec_wdata_o   (vec_wdata),
    .rsp_rdata_o   (rsp_rdata)
  );

  rvne_spm #(.T_SPM(T_SPM)) u_spm (
    .row_addr_i(spm_row_addr),
    .bank_we_i (spm_bank_we),
    .wdata_i   (spm_wdata),
    .row_o     (spm_row)
  );

  rvne_wvr u_wvr (
    .rst_ni (rst_ni),
    .we_i   (wvr_we),
    .wdata_i(vec_wdata),
    .q_o    (wvr_q)
  );

  rvne_svr u_svr (
    .rst_ni (rst_ni),
    .we_i   (svr_we),
    .wdata_i(vec_wdata),
    .q_o    (svr_q)
  );

endmodule
