// RVNE-ASYNC — bridge, clocked half: 4-phase bundled-data master.
// Contract: docs/rtl_module_spec.md §4.5. Realises D3 §3.3, §4 (S1–S5).
//
//   IDLE --cmd hs--> LATCH_CMD --> REQ_HIGH --ack_s--> ACK_SEEN --> REQ_LOW --!ack_s--> IDLE
//
//   S1  cmd_q loads on the IDLE handshake edge; req_q rises one edge later.
//       req_o / cmd_o are flop outputs with no logic after them.
//   S2  ack_i reaches the FSM only through u_ack_sync (ack_s).
//   S3  rsp_rdata_i is sampled exactly once: on the edge that ends the first
//       REQ_HIGH cycle with ack_s = 1.
//   S4  req_q falls in ACK_SEEN. [refinement, stricter] cmd_q is held until the
//       FSM leaves REQ_LOW, so the async side's combinational rsp_rdata stays
//       stable through req fall (D3 P3) without async-side storage.
//   S5  rsp_valid_o pulses in the REQ_LOW cycle in which ack_s = 0.
//   R4  cmd_ready_o also requires ack_s = 0, so a transaction never starts
//       while the async side is still returning to zero.
`timescale 1ns/1ps

module rvne_bridge_sync
  import rvne_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,
  // decoder side
  input  logic        cmd_valid_i,
  input  bridge_cmd_t cmd_i,
  output logic        cmd_ready_o,
  output logic        rsp_valid_o,
  output logic [31:0] rsp_rdata_o,
  // boundary (D3 §3.1)
  output logic        req_o,
  output bridge_cmd_t cmd_o,
  input  logic        ack_i,
  input  logic [31:0] rsp_rdata_i
);

  typedef enum logic [2:0] {S_IDLE, S_LATCH_CMD, S_REQ_HIGH, S_ACK_SEEN, S_REQ_LOW} state_e;

  state_e      state_q;
  logic        req_q;
  bridge_cmd_t cmd_q;
  logic [31:0] rsp_q;
  logic        ack_s;

  rvne_sync2 #(.RESET_VAL(1'b0)) u_ack_sync (
    .clk_i (clk_i),
    .rst_ni(rst_ni),
    .d_i   (ack_i),
    .q_o   (ack_s)
  );

  assign cmd_ready_o = (state_q == S_IDLE) && !ack_s;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      req_q   <= 1'b0;
      cmd_q   <= '0;
      rsp_q   <= '0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (cmd_valid_i && cmd_ready_o) begin
            cmd_q   <= cmd_i;
            state_q <= S_LATCH_CMD;
          end
        end
        S_LATCH_CMD: begin
          req_q   <= 1'b1;
          state_q <= S_REQ_HIGH;
        end
        S_REQ_HIGH: begin
          if (ack_s) begin
            rsp_q   <= rsp_rdata_i;
            state_q <= S_ACK_SEEN;
          end
        end
        S_ACK_SEEN: begin
          req_q   <= 1'b0;
          state_q <= S_REQ_LOW;
        end
        S_REQ_LOW: begin
          if (!ack_s) state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign req_o       = req_q;
  assign cmd_o       = cmd_q;
  assign rsp_valid_o = (state_q == S_REQ_LOW) && !ack_s;
  assign rsp_rdata_o = rsp_q;

`ifndef SYNTHESIS
  // S1 (+ S4 refinement): the boundary command changes only on the IDLE handshake edge.
  a_S1: assert property (@(posedge clk_i) disable iff (!rst_ni)
          !$stable(cmd_q) |-> $past(state_q) == S_IDLE)
        else $error("a_S1 violated: cmd_o changed outside the IDLE handshake");

  // P8: req rises only when the synchronised ack has returned to zero.
  a_P8_sync: assert property (@(posedge clk_i) disable iff (!rst_ni)
          $rose(req_q) |-> !$past(ack_s))
        else $error("a_P8_sync violated: req rose while ack_s = 1");

  // P4: req falls only from ACK_SEEN, i.e. after ack was observed.
  a_P4_sync: assert property (@(posedge clk_i) disable iff (!rst_ni)
          $fell(req_q) |-> $past(state_q) == S_ACK_SEEN)
        else $error("a_P4_sync violated: req fell before ack was observed");

  // S3: the response register loads only on the REQ_HIGH && ack_s edge.
  a_S3: assert property (@(posedge clk_i) disable iff (!rst_ni)
          !$stable(rsp_q) |-> ($past(state_q) == S_REQ_HIGH) && $past(ack_s))
        else $error("a_S3 violated: rsp sampled outside the REQ_HIGH/ack_s edge");

  // S5: rsp_valid is a single-cycle pulse.
  a_rsp_pulse: assert property (@(posedge clk_i) disable iff (!rst_ni)
          rsp_valid_o |=> !rsp_valid_o)
        else $error("a_rsp_pulse violated: rsp_valid high for more than one cycle");
`endif

endmodule
