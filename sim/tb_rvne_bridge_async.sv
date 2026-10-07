// RVNE-ASYNC — D6.5 testbench: rvne_c_element, rvne_delay, rvne_bridge_async.
// No storage is attached. Around the async bridge sit:
//   * a behavioural 4-phase master working in real time (the sync side);
//   * a timing stand-in for rvne_exec + rvne_spm: decode/select outputs lag the
//     command by T_EXEC, SPM row data lags the row address by T_EXEC + T_SPM,
//     the response lags its sources by T_EXEC. Strobe gating (p & select) has
//     no extra delay (D3 A5). Routing correctness is D6.6; only windows here.
//
// Parameters (overridden per run with xelab -generic_top):
//   D_DEC, D_SPM, D_WR   matched delays           T_EXEC, T_SPM  modelled logic delays
//   PRIM = 1             also run the C-element and delay-element tests
// +FAULT=<n> injects one protocol violation (see table in run_d65.py).
`timescale 1ns/1ps

module tb_rvne_bridge_async #(
  parameter realtime D_DEC  = 1.0,
  parameter realtime D_SPM  = 2.0,
  parameter realtime D_WR   = 1.0,
  parameter realtime T_EXEC = 0.3,
  parameter realtime T_SPM  = 1.5,
  parameter int      PRIM   = 1,
  parameter int      N_TXN  = 2000
);
  import rvne_pkg::*;

  localparam realtime TOL     = 0.002;                 // 2 ps
  localparam realtime D_TOTAL = D_DEC + D_SPM + D_WR;

  int tb_errors = 0, fault = 0;
  task automatic fail(string what);
    tb_errors++;
    if (tb_errors <= 40) $display("TB_ERROR t=%0.3f %s", $realtime, what);
  endtask
  function automatic bit near(realtime a, realtime b);
    return (a - b < TOL) && (b - a < TOL);
  endfunction

  // ================================================================ primitives
  logic c_rst = 1'b0, c_a = 1'b0, c_b = 1'b0, c_out;
  rvne_c_element u_c (.rst_ni(c_rst), .a_i(c_a), .b_i(c_b), .c_o(c_out));

  localparam realtime DL = 3.7;
  logic d_rst = 1'b0, d_in = 1'b0, d_out;
  rvne_delay #(.D(DL)) u_dl (.rst_ni(d_rst), .in_i(d_in), .out_o(d_out));

  int prim_c_checks = 0, prim_d_checks = 0;

  task automatic test_c_element();
    logic model;
    // reset
    c_a = 1; c_b = 1; #1; c_rst = 0; #0.001;
    if (c_out !== 0) fail("C: not 0 in reset with a=b=1");
    c_rst = 1; #0.001;
    if (c_out !== 1) fail("C: release with a=b=1 must give 1");
    model = 1;
    // exhaustive: every input pair -> every input pair, from both output states
    for (int s = 0; s < 2; s++)
      for (int from = 0; from < 4; from++)
        for (int to = 0; to < 4; to++) begin
          {c_a, c_b} = s ? 2'b11 : 2'b00; #1; model = s;          // establish state
          {c_a, c_b} = from[1:0]; #1;
          if (c_a == c_b) model = c_a;
          if (c_out !== model) fail($sformatf("C: state %0d -> in %02b: c=%b exp %b", s, from[1:0], c_out, model));
          {c_a, c_b} = to[1:0]; #1;
          if (c_a == c_b) model = c_a;
          if (c_out !== model) fail($sformatf("C: %02b -> %02b: c=%b exp %b", from[1:0], to[1:0], c_out, model));
          prim_c_checks += 2;
        end
    // random walk with asynchronous resets
    for (int i = 0; i < 3000; i++) begin
      if ($urandom_range(0, 19) == 0) begin
        c_rst = 0; #0.001;
        if (c_out !== 0) fail("C: reset did not force 0 immediately");
        {c_a, c_b} = $urandom; #0.5;
        if (c_out !== 0) fail("C: output left 0 during reset");
        c_rst = 1; #0.001;
        model = (c_a == c_b) ? c_a : 1'b0;
      end else begin
        {c_a, c_b} = $urandom; #($urandom_range(1, 900) * 1ps);
        if (c_a == c_b) model = c_a;
      end
      if (c_out !== model) fail($sformatf("C walk %0d: in %b%b c=%b exp %b", i, c_a, c_b, c_out, model));
      prim_c_checks++;
    end
  endtask

  task automatic test_delay();
    realtime t;
    d_rst = 1; d_in = 0; #10;
    for (int i = 0; i < 20; i++) begin
      // rising and falling edges each delayed by exactly DL
      d_in = 1; t = $realtime;
      #(DL - 0.001); if (d_out !== 0) fail("DLY: rose early");
      #0.002;        if (d_out !== 1) fail("DLY: did not rise at in+D");
      #($urandom_range(1, 3000) * 1ps);
      d_in = 0;
      #(DL - 0.001); if (d_out !== 1) fail("DLY: fell early");
      #0.002;        if (d_out !== 0) fail("DLY: did not fall at in+D");
      #1;
      prim_d_checks += 4;
    end
    // inertial: a pulse shorter than D is absorbed
    begin
      bit seen;
      seen = 0;
      fork
        begin d_in = 1; #(DL / 2); d_in = 0; #(DL * 2); end
        begin repeat (1) @(posedge d_out or posedge seen); seen = 1; end
      join_any
      disable fork;
      if (d_out !== 0 || seen) fail("DLY: short pulse not absorbed (inertial)");
      prim_d_checks++;
    end
    // reset forces 0 immediately; release after the node settled follows the node
    d_in = 1; #(DL + 1);
    if (d_out !== 1) fail("DLY: not 1 before reset test");
    d_rst = 0; #0.001; if (d_out !== 0) fail("DLY: reset did not force 0 immediately");
    #2; d_rst = 1; #0.001; if (d_out !== 1) fail("DLY: release with node 1 must give 1");
    // pending transition across a short reset: node still rises at in+D
    d_in = 0; #(DL + 1);
    d_in = 1; t = $realtime; #1; d_rst = 0; #1; d_rst = 1;
    #(DL - 2 - 0.001); if (d_out !== 0) fail("DLY: pending rise early after reset");
    #0.002;            if (d_out !== 1) fail("DLY: pending rise lost across reset");
    prim_d_checks += 5;
    d_in = 0; #(DL + 1);
  endtask

  // ================================================================ async bridge DUT
  logic        rst_n = 1'b0, req = 1'b0;
  bridge_cmd_t cmd = '0;
  logic        ack, p_spm, p_wr;

  // timing stand-in for rvne_exec / rvne_spm
  // delayed stand-in signals are nets: xsim gives inertial delay only to nets (X-h)
  wire  [7:0]  row_addr_d;
  wire  [31:0] wdata_d;
  wire  [15:0] bank_sel_d, wsel_d, ssel_d, spm_bank_we, wvr_we, svr_we;
  vec_t        row_now;
  wire  vec_t  row, vec_wdata;
  logic [31:0] rsp_now;
  wire  [31:0] rsp;
  logic [31:0] mem [256][16];
  logic [31:0] wvr_regs [16], svr_regs [16];
  event        mem_ev;

  function automatic logic [15:0] range_mask(bridge_cmd_t c, bit sv);
    int n;
    n = 0;
    unique case (c.op)
      OP_LW_WV: n = sv ? 0 : 1;   OP_LH_WV: n = sv ? 0 : 4;   OP_LA_WV: n = sv ? 0 : 16;
      OP_LW_SV: n = sv ? 1 : 0;   OP_LH_SV: n = sv ? 4 : 0;   OP_LA_SV: n = sv ? 16 : 0;
      default:  n = 0;
    endcase
    return 16'(((32'h1 << n) - 1) << c.idx);
  endfunction

  assign #(T_EXEC) row_addr_d = cmd.addr[13:6];
  assign #(T_EXEC) wdata_d    = cmd.wdata;
  assign #(T_EXEC) bank_sel_d = (cmd.op == OP_SPM_SW) ? (16'h1 << cmd.addr[5:2]) : 16'h0;
  assign #(T_EXEC) wsel_d     = range_mask(cmd, 1'b0);
  assign #(T_EXEC) ssel_d     = range_mask(cmd, 1'b1);
  assign spm_bank_we = {16{p_spm}} & bank_sel_d;          // strobe gating: no added delay (A5)
  assign wvr_we      = {16{p_wr}}  & wsel_d;
  assign svr_we      = {16{p_wr}}  & ssel_d;

  for (genvar b = 0; b < 16; b++) begin : g_bank
    always @(posedge spm_bank_we[b]) begin mem[row_addr_d][b] = wdata_d; -> mem_ev; end
  end
  always @(row_addr_d or mem_ev) for (int b = 0; b < 16; b++) row_now[b] = mem[row_addr_d][b];
  assign #(T_SPM) row = row_now;
  assign vec_wdata = row;

  always @* begin
    unique case (cmd.op)
      OP_SPM_LW: rsp_now = row[cmd.addr[5:2]];
      OP_RD_WV:  rsp_now = wvr_regs[cmd.idx];
      OP_RD_SV:  rsp_now = svr_regs[cmd.idx];
      default:   rsp_now = 32'h0;
    endcase
  end
  assign #(T_EXEC) rsp = rsp_now;

  rvne_bridge_async #(.D_DEC(D_DEC), .D_SPM(D_SPM), .D_WR(D_WR)) dut (
    .rst_ni            (rst_n),
    .req_i             (req),
    .ack_o             (ack),
    .p_spm_o           (p_spm),
    .p_wr_o            (p_wr),
    .cmd_chk_i         (cmd),
    .rsp_rdata_chk_i   (rsp),
    .spm_row_addr_chk_i(row_addr_d),
    .spm_wdata_chk_i   (wdata_d),
    .spm_bank_we_chk_i (spm_bank_we),
    .wvr_we_chk_i      (wvr_we),
    .svr_we_chk_i      (svr_we),
    .vec_wdata_chk_i   (vec_wdata)
  );

  // ================================================================ per-transaction event log
  realtime t_spm_r, t_spm_f, t_wr_r, t_wr_f, t_ack_r, t_ack_f;
  int      n_spm, n_wr;
  logic [15:0] bank_rises, wvr_rises, svr_rises;
  int      dup_rises;
  task automatic clear_log();
    n_spm = 0; n_wr = 0; bank_rises = 0; wvr_rises = 0; svr_rises = 0; dup_rises = 0;
  endtask
  always @(posedge p_spm) begin n_spm++; t_spm_r = $realtime; end
  always @(negedge p_spm) t_spm_f = $realtime;
  always @(posedge p_wr)  begin n_wr++;  t_wr_r  = $realtime; end
  always @(negedge p_wr)  t_wr_f  = $realtime;
  for (genvar e = 0; e < 16; e++) begin : g_mon
    always @(posedge spm_bank_we[e]) begin if (bank_rises[e]) dup_rises++; bank_rises[e] = 1; end
    always @(posedge wvr_we[e])      begin if (wvr_rises[e])  dup_rises++; wvr_rises[e]  = 1; end
    always @(posedge svr_we[e])      begin if (svr_rises[e])  dup_rises++; svr_rises[e]  = 1; end
  end

  // ================================================================ master
  int n_txn = 0;
  bit [9:0] ops_seen = '0;

  function automatic bridge_cmd_t rand_cmd(int force_op);
    bridge_cmd_t c;
    int op;
    op = (force_op >= 0) ? force_op : $urandom_range(0, 9);
    c.op    = bridge_op_e'(op);
    c.wdata = (op == OP_SPM_SW) ? $urandom : 32'h0;
    c.addr  = $urandom;
    c.idx   = $urandom;
    unique case (op)
      OP_SPM_SW, OP_SPM_LW, OP_LW_WV, OP_LW_SV: begin c.addr[1:0] = 0; if (op <= OP_SPM_LW) c.idx = 0; end
      OP_LH_WV, OP_LH_SV: begin c.addr[3:0] = 0; c.idx[1:0] = 0; end
      OP_LA_WV, OP_LA_SV: begin c.addr[5:0] = 0; c.idx = 0; end
      default: c.addr = 0;                                  // RD_WV / RD_SV
    endcase
    return c;
  endfunction

  // one complete, protocol-correct transaction with full timing checks
  task automatic txn(bridge_cmd_t c, realtime hold);
    realtime t_req, t_fall;
    cmd = c;
    // bundled-data setup before req: 40 % near-zero (1 ps) so that T1/T2 and the
    // response-path margin are binding (S1 gives a full clock in the real system)
    if ($urandom_range(0, 9) < 4) #0.001;
    else                          #($urandom_range(100, 8000) * 1ps);
    clear_log();
    req = 1; t_req = $realtime;
    wait (ack === 1'b1); t_ack_r = $realtime;
    if (!near(t_ack_r, t_req + D_TOTAL)) fail($sformatf("ack rise at +%0.3f, exp +%0.3f", t_ack_r - t_req, D_TOTAL));
    #(hold);
    req = 0; t_fall = $realtime;
    wait (ack === 1'b0); t_ack_f = $realtime;
    if (!near(t_ack_f, t_fall + D_TOTAL)) fail($sformatf("ack fall at +%0.3f, exp +%0.3f", t_ack_f - t_fall, D_TOTAL));
    // E2..E4 windows
    if (n_spm != 1 || n_wr != 1) fail($sformatf("op %0d: %0d p_spm / %0d p_wr pulses (exp 1/1)", c.op, n_spm, n_wr));
    if (!near(t_spm_r, t_req + D_DEC))          fail("p_spm did not open at req + D_DEC");
    if (!near(t_spm_f - t_spm_r, D_SPM))        fail("p_spm width != D_SPM");
    if (!near(t_wr_r,  t_req + D_DEC + D_SPM))  fail("p_wr did not open at req + D_DEC + D_SPM");
    if (!near(t_wr_f - t_wr_r, D_WR))           fail("p_wr width != D_WR");
    if (!near(t_wr_f, t_ack_r))                 fail("p_wr did not close at ack rise");
    // enables per op
    if (bank_rises !== ((c.op == OP_SPM_SW) ? 16'(16'h1 << c.addr[5:2]) : 16'h0))
      fail($sformatf("op %0d: SPM bank enables %04h", c.op, bank_rises));
    if (wvr_rises !== range_mask(c, 0)) fail($sformatf("op %0d: WVR enables %04h exp %04h", c.op, wvr_rises, range_mask(c, 0)));
    if (svr_rises !== range_mask(c, 1)) fail($sformatf("op %0d: SVR enables %04h exp %04h", c.op, svr_rises, range_mask(c, 1)));
    if (dup_rises != 0) fail("an enable pulsed more than once in one transaction");
    ops_seen[c.op] = 1'b1;
    n_txn++;
  endtask

  // ================================================================ fault injection
  task automatic run_fault(int f);
    bridge_cmd_t c;
    c = rand_cmd(OP_LA_WV);
    cmd = c; #5;
    unique case (f)
      1: begin req = 1; wait (ack); #0.001; req = 0; #0.1; req = 1; #20; req = 0; end        // a_P8: re-request before ack fall
      2: begin req = 1; #(D_DEC + 0.5); req = 0; #20; end                              // a_P4_req_fall: drop before ack
      3: begin req = 1; #(D_DEC + 0.5); rst_n = 0; req = 0; #0.3; rst_n = 1; #20; end   // malformed (short) reset -> a_P6
      4: begin req = 1; #0.2; req = 0; #20; end                                         // req glitch while idle -> a_P4_req_fall
      // inside the p_wr window, where wdata drives nothing (in p_spm it would also, correctly, trip W1)
      5: begin req = 1; #(D_DEC + D_SPM + D_WR / 2); cmd.wdata = ~cmd.wdata; wait (ack); #0.001; req = 0; wait (!ack); end   // a_P2
      6: begin cmd = rand_cmd(OP_SPM_LW); #5; req = 1; wait (ack); #0.5;
               force rsp = ~rsp; #0.5; release rsp; #0.001; req = 0; wait (!ack); end         // a_P3
      7: begin req = 1; wait (p_wr === 1'b1); force dut.p_wr_o = 1'b1;
               wait (ack); #0.002; release dut.p_wr_o; #0.001; req = 0; wait (!ack); end    // a_P5
      8: begin #1; force dut.p_spm_o = 1'b1; #0.5; release dut.p_spm_o; #20; end        // a_P6: strobe while idle
      9: begin cmd.op = bridge_op_e'(4'hA); #5; req = 1; wait (ack); #0.001; req = 0; wait (!ack); end   // a_P7
      10: begin #1; force dut.ack_o = 1'b1; #0.5; release dut.ack_o; #20; end           // a_P4_ack_rise
      // after 'release' the net keeps the forced 0 until its driver changes (X-e),
      // so the handshake is not continued: req stays high and the run ends
      11: begin req = 1; wait (ack); #0.3; force dut.ack_o = 1'b0; #0.3; release dut.ack_o; end                                             // a_P4_ack_fall
      default: ;
    endcase
    #50;
  endtask

  // ================================================================ main
  initial begin
    if (!$value$plusargs("FAULT=%d", fault)) fault = 0;
    $display("TB_INFO cfg D_DEC=%0.3f D_SPM=%0.3f D_WR=%0.3f T_EXEC=%0.3f T_SPM=%0.3f fault=%0d",
             D_DEC, D_SPM, D_WR, T_EXEC, T_SPM, fault);
    for (int r = 0; r < 256; r++) for (int b = 0; b < 16; b++) mem[r][b] = $urandom;
    for (int i = 0; i < 16; i++) begin wvr_regs[i] = $urandom; svr_regs[i] = $urandom; end

    if (PRIM && fault == 0) begin
      test_c_element();
      test_delay();
      $display("TB_PRIM c_element_checks=%0d delay_checks=%0d", prim_c_checks, prim_d_checks);
    end

    #10 rst_n = 1;
    #(D_TOTAL + 5);

    if (fault != 0) begin
      for (int i = 0; i < 20; i++) txn(rand_cmd(-1), $urandom_range(0, 3000) * 1ps);
      run_fault(fault);
      $display("TB_FAULT_DONE fault=%0d", fault);
      $finish;
    end

    // every op at least once, then random; gaps include 0 (back-to-back requests)
    for (int op = 0; op <= 9; op++) txn(rand_cmd(op), 0.5);
    for (int i = 0; i < N_TXN; i++) begin
      txn(rand_cmd(-1), ($urandom_range(0, 3) == 0) ? 0.0 : $urandom_range(1, 20_000) * 1ps);
    end

    // legal reset mid-transaction (R5): width >= drain time, then recovery
    begin
      cmd = rand_cmd(OP_LA_SV); #5;
      req = 1; wait (p_wr === 1'b1); #(D_WR / 2);
      rst_n = 0; req = 0; #0.001;
      if (dut.s1 || dut.s2 || dut.s3 || p_spm || p_wr || ack) fail("R2: reset did not clear the async control immediately");
      #(D_TOTAL + 1); rst_n = 1;
      #(D_TOTAL + 1);
      if (p_spm || p_wr || ack) fail("R5: control not idle after a legal reset");
      for (int i = 0; i < 20; i++) txn(rand_cmd(-1), 1.0);
      $display("TB_RESET mid-transaction reset cleared immediately; 20 transactions after recovery");
    end

    #20;
    $display("TB_SUMMARY txns=%0d ops_seen=%03h c_checks=%0d d_checks=%0d tb_errors=%0d",
             n_txn, ops_seen, prim_c_checks, prim_d_checks, tb_errors);
    $finish;
  end

endmodule
