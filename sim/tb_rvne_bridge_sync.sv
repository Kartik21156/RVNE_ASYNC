// RVNE-ASYNC — D6.4 testbench for rvne_bridge_sync (+ rvne_sync2).
//
// Decoder side: replays every bridge command of the D6.3-proven D5 stream
//   (vectors/txn.hex lines with has_cmd = 1) and checks each rsp_rdata.
// Boundary side: a behavioural asynchronous 4-phase responder working in
//   real time (ns/ps), not clock cycles, so ack transitions land at arbitrary
//   clock phases. It drives rsp_rdata only inside [ack rise, req fall] and
//   garbage everywhere else, so any mis-timed sample is detected.
//
// Checked for every transaction:
//   S1  cmd_o loads on the handshake edge, req rises exactly one edge later;
//       req_o / cmd_o only ever change on a clock edge
//   S2/S3  rsp sampled on exactly the 3rd edge after ack rise
//   S4  req falls exactly one edge after the sample
//   S5  rsp_valid rises on the 2nd edge after ack fall, for exactly one cycle
//   P2 (+refinement)  cmd_o stable from req rise until ack fall
//   P8  req never rises while ack = 1
// Directed: D1 fast-path schedule; D2 spurious ack holds off cmd_ready (R4
//   guard); D3 reset in mid-transaction (R5).
// +FAULT=<n> breaks one bridge rule for one cycle (1 a_S1, 2 a_P8_sync,
//   3 a_P4_sync, 4 a_S3, 5 a_rsp_pulse) and ends the run shortly after.
`timescale 1ns/1ps

module tb_rvne_bridge_sync;
  import rvne_pkg::*;

  localparam int ST_IDLE = 0, ST_LATCH = 1, ST_REQ_HIGH = 2, ST_ACK_SEEN = 3, ST_REQ_LOW = 4;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;                       // posedges at 5, 15, 25, ... ns
  int ecnt = 0;                               // index of the most recent posedge
  always @(posedge clk) ecnt++;

  // ------------------------------------------------------------ DUT
  logic        cmd_valid = 1'b0, cmd_ready, rsp_valid;
  bridge_cmd_t cmd_in = '0, cmd_b;
  logic [31:0] rsp_rdata;
  logic        req, ack = 1'b0;
  logic [31:0] rsp_b = 32'hDEAD_0000;

  rvne_bridge_sync dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .cmd_valid_i(cmd_valid),
    .cmd_i      (cmd_in),
    .cmd_ready_o(cmd_ready),
    .rsp_valid_o(rsp_valid),
    .rsp_rdata_o(rsp_rdata),
    .req_o      (req),
    .cmd_o      (cmd_b),
    .ack_i      (ack),
    .rsp_rdata_i(rsp_b)
  );

  // ------------------------------------------------------------ bookkeeping
  int tb_errors = 0, fault = 0;
  task automatic fail(string what);
    tb_errors++;
    if (tb_errors <= 30) $display("TB_ERROR t=%0.3f %s", $realtime, what);
  endtask

  function automatic bit on_edge(realtime t);       // t is a posedge time (5 + 10k ns)
    real x;
    x = (t - 5.0) / 10.0;
    return (x - $floor(x)) < 1e-6;
  endfunction

  // ------------------------------------------------------------ behavioural async responder
  logic [31:0] exp_q [$];                           // expected rsp per command, FIFO
  int          e_ack_rise = 0, e_ack_fall = 0;
  bit          ack_rise_on_edge = 0, ack_fall_on_edge = 0;
  int          resp_txn = 0;
  int          spurious_ns = 0;                     // >0: raise a spurious ack (directed D2)
  bit          fast = 0;                            // directed D1: minimal async delays

  task automatic adelay(bit is_fast);
    // 50 %: sub-cycle (0.1–9.9 ns); 50 %: multi-cycle (10–60 ns); fast: 0.1–0.9 ns
    int ps;
    if (is_fast)                       ps = $urandom_range(100, 900);
    else if ($urandom_range(0, 1))     ps = $urandom_range(100, 9_900);
    else                               ps = $urandom_range(10_000, 60_000);
    #(ps * 1ps);
  endtask

  initial begin : responder
    logic [31:0] e;
    forever begin
      fork : f_txn
        begin
          if (spurious_ns > 0) begin
            ack = 1'b1;
            #(spurious_ns * 1ns);
            ack = 1'b0;
            spurious_ns = 0;
          end
          wait (rst_n && req === 1'b1);
          resp_txn++;
          if (exp_q.size() == 0) begin fail("responder: req with no expected response"); e = 'x; end
          else e = exp_q.pop_front();
          adelay(fast); rsp_b = e;                  // data valid before ack rise (P3)
          adelay(fast); ack = 1'b1;
          e_ack_rise = ecnt; ack_rise_on_edge = on_edge($realtime);
          wait (req === 1'b0);
          rsp_b = $urandom;                         // P3 allows change after req fall
          adelay(fast); ack = 1'b0;
          e_ack_fall = ecnt; ack_fall_on_edge = on_edge($realtime);
        end
        begin
          wait (!rst_n);
        end
      join_any
      disable f_txn;
      if (!rst_n) begin
        ack = 1'b0;                                 // R2: async side resets ack
        rsp_b = $urandom;
        exp_q.delete();
        wait (rst_n);
      end
    end
  end

  // ------------------------------------------------------------ boundary monitors
  bit in_hs = 0;                                    // req rise .. ack fall
  always @(posedge req) if (rst_n) begin
    if (ack !== 1'b0) fail("P8: req rose while ack = 1");
    in_hs = 1;
  end
  always @(negedge ack) in_hs = 0;
  always @(negedge rst_n) in_hs = 0;

  always @(cmd_b) if (rst_n && in_hs && fault == 0) fail("P2/S4-refinement: cmd_o changed during handshake");
  always @(req or cmd_b) if (rst_n && $realtime > 0 && !on_edge($realtime) && fault == 0)
    fail($sformatf("S1: req_o/cmd_o changed off a clock edge (req=%b)", req));

  // cycle-exact schedule, measured as posedge indices
  int e_hs = 0, e_req_rise = 0, e_cap = 0, e_req_fall = 0, e_rv = 0;
  int sched_checked = 0;
  always @(posedge req) e_req_rise = ecnt;
  always @(negedge req) e_req_fall = ecnt;
  always @(dut.state_q) if (dut.state_q == ST_ACK_SEEN) e_cap = ecnt;
  always @(posedge rsp_valid) e_rv = ecnt;

  // ------------------------------------------------------------ fault injection
  initial begin : inject
    if (!$value$plusargs("FAULT=%d", fault)) fault = 0;
    if (fault != 0) begin
      wait (resp_txn == 20);
      unique case (fault)
        1: begin wait (dut.state_q == ST_REQ_HIGH); @(negedge clk);
                 force dut.cmd_q = dut.cmd_q ^ 54'h1; @(negedge clk); release dut.cmd_q; end
        2: begin wait (dut.state_q == ST_LATCH);    @(negedge clk);
                 force dut.ack_s = 1'b1;            @(negedge clk); release dut.ack_s; end
        // one cycle into REQ_HIGH: on the entry edge the sampled req_q is still 0
        3: begin wait (dut.state_q == ST_REQ_HIGH); @(posedge clk); @(negedge clk);
                 force dut.req_q = 1'b0;            @(negedge clk); release dut.req_q; end
        4: begin wait (dut.state_q == ST_REQ_LOW);  @(negedge clk);
                 force dut.rsp_q = ~dut.rsp_q;      @(negedge clk); release dut.rsp_q; end
        5: begin wait (rsp_valid === 1'b1);         @(negedge clk);
                 // 3'd4 = S_REQ_LOW (the enum type is not reachable hierarchically)
                 force dut.state_q = 3'd4;          @(negedge clk); release dut.state_q; end
        default: ;
      endcase
      repeat (100) @(posedge clk);
      $display("TB_FAULT_DONE fault=%0d", fault);
      $finish;
    end
  end

  // ------------------------------------------------------------ one decoder-side transaction
  int n_txn = 0;
  task automatic do_txn(bridge_cmd_t c, logic [31:0] e, bit check_sched);
    @(posedge clk); #1;
    cmd_valid = 1'b1;
    cmd_in    = c;
    exp_q.push_back(e);
    do @(negedge clk); while (!cmd_ready);
    @(posedge clk); #1;
    e_hs = ecnt;                                     // handshake edge
    if (cmd_b !== c) fail($sformatf("S1: cmd_o != cmd_i after handshake (txn %0d)", n_txn));
    if (req !== 1'b0) fail("S1: req high on the handshake edge");
    cmd_valid = $urandom_range(0, 1);                // bridge must ignore cmd_valid now
    cmd_in    = {$urandom, $urandom};               // and any change of cmd_i
    do @(negedge clk); while (!rsp_valid);
    if (rsp_rdata !== e) fail($sformatf("txn %0d rsp_rdata %08h exp %08h", n_txn, rsp_rdata, e));
    @(negedge clk);
    if (rsp_valid !== 1'b0) fail("S5: rsp_valid longer than one cycle");
    cmd_valid = 1'b0;
    if (check_sched) begin
      sched_checked++;
      if (e_req_rise != e_hs + 1)  fail($sformatf("S1: req rose at edge +%0d after handshake", e_req_rise - e_hs));
      if (!(e_cap == e_ack_rise + 3 || (ack_rise_on_edge && e_cap == e_ack_rise + 2)))
        fail($sformatf("S2/S3: sample at edge +%0d after ack rise", e_cap - e_ack_rise));
      if (e_req_fall != e_cap + 1) fail($sformatf("S4: req fell at edge +%0d after sample", e_req_fall - e_cap));
      if (!(e_rv == e_ack_fall + 2 || (ack_fall_on_edge && e_rv == e_ack_fall + 1)))
        fail($sformatf("S5: rsp_valid at edge +%0d after ack fall", e_rv - e_ack_fall));
    end
    n_txn++;
  endtask

  // ------------------------------------------------------------ main
  bridge_cmd_t cmds [$];
  logic [31:0] rsps [$];
  int min_lat = 1 << 30;

  initial begin
    int fd;
    logic [31:0] w, f_rs1, f_rs2, f_acc, f_hascmd, f_op, f_idx, f_addr, f_wdata, f_rsp,
                 f_hasres, f_we, f_rd, f_data, f_status;
    bridge_cmd_t c;
    int aborted_rv;

    fd = $fopen("../vectors/txn.hex", "r");
    if (fd == 0) begin $display("TB_FATAL cannot open txn.hex"); $finish; end
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                   w, f_rs1, f_rs2, f_acc, f_hascmd, f_op, f_idx, f_addr, f_wdata, f_rsp,
                   f_hasres, f_we, f_rd, f_data, f_status) == 15)
      if (f_hascmd[0]) begin
        c.op = bridge_op_e'(f_op[3:0]); c.idx = f_idx[3:0]; c.addr = f_addr[SPM_AW-1:0]; c.wdata = f_wdata;
        cmds.push_back(c); rsps.push_back(f_rsp);
      end
    $fclose(fd);
    $display("TB_INFO commands=%0d fault=%0d", cmds.size(), fault);

    repeat (3) @(posedge clk);
    #2.3 rst_n = 1'b1;                               // release off-edge
    repeat (2) @(posedge clk);

    // ---- D1: fast-path schedule (async side answers in < 1 ns)
    fast = 1;
    for (int i = 0; i < 8; i++) begin
      int t0;
      t0 = ecnt;
      do_txn(cmds[i], rsps[i], 1'b1);
      if (e_rv - e_hs < min_lat) min_lat = e_rv - e_hs;
      // async time < 1 ns: handshake +1 req rise, +2 ack_s, +1 sample, +1 req fall, +2 ack_s low
      if (e_rv - e_hs != 7) fail($sformatf("D1: fast-path latency %0d edges, expected exactly 7", e_rv - e_hs));
    end
    fast = 0;
    $display("TB_D1 fast-path handshake->rsp_valid = %0d edges (exactly 7 required: 1+2+1+1+2)", min_lat);

    // ---- D2: spurious ack after idle must hold off cmd_ready (R4 guard)
    begin
      int ready_while_ack;
      ready_while_ack = 0;
      @(negedge clk); spurious_ns = 47;              // responder raises ack for 47 ns
      fork
        do_txn(cmds[8], rsps[8], 1'b0);
        begin
          wait (ack === 1'b1);
          while (ack === 1'b1 || dut.ack_s === 1'b1) begin
            @(negedge clk);
            if (dut.ack_s === 1'b1 && cmd_ready === 1'b1) ready_while_ack++;
          end
        end
      join
      if (ready_while_ack != 0) fail("D2: cmd_ready high while ack_s = 1");
      $display("TB_D2 spurious ack: cmd_ready held off, transaction completed afterwards");
    end

    // ---- main stream: every D6.3-proven command, random async timing
    for (int i = 0; i < cmds.size(); i++) do_txn(cmds[i], rsps[i], 1'b1);

    // ---- D3: reset in mid-transaction (R5), then recovery
    @(posedge clk); #1;
    cmd_valid = 1'b1; cmd_in = cmds[0]; exp_q.push_back(rsps[0]);
    wait (dut.state_q == ST_REQ_HIGH);
    #3.3 rst_n = 1'b0;
    #0.001;
    if (req !== 1'b0)            fail("D3: req not cleared immediately by reset");
    if (dut.state_q != ST_IDLE)  fail("D3: FSM not IDLE in reset");
    if (rsp_valid !== 1'b0)      fail("D3: rsp_valid in reset");
    cmd_valid = 1'b0;
    aborted_rv = 0;
    fork
      begin repeat (3) @(posedge clk); #4.1 rst_n = 1'b1; repeat (4) @(posedge clk); end
      begin repeat (7) begin @(negedge clk); if (rsp_valid) aborted_rv++; end end
    join
    if (aborted_rv != 0) fail("D3: aborted transaction produced rsp_valid");
    for (int i = 0; i < 50; i++) do_txn(cmds[i], rsps[i], 1'b1);
    $display("TB_D3 reset mid-transaction: aborted cleanly, 50 transactions after recovery");

    repeat (4) @(posedge clk);
    $display("TB_SUMMARY commands=%0d transactions=%0d responder_txn=%0d schedule_checked=%0d min_latency_edges=%0d tb_errors=%0d",
             cmds.size(), n_txn, resp_txn, sched_checked, min_lat, tb_errors);
    $finish;
  end

endmodule
