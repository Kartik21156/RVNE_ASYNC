// RVNE-ASYNC — bridge, asynchronous half (handshake control, no clock).
// Contract: docs/rtl_module_spec.md §4.7. Realises D3 §3.3 (P1–P8), §5.1, §5.2, §6 R2.
//
//   s1 = delay(req, D_DEC)   s2 = delay(s1, D_SPM)   s3 = delay(s2, D_WR)
//   p_spm = s1 & ~s2         (SPM write window,    width D_SPM, opens after decode, T1)
//   p_wr  = s2 & ~s3         (WVR/SVR write window, width D_WR, opens after SPM data, T2)
//   ack   = C(req, s3)       (rises after s3 with req high; falls after req and s3 low)
//
// On req fall the chain empties in order, and both strobes stay 0 (P6).
// rst_ni = 0 forces s1..s3 and ack to 0 immediately (rvne_delay output gating).
//
// The *_chk_i ports are simulation-only checker inputs (spec §4.7 item 3); they
// carry no function and are unused under SYNTHESIS.
`timescale 1ns/1ps

module rvne_bridge_async
  import rvne_pkg::*;
#(
  parameter realtime D_DEC = 1.0,
  parameter realtime D_SPM = 2.0,
  parameter realtime D_WR  = 1.0
) (
  input  logic        rst_ni,
  // boundary (D3 §3.1)
  input  logic        req_i,
  output logic        ack_o,
  // to rvne_exec
  output logic        p_spm_o,
  output logic        p_wr_o,
  // checker inputs (simulation only)
  input  bridge_cmd_t cmd_chk_i,
  input  logic [31:0] rsp_rdata_chk_i,
  input  logic [7:0]  spm_row_addr_chk_i,
  input  logic [31:0] spm_wdata_chk_i,
  input  logic [15:0] spm_bank_we_chk_i,
  input  logic [15:0] wvr_we_chk_i,
  input  logic [15:0] svr_we_chk_i,
  input  vec_t        vec_wdata_chk_i
);

  logic s1, s2, s3;

  rvne_delay #(.D(D_DEC)) u_d_dec (.rst_ni(rst_ni), .in_i(req_i), .out_o(s1));
  rvne_delay #(.D(D_SPM)) u_d_spm (.rst_ni(rst_ni), .in_i(s1),    .out_o(s2));
  rvne_delay #(.D(D_WR))  u_d_wr  (.rst_ni(rst_ni), .in_i(s2),    .out_o(s3));

  rvne_c_element u_ack_c (.rst_ni(rst_ni), .a_i(req_i), .b_i(s3), .c_o(ack_o));

  assign p_spm_o = s1 & ~s2;
  assign p_wr_o  = s2 & ~s3;

`ifndef SYNTHESIS
  // ================================================================ event checkers (§4.7)
  // Immediate assertions in event-triggered blocks; all disabled in reset.
  // Where a check depends on combinational outputs of the same event, it is
  // evaluated 1 ps after the event so the zero-delay network has settled.
  localparam realtime SETTLE = 0.001;   // 1 ps

  // P4 / P8: handshake order
  always @(posedge ack_o) if (rst_ni)
    a_P4_ack_rise: assert (req_i === 1'b1)
      else $error("a_P4_ack_rise violated: ack rose while req = 0");
  always @(negedge ack_o) if (rst_ni)
    a_P4_ack_fall: assert (req_i === 1'b0)
      else $error("a_P4_ack_fall violated: ack fell while req = 1");
  always @(negedge req_i) if (rst_ni)
    a_P4_req_fall: assert (ack_o === 1'b1)
      else $error("a_P4_req_fall violated: req fell before ack rose");
  always @(posedge req_i) if (rst_ni)
    a_P8: assert (ack_o === 1'b0)
      else $error("a_P8 violated: req rose before ack returned to 0");

  // P2 / P3: bundled data stability
  always @(cmd_chk_i) if (rst_ni)
    a_P2: assert (!(req_i && !ack_o))
      else $error("a_P2 violated: command changed between req rise and ack rise");
  always @(rsp_rdata_chk_i) if (rst_ni)
    a_P3: assert (!(ack_o && req_i))
      else $error("a_P3 violated: response changed between ack rise and req fall");

  // P5: no write window open when ack rises
  always @(posedge ack_o) if (rst_ni) begin
    #(SETTLE);
    a_P5: assert (!p_spm_o && !p_wr_o)
      else $error("a_P5 violated: write strobe open at ack rise");
  end

  // P6: strobes open only between req rise and ack rise
  always @(posedge p_spm_o or posedge p_wr_o) if (rst_ni)
    a_P6: assert (req_i && !ack_o)
      else $error("a_P6 violated: write strobe opened outside req high / ack low");

  // P7: never open a window for a reserved op
  always @(posedge p_spm_o or posedge p_wr_o) if (rst_ni)
    a_P7: assert (cmd_chk_i.op <= OP_RD_SV)
      else $error("a_P7 violated: write window opened for reserved op");

  // W1: SPM write inputs settled strictly before p_spm rise and stable while open.
  // The bank-enable *select* is observed through the gated enable: a change of
  // spm_bank_we while p_spm is steadily high (not at its rising instant) is a
  // select change inside the window.
  realtime t_w1_last = -1.0, t_spm_rise = -1.0;
  always @(spm_row_addr_chk_i or spm_wdata_chk_i) begin
    t_w1_last = $realtime;
    if (rst_ni && p_spm_o)
      a_W1_data: assert (0) else $error("a_W1 violated: SPM address/data changed inside the p_spm window");
  end
  always @(posedge p_spm_o) if (rst_ni) begin
    t_spm_rise = $realtime;
    a_W1_setup: assert (t_w1_last < $realtime)
      else $error("a_W1 violated: SPM address/data not settled before p_spm rise");
  end
  always @(spm_bank_we_chk_i) if (rst_ni && p_spm_o && $realtime != t_spm_rise)
    a_W1_sel: assert (0) else $error("a_W1 violated: SPM bank select changed inside the p_spm window");

  // W2: vector write inputs, same scheme on the p_wr window.
  realtime t_w2_last = -1.0, t_wr_rise = -1.0;
  always @(vec_wdata_chk_i) begin
    t_w2_last = $realtime;
    if (rst_ni && p_wr_o)
      a_W2_data: assert (0) else $error("a_W2 violated: vector write data changed inside the p_wr window");
  end
  always @(posedge p_wr_o) if (rst_ni) begin
    t_wr_rise = $realtime;
    a_W2_setup: assert (t_w2_last < $realtime)
      else $error("a_W2 violated: vector write data not settled before p_wr rise");
  end
  always @(wvr_we_chk_i or svr_we_chk_i) if (rst_ni && p_wr_o && $realtime != t_wr_rise)
    a_W2_sel: assert (0) else $error("a_W2 violated: vector entry select changed inside the p_wr window");
`endif

endmodule
