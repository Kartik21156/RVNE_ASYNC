// RVNE-ASYNC — CV-X-IF adapter (CV32A60X, CV-X-IF v1.0.0).
// Contract: docs/rtl_module_spec.md §4.2. Realises D3 §2, DEC-03, DEC-14.
//
// Combinational wiring only. clk_i/rst_ni are used by the assertions alone.
//   - issue + register are unsplit on CV32A60X: register_ready = issue_ready.
//   - commit is not forwarded (same-cycle commit, kill = 0); it is only checked.
//   - compressed interface tied off (DEC-14): ready = 1, accept = 0, instr = 0.
//   - no memory / memory-result interface exists in the pinned structs.
`timescale 1ns/1ps

module rvne_if
  import rvne_pkg::*;
#(
  parameter type cvxif_req_t  = rvne_pkg::cvxif_req_t,
  parameter type cvxif_resp_t = rvne_pkg::cvxif_resp_t
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  // CPU side
  input  cvxif_req_t    cvxif_req_i,
  output cvxif_resp_t   cvxif_resp_o,
  // decoder side: to decoder
  output logic          issue_valid_o,
  output logic [31:0]   issue_instr_o,
  output id_t           issue_id_o,
  output hartid_t       issue_hartid_o,
  output logic [31:0]   rs1_o,
  output logic [31:0]   rs2_o,
  output readregflags_t rs_valid_o,
  output logic          result_ready_o,
  // decoder side: from decoder
  input  logic          issue_ready_i,
  input  logic          issue_accept_i,
  input  logic          issue_writeback_i,
  input  readregflags_t issue_register_read_i,
  input  logic          result_valid_i,
  input  hartid_t       result_hartid_i,
  input  id_t           result_id_i,
  input  logic [31:0]   result_data_i,
  input  logic [4:0]    result_rd_i,
  input  logic          result_we_i
);

  // ------------------------------------------------------------ CPU -> decoder
  assign issue_valid_o  = cvxif_req_i.issue_valid;
  assign issue_instr_o  = cvxif_req_i.issue_req.instr;
  assign issue_id_o     = cvxif_req_i.issue_req.id;
  assign issue_hartid_o = cvxif_req_i.issue_req.hartid;
  assign rs1_o          = cvxif_req_i.register.rs[0];
  assign rs2_o          = cvxif_req_i.register.rs[1];
  assign rs_valid_o     = cvxif_req_i.register.rs_valid;
  assign result_ready_o = cvxif_req_i.result_ready;

  // ------------------------------------------------------------ decoder -> CPU
  always_comb begin
    cvxif_resp_o = '0;

    // DEC-14 compressed tie-off
    cvxif_resp_o.compressed_ready       = 1'b1;
    cvxif_resp_o.compressed_resp.instr  = '0;
    cvxif_resp_o.compressed_resp.accept = 1'b0;

    // issue + unsplit register
    cvxif_resp_o.issue_ready                = issue_ready_i;
    cvxif_resp_o.issue_resp.accept          = issue_accept_i;
    cvxif_resp_o.issue_resp.writeback       = issue_writeback_i;
    cvxif_resp_o.issue_resp.register_read   = issue_register_read_i;
    cvxif_resp_o.register_ready             = issue_ready_i;

    // result
    cvxif_resp_o.result_valid  = result_valid_i;
    cvxif_resp_o.result.hartid = result_hartid_i;
    cvxif_resp_o.result.id     = result_id_i;
    cvxif_resp_o.result.data   = result_data_i;
    cvxif_resp_o.result.rd     = result_rd_i;
    cvxif_resp_o.result.we     = result_we_i;
  end

  // ------------------------------------------------------------ platform assertions (D3 §2)
`ifndef SYNTHESIS
  logic issue_hs, issue_acc;
  assign issue_hs  = cvxif_req_i.issue_valid && cvxif_resp_o.issue_ready;
  assign issue_acc = issue_hs && cvxif_resp_o.issue_resp.accept;

  // X1: commit only together with an issue handshake, for the same instruction.
  a_X1: assert property (@(posedge clk_i) disable iff (!rst_ni)
          cvxif_req_i.commit_valid |->
            issue_hs &&
            (cvxif_req_i.commit.id     == cvxif_req_i.issue_req.id) &&
            (cvxif_req_i.commit.hartid == cvxif_req_i.issue_req.hartid))
        else $error("a_X1 violated: commit without same-cycle issue handshake or id/hartid mismatch");

  // X2: CV32A60X never kills an offloaded instruction.
  a_X2: assert property (@(posedge clk_i) disable iff (!rst_ni)
          cvxif_req_i.commit_valid |-> !cvxif_req_i.commit.commit_kill)
        else $error("a_X2 violated: commit_kill = 1");

  // X3: issue and register transactions are unsplit.
  a_X3: assert property (@(posedge clk_i) disable iff (!rst_ni)
          (cvxif_req_i.register_valid == cvxif_req_i.issue_valid) &&
          (!cvxif_req_i.issue_valid ||
             ((cvxif_req_i.register.id     == cvxif_req_i.issue_req.id) &&
              (cvxif_req_i.register.hartid == cvxif_req_i.issue_req.hartid))))
        else $error("a_X3 violated: register transaction split from issue");

  // X4: operands required by an accepted instruction are valid at acceptance.
  a_X4: assert property (@(posedge clk_i) disable iff (!rst_ni)
          issue_acc |->
            ((cvxif_req_i.register.rs_valid & cvxif_resp_o.issue_resp.register_read)
               == cvxif_resp_o.issue_resp.register_read))
        else $error("a_X4 violated: rs_valid does not cover register_read at acceptance");

  // DEC-14 tie-off is constant.
  a_tieoff: assert property (@(posedge clk_i) disable iff (!rst_ni)
          cvxif_resp_o.compressed_ready && (cvxif_resp_o.compressed_resp == '0))
        else $error("a_tieoff violated: compressed interface not tied off (DEC-14)");
`endif

endmodule
