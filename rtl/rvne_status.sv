// RVNE-ASYNC — STATUS register. Contract: docs/rtl_module_spec.md §4.4. Realises D2 §5.2, §6.
//   [0] ERR_ALIGN  sticky   [1] ERR_RANGE  sticky   [11:8] LAST_ERR_OP   [31:24] VERSION
// status_o is the registered value, so a read in the same cycle as clr_i returns
// the pre-clear value. clr_i clears ERR_* only; LAST_ERR_OP is kept.
`timescale 1ns/1ps

module rvne_status
  import rvne_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        err_set_i,
  input  logic        err_align_i,
  input  logic        err_range_i,
  input  logic [3:0]  err_op_i,
  input  logic        clr_i,
  output logic [31:0] status_o
);

  logic       err_align_q, err_range_q;
  logic [3:0] last_err_op_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      err_align_q   <= 1'b0;
      err_range_q   <= 1'b0;
      last_err_op_q <= 4'h0;
    end else if (err_set_i) begin
      err_align_q   <= err_align_q | err_align_i;
      err_range_q   <= err_range_q | err_range_i;
      last_err_op_q <= err_op_i;
    end else if (clr_i) begin
      err_align_q   <= 1'b0;
      err_range_q   <= 1'b0;
    end
  end

  assign status_o = {STATUS_VERSION, 12'h000, last_err_op_q, 6'b000000, err_range_q, err_align_q};

`ifndef SYNTHESIS
  a_set_clr_excl: assert property (@(posedge clk_i) disable iff (!rst_ni)
                    !(err_set_i && clr_i))
                  else $error("a_set_clr_excl violated: err_set and clr in the same cycle");
  a_one_err:      assert property (@(posedge clk_i) disable iff (!rst_ni)
                    err_set_i |-> (err_align_i ^ err_range_i))
                  else $error("a_one_err violated: err_set without exactly one error bit");
`endif

endmodule
