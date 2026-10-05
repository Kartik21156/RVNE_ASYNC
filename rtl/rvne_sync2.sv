// RVNE-ASYNC — 2-flop synchroniser. Contract: docs/rtl_module_spec.md §4.6.
// Realises D3 S2 (ack), T5, R4 (reset release). q_o follows d_i two edges later.
`timescale 1ns/1ps

module rvne_sync2 #(
  parameter logic RESET_VAL = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic d_i,
  output logic q_o
);

  (* ASYNC_REG = "TRUE" *) logic ff1_q;
  (* ASYNC_REG = "TRUE" *) logic ff2_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ff1_q <= RESET_VAL;
      ff2_q <= RESET_VAL;
    end else begin
      ff1_q <= d_i;
      ff2_q <= ff1_q;
    end
  end

  assign q_o = ff2_q;

endmodule
