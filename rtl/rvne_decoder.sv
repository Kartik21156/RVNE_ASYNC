// RVNE-ASYNC — command decoder. Contract: docs/rtl_module_spec.md §4.3.
// Realises D2 §2–§7, D3 §2 (FSM), D1 §6 (one outstanding instruction), DEC-07.
//
// Issue classification (accept / writeback / register_read) is a function of
// issue_instr_i ONLY (DEC-07). Operand-value errors are detected in CHECK and
// never produce a bridge command: the async domain only sees legal commands.
`timescale 1ns/1ps

module rvne_decoder
  import rvne_pkg::*;
(
  input  logic          clk_i,
  input  logic          rst_ni,
  // from rvne_if
  input  logic          issue_valid_i,
  input  logic [31:0]   issue_instr_i,
  input  id_t           issue_id_i,
  input  hartid_t       issue_hartid_i,
  input  logic [31:0]   rs1_i,
  input  logic [31:0]   rs2_i,
  input  readregflags_t rs_valid_i,
  input  logic          result_ready_i,
  // to rvne_if
  output logic          issue_ready_o,
  output logic          issue_accept_o,
  output logic          issue_writeback_o,
  output readregflags_t issue_register_read_o,
  output logic          result_valid_o,
  output hartid_t       result_hartid_o,
  output id_t           result_id_o,
  output logic [31:0]   result_data_o,
  output logic [4:0]    result_rd_o,
  output logic          result_we_o,
  // to/from rvne_bridge_sync
  output logic          cmd_valid_o,
  output bridge_cmd_t   cmd_o,
  input  logic          cmd_ready_i,
  input  logic          rsp_valid_i,
  input  logic [31:0]   rsp_rdata_i
);

  // ================================================================ instruction classes
  typedef enum logic [3:0] {
    K_LW_WV, K_LH_WV, K_LA_WV, K_LW_SV, K_LH_SV, K_LA_SV,
    K_SPM_SW, K_SPM_LW, K_RD_WV, K_RD_SV, K_STATUS, K_NONE
  } kind_e;

  typedef struct packed {
    logic          legal;
    kind_e         kind;
    logic          writeback;
    readregflags_t register_read;   // bit 0 = rs1, bit 1 = rs2
  } dec_t;

  // D2 §1, §2, §3, §5.1 — depends on the instruction word only.
  function automatic dec_t classify(logic [31:0] w);
    dec_t d;
    logic [6:0]  opc;
    logic [2:0]  f3;
    logic [4:0]  f117, rs1f;
    logic [11:0] imm;
    opc  = w[6:0];
    f3   = w[14:12];
    f117 = w[11:7];
    rs1f = w[19:15];
    imm  = w[31:20];
    d = '{legal: 1'b0, kind: K_NONE, writeback: 1'b0, register_read: 2'b00};
    if (opc == OPC_CUSTOM0) begin
      unique case (f3)
        3'b000: d = '{!f117[4],         K_LW_WV, 1'b0, 2'b01};  // LDW: idx[4] must be 0
        3'b001: d = '{f117[1:0] == 2'b00, K_LH_WV, 1'b0, 2'b01};  // LDH: idx % 4 == 0, hint any
        3'b010: d = '{f117[3:0] == 4'h0,  K_LA_WV, 1'b0, 2'b01};  // LDH: idx == 0,     hint any
        3'b100: d = '{!f117[4],         K_LW_SV, 1'b0, 2'b01};
        3'b101: d = '{f117[1:0] == 2'b00, K_LH_SV, 1'b0, 2'b01};
        3'b110: d = '{f117[3:0] == 4'h0,  K_LA_SV, 1'b0, 2'b01};
        default: ;                                               // 011, 111 reserved
      endcase
    end else if (opc == OPC_CUSTOM1) begin
      unique case (f3)
        3'b000: d = '{1'b1, K_SPM_SW, 1'b0, 2'b11};
        3'b100: d = '{1'b1, K_SPM_LW, 1'b1, 2'b01};
        3'b001: d = '{(rs1f == 5'd0) && (imm[11:4] == 8'h00), K_RD_WV, 1'b1, 2'b00};
        3'b010: d = '{(rs1f == 5'd0) && (imm[11:4] == 8'h00), K_RD_SV, 1'b1, 2'b00};
        3'b011: d = '{(rs1f == 5'd0) && (imm[11:4] == 8'h00) && (imm[3:1] == 3'b000),
                      K_STATUS, 1'b1, 2'b00};
        default: ;                                               // 101, 110, 111 reserved
      endcase
    end
    if (!d.legal) d = '{legal: 1'b0, kind: K_NONE, writeback: 1'b0, register_read: 2'b00};
    return d;
  endfunction

  dec_t issue_dec;
  assign issue_dec             = classify(issue_instr_i);
  assign issue_accept_o        = issue_dec.legal;
  assign issue_writeback_o     = issue_dec.writeback;
  assign issue_register_read_o = issue_dec.register_read;

  // ================================================================ state
  typedef enum logic [2:0] {S_INIT, S_IDLE, S_CHECK, S_BRIDGE_REQ, S_BRIDGE_WAIT, S_RESULT} state_e;

  state_e      state_q;
  logic [1:0]  init_cnt_q;
  logic [31:0] instr_q, rs1_q, rs2_q;
  id_t         id_q;
  hartid_t     hartid_q;
  bridge_cmd_t cmd_q;
  logic [31:0] res_data_q;
  logic [4:0]  res_rd_q;
  logic        res_we_q;

  // ================================================================ CHECK-stage evaluation (from latched instruction)
  dec_t        cur;
  logic [31:0] imm_sext, ea;
  logic [6:0]  align_mask;
  logic        e_align, e_range, is_load, is_spm;
  bridge_op_e  op;
  logic [3:0]  vidx;

  assign cur = classify(instr_q);

  always_comb begin
    // immediate: S-type for spm.sw, I-type otherwise (D2 §2)
    if (cur.kind == K_SPM_SW) imm_sext = {{20{instr_q[31]}}, instr_q[31:25], instr_q[11:7]};
    else                      imm_sext = {{20{instr_q[31]}}, instr_q[31:20]};
    ea = rs1_q + imm_sext;                                  // 32-bit wrap (D2 §2)

    unique case (cur.kind)
      K_LW_WV: op = OP_LW_WV;   K_LH_WV: op = OP_LH_WV;   K_LA_WV: op = OP_LA_WV;
      K_LW_SV: op = OP_LW_SV;   K_LH_SV: op = OP_LH_SV;   K_LA_SV: op = OP_LA_SV;
      K_SPM_SW: op = OP_SPM_SW; K_SPM_LW: op = OP_SPM_LW;
      K_RD_WV: op = OP_RD_WV;   K_RD_SV: op = OP_RD_SV;
      default:  op = OP_SPM_SW;                              // K_STATUS / K_NONE: unused
    endcase

    unique case (cur.kind)
      K_LH_WV, K_LH_SV: align_mask = 7'h0F;                 // 16 B
      K_LA_WV, K_LA_SV: align_mask = 7'h3F;                 // 64 B
      default:          align_mask = 7'h03;                 // 4 B
    endcase

    is_load = cur.kind inside {K_LW_WV, K_LH_WV, K_LA_WV, K_LW_SV, K_LH_SV, K_LA_SV};
    is_spm  = cur.kind inside {K_SPM_SW, K_SPM_LW};

    // D2 §5.2: alignment first, then range (unsigned 32-bit compare)
    e_align = (is_load || is_spm) && ((ea[6:0] & align_mask) != 7'h00);
    e_range = (is_load || is_spm) && !e_align && (ea >= 32'(SPM_BYTES));

    // WVR/SVR index: LDW/LDH idx is instr[10:7] (LDW idx[4] = 0 is guaranteed
    // by acceptance); IDX format idx is imm[3:0]; spm.* use 0.
    if (is_load)                                vidx = instr_q[10:7];
    else if (cur.kind inside {K_RD_WV, K_RD_SV}) vidx = instr_q[23:20];
    else                                        vidx = 4'h0;
  end

  // STATUS interface (combinational strobes, valid in S_CHECK only)
  logic        err_set, err_align, err_range, clr;
  logic [3:0]  err_op;
  logic [31:0] status;

  assign err_set   = (state_q == S_CHECK) && (e_align || e_range);
  assign err_align = err_set && e_align;
  assign err_range = err_set && e_range;
  assign err_op    = op;
  assign clr       = (state_q == S_CHECK) && (cur.kind == K_STATUS) && instr_q[20];

  rvne_status u_status (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .err_set_i  (err_set),
    .err_align_i(err_align),
    .err_range_i(err_range),
    .err_op_i   (err_op),
    .clr_i      (clr),
    .status_o   (status)
  );

  // ================================================================ FSM
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= S_INIT;
      init_cnt_q <= 2'd0;
      instr_q    <= '0;
      rs1_q      <= '0;
      rs2_q      <= '0;
      id_q       <= '0;
      hartid_q   <= '0;
      cmd_q      <= '0;
      res_data_q <= '0;
      res_rd_q   <= '0;
      res_we_q   <= 1'b0;
    end else begin
      unique case (state_q)
        // R4 refinement: hold issue_ready low for 2 cycles after reset release
        S_INIT: begin
          init_cnt_q <= init_cnt_q + 2'd1;
          if (init_cnt_q == 2'd1) state_q <= S_IDLE;
        end

        S_IDLE: begin
          if (issue_valid_i && issue_dec.legal) begin
            instr_q  <= issue_instr_i;
            id_q     <= issue_id_i;
            hartid_q <= issue_hartid_i;
            rs1_q    <= rs1_i;          // operand sufficiency guaranteed by a_X4
            rs2_q    <= rs2_i;
            state_q  <= S_CHECK;
          end
        end

        S_CHECK: begin
          if (cur.kind == K_STATUS) begin
            res_data_q <= status;       // registered status_o: pre-clear value (D2 §6)
            res_rd_q   <= instr_q[11:7];
            res_we_q   <= 1'b1;
            state_q    <= S_RESULT;
          end else if (e_align || e_range) begin
            res_data_q <= '0;           // spm.lw error returns 0; others write nothing
            res_rd_q   <= cur.writeback ? instr_q[11:7] : 5'd0;
            res_we_q   <= cur.writeback;
            state_q    <= S_RESULT;
          end else begin
            cmd_q.op    <= op;
            cmd_q.idx   <= vidx;
            cmd_q.addr  <= (cur.kind inside {K_RD_WV, K_RD_SV}) ? '0 : ea[SPM_AW-1:0];
            cmd_q.wdata <= (cur.kind == K_SPM_SW) ? rs2_q : 32'h0;
            res_rd_q    <= cur.writeback ? instr_q[11:7] : 5'd0;
            res_we_q    <= cur.writeback;
            state_q     <= S_BRIDGE_REQ;
          end
        end

        S_BRIDGE_REQ: begin
          if (cmd_ready_i) state_q <= S_BRIDGE_WAIT;
        end

        S_BRIDGE_WAIT: begin
          if (rsp_valid_i) begin
            res_data_q <= res_we_q ? rsp_rdata_i : 32'h0;
            state_q    <= S_RESULT;
          end
        end

        S_RESULT: begin
          if (result_ready_i) state_q <= S_IDLE;
        end

        default: state_q <= S_INIT;
      endcase
    end
  end

  // ================================================================ outputs
  assign issue_ready_o   = (state_q == S_IDLE);
  assign cmd_valid_o     = (state_q == S_BRIDGE_REQ);
  assign cmd_o           = cmd_q;
  assign result_valid_o  = (state_q == S_RESULT);
  assign result_hartid_o = hartid_q;
  assign result_id_o     = id_q;
  assign result_data_o   = res_data_q;
  assign result_rd_o     = res_rd_q;
  assign result_we_o     = res_we_q;

  // ================================================================ assertions (§4.3 item 9)
`ifndef SYNTHESIS
  a_issue_ready_state: assert property (@(posedge clk_i) disable iff (!rst_ni)
      issue_ready_o == (state_q == S_IDLE))
    else $error("a_issue_ready_state violated");

  a_cmd_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
      cmd_valid_o && !cmd_ready_i |=> cmd_valid_o && $stable(cmd_o))
    else $error("a_cmd_stable violated: cmd dropped or changed before cmd_ready");

  a_result_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
      result_valid_o && !result_ready_i |=>
        result_valid_o && $stable({result_hartid_o, result_id_o, result_data_o, result_rd_o, result_we_o}))
    else $error("a_result_stable violated: result dropped or changed before result_ready");

  a_one_cmd: assert property (@(posedge clk_i) disable iff (!rst_ni)
      cmd_valid_o |-> state_q == S_BRIDGE_REQ)
    else $error("a_one_cmd violated");

  a_err_xor_clr: assert property (@(posedge clk_i) disable iff (!rst_ni)
      !(err_set && clr))
    else $error("a_err_xor_clr violated");

  a_rsp_in_wait: assert property (@(posedge clk_i) disable iff (!rst_ni)
      rsp_valid_i |-> state_q == S_BRIDGE_WAIT)
    else $error("a_rsp_in_wait violated: bridge response outside BRIDGE_WAIT");

  // DEC-07 / D3 P7: the command handed to the bridge is always well formed.
  // Boolean implication is written !a || b: xsim 2022.1 ignores '->' inside
  // properties (XSIM 43-4455), which would silently disable this check.
  logic cmd_wellformed;
  always_comb begin
    cmd_wellformed =
      (cmd_o.op <= OP_RD_SV) &&
      (!(cmd_o.op inside {OP_SPM_SW, OP_SPM_LW, OP_LW_WV, OP_LW_SV}) || (cmd_o.addr[1:0] == 2'b00)) &&
      (!(cmd_o.op inside {OP_LH_WV, OP_LH_SV}) || ((cmd_o.addr[3:0] == 4'h0) && (cmd_o.idx[1:0] == 2'b00))) &&
      (!(cmd_o.op inside {OP_LA_WV, OP_LA_SV}) || ((cmd_o.addr[5:0] == 6'h00) && (cmd_o.idx == 4'h0))) &&
      ((cmd_o.op == OP_SPM_SW) || (cmd_o.wdata == 32'h0));
  end
  a_cmd_wellformed: assert property (@(posedge clk_i) disable iff (!rst_ni)
      cmd_valid_o |-> cmd_wellformed)
    else $error("a_cmd_wellformed violated: malformed bridge command (DEC-07)");
`endif

endmodule
