// RVNE-ASYNC — D6.2 testbench for rvne_if (CV-X-IF adapter).
//
// The DUT is rvne_if alone. Around it:
//   * CPU side: a CV32A60X driver model — unsplit issue/register,
//     commit_valid = issue_valid && issue_ready (same cycle), commit_kill = 0,
//     random compressed offers, random result_ready.
//   * Decoder side: a stand-in that answers accept/writeback/register_read from
//     the D5 oracle (vectors/issue.hex) and drives random result payloads.
//     RTL issue classification itself is D6.3; here we prove the adapter
//     carries the oracle's answer to the CPU exactly.
//
// +MODE=<n> selects one deliberate host-contract violation:
//   0 none (positive run)   1 X1 commit id mismatch   2 X2 commit_kill = 1
//   3 X3 split register     4 X4 rs_valid missing     5 DEC-14 tie-off broken
// +VEC=<path> overrides the vector file (default ../vectors/issue.hex).
`timescale 1ns/1ps

module tb_rvne_if;
  import rvne_pkg::*;

  // ------------------------------------------------------------ clock / reset
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------ DUT
  cvxif_req_t    req;
  cvxif_resp_t   resp;

  logic          issue_valid, result_ready;
  logic [31:0]   issue_instr, rs1, rs2;
  id_t           issue_id;
  hartid_t       issue_hartid;
  readregflags_t rs_valid;

  logic          dec_issue_ready, dec_accept, dec_writeback;
  readregflags_t dec_register_read;
  logic          dec_res_valid, dec_res_we;
  hartid_t       dec_res_hartid;
  id_t           dec_res_id;
  logic [31:0]   dec_res_data;
  logic [4:0]    dec_res_rd;

  rvne_if dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .cvxif_req_i          (req),
    .cvxif_resp_o         (resp),
    .issue_valid_o        (issue_valid),
    .issue_instr_o        (issue_instr),
    .issue_id_o           (issue_id),
    .issue_hartid_o       (issue_hartid),
    .rs1_o                (rs1),
    .rs2_o                (rs2),
    .rs_valid_o           (rs_valid),
    .result_ready_o       (result_ready),
    .issue_ready_i        (dec_issue_ready),
    .issue_accept_i       (dec_accept),
    .issue_writeback_i    (dec_writeback),
    .issue_register_read_i(dec_register_read),
    .result_valid_i       (dec_res_valid),
    .result_hartid_i      (dec_res_hartid),
    .result_id_i          (dec_res_id),
    .result_data_i        (dec_res_data),
    .result_rd_i          (dec_res_rd),
    .result_we_i          (dec_res_we)
  );

  // ------------------------------------------------------------ D5 oracle
  logic [31:0] v_instr [$];
  logic [3:0]  v_resp  [$];          // {accept, writeback, register_read[1:0]}
  logic [3:0]  oracle  [logic [31:0]];

  function automatic logic [3:0] oracle_of(logic [31:0] w);
    return oracle.exists(w) ? oracle[w] : 4'b0000;
  endfunction

  // Decoder stand-in: issue response straight from the oracle.
  // Explicit sensitivity: xsim 2022.1 does not support sensitivity on associative arrays.
  always @(issue_instr) begin
    logic [3:0] r;
    r                 = oracle_of(issue_instr);
    dec_accept        = r[3];
    dec_writeback     = r[2];
    dec_register_read = r[1:0];
  end

  // ------------------------------------------------------------ bookkeeping
  int mode = 0;
  int tb_errors = 0, handshakes = 0, accepted = 0, offers = 0, results = 0;
  int inject_k = -1;

  task automatic fail(string what);
    tb_errors++;
    if (tb_errors <= 20) $display("TB_ERROR t=%0t %s", $time, what);
  endtask

  // ------------------------------------------------------------ CV32A60X commit model (+ X1/X2 injection)
  logic inj_x1 = 1'b0, inj_x2 = 1'b0, inj_x3 = 1'b0;
  // plain always @* (not always_comb): req is shared with the procedural driver below
  always @* begin
    req.commit_valid       = req.issue_valid && resp.issue_ready;
    req.commit.hartid      = req.issue_req.hartid;
    req.commit.id          = req.issue_req.id ^ (inj_x1 ? 2'b01 : 2'b00);
    req.commit.commit_kill = inj_x2;
    req.register_valid     = req.issue_valid && !inj_x3;
  end

  // ------------------------------------------------------------ continuous pass-through checks (sampled at negedge)
  always @(negedge clk) if (rst_n) begin
    // CPU -> decoder
    if (issue_valid  !== req.issue_valid)            fail("issue_valid pass-through");
    if (issue_instr  !== req.issue_req.instr)        fail("issue_instr pass-through");
    if (issue_id     !== req.issue_req.id)           fail("issue_id pass-through");
    if (issue_hartid !== req.issue_req.hartid)       fail("issue_hartid pass-through");
    if (rs1          !== req.register.rs[0])         fail("rs1 pass-through");
    if (rs2          !== req.register.rs[1])         fail("rs2 pass-through");
    if (rs_valid     !== req.register.rs_valid)      fail("rs_valid pass-through");
    if (result_ready !== req.result_ready)           fail("result_ready pass-through");
    // decoder -> CPU
    if (resp.issue_ready    !== dec_issue_ready)     fail("issue_ready pass-through");
    if (resp.register_ready !== resp.issue_ready)    fail("register_ready != issue_ready");
    if (resp.issue_resp.accept        !== dec_accept)        fail("accept pass-through");
    if (resp.issue_resp.writeback     !== dec_writeback)     fail("writeback pass-through");
    if (resp.issue_resp.register_read !== dec_register_read) fail("register_read pass-through");
    if (resp.result_valid  !== dec_res_valid)        fail("result_valid pass-through");
    if (resp.result.hartid !== dec_res_hartid)       fail("result.hartid pass-through");
    if (resp.result.id     !== dec_res_id)           fail("result.id pass-through");
    if (resp.result.data   !== dec_res_data)         fail("result.data pass-through");
    if (resp.result.rd     !== dec_res_rd)           fail("result.rd pass-through");
    if (resp.result.we     !== dec_res_we)           fail("result.we pass-through");
    // DEC-14: a compressed offer is never stalled and never accepted
    if (mode != 5 && req.compressed_valid) begin
      offers++;
      if (resp.compressed_ready !== 1'b1)           fail("compressed offer stalled (ready != 1)");
      if (resp.compressed_resp.accept !== 1'b0)     fail("compressed offer accepted");
      if (resp.compressed_resp.instr  !== '0)       fail("compressed_resp.instr != 0");
    end
    if (resp.result_valid && req.result_ready) results++;
  end

  // ------------------------------------------------------------ random decoder-side and side-channel stimulus
  always @(posedge clk) begin
    #1;
    dec_issue_ready         = ($urandom_range(0, 3) != 0);   // ~75 % ready
    dec_res_valid           = $urandom_range(0, 1);
    dec_res_hartid          = $urandom;
    dec_res_id              = $urandom;
    dec_res_data            = $urandom;
    dec_res_rd              = $urandom;
    dec_res_we              = $urandom;
    req.result_ready        = $urandom_range(0, 1);
    req.compressed_valid    = $urandom_range(0, 1);
    req.compressed_req      = {$urandom, $urandom};
  end

  // ------------------------------------------------------------ MODE 5: break the DEC-14 tie-off for one cycle
  initial begin : inject_dec14
    cvxif_resp_t bad;
    wait (mode == 5 && inject_k >= 0 && handshakes == inject_k);
    @(negedge clk);
    bad = resp;
    bad.compressed_ready = 1'b0;
    force dut.cvxif_resp_o = bad;
    @(negedge clk);
    release dut.cvxif_resp_o;
  end

  // ------------------------------------------------------------ main: load vectors, drive issue transactions
  initial begin
    string vec_path;
    int fd, n;
    logic [31:0] w;
    logic [3:0] a, wb, rr, cat;

    if (!$value$plusargs("MODE=%d", mode)) mode = 0;
    if (!$value$plusargs("VEC=%s", vec_path)) vec_path = "../vectors/issue.hex";
    fd = $fopen(vec_path, "r");
    if (fd == 0) begin $display("TB_FATAL cannot open %s", vec_path); $finish; end
    while ($fscanf(fd, "%h %h %h %h %h\n", w, a, wb, rr, cat) == 5) begin
      v_instr.push_back(w);
      v_resp.push_back({a[0], wb[0], rr[1:0]});
      oracle[w] = {a[0], wb[0], rr[1:0]};
    end
    $fclose(fd);
    $display("TB_INFO mode=%0d vectors=%0d file=%s", mode, v_instr.size(), vec_path);

    // pick the injection point: first accepted vector at index >= 100 that reads a register
    for (int k = 100; k < v_instr.size(); k++)
      if (v_resp[k][3] && v_resp[k][1:0] != 2'b00) begin inject_k = k; break; end

    req = '0;
    dec_issue_ready = 1'b0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;

    for (int k = 0; k < v_instr.size(); k++) begin
      @(posedge clk); #2;
      req.issue_valid             = 1'b1;
      req.issue_req.instr         = v_instr[k];
      req.issue_req.id            = id_t'(k);
      req.issue_req.hartid        = $urandom;
      req.register.hartid         = req.issue_req.hartid;
      req.register.id             = req.issue_req.id;
      req.register.rs[0]          = $urandom;
      req.register.rs[1]          = $urandom;
      req.register.rs_valid       = (mode == 4 && k == inject_k) ? 2'b00 : 2'b11;
      inj_x1 = (mode == 1 && k == inject_k);
      inj_x2 = (mode == 2 && k == inject_k);
      inj_x3 = (mode == 3 && k == inject_k);

      // hold until the issue handshake (issue_valid && issue_ready) at a posedge
      do @(negedge clk); while (!resp.issue_ready);
      // oracle check on what the CPU sees for this instruction
      if (resp.issue_resp.accept        !== v_resp[k][3])   fail($sformatf("vec %0d instr %08h accept",   k, v_instr[k]));
      if (resp.issue_resp.writeback     !== v_resp[k][2])   fail($sformatf("vec %0d instr %08h writeback", k, v_instr[k]));
      if (resp.issue_resp.register_read !== v_resp[k][1:0]) fail($sformatf("vec %0d instr %08h register_read", k, v_instr[k]));
      handshakes++;
      if (v_resp[k][3]) accepted++;
      @(posedge clk); #1;
      req.issue_valid = 1'b0;
      inj_x1 = 1'b0; inj_x2 = 1'b0; inj_x3 = 1'b0;
    end

    repeat (4) @(posedge clk);
    $display("TB_SUMMARY mode=%0d vectors=%0d handshakes=%0d accepted=%0d compressed_offers=%0d results=%0d inject_k=%0d tb_errors=%0d",
             mode, v_instr.size(), handshakes, accepted, offers, results, inject_k, tb_errors);
    $finish;
  end

endmodule
