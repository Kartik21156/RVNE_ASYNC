// RVNE-ASYNC — D6.3 testbench for rvne_decoder (+ rvne_status).
//
// Part A — issue classification. With issue_valid = 0 (FSM idle), every word
//   in vectors/issue.hex is applied to issue_instr and the combinational
//   accept / writeback / register_read are compared against D5. Results are
//   counted per D2 §5.1 category.
// Part B — sequential behaviour. vectors/txn.hex (a D5-executed program) is
//   issued through the decoder's CV-X-IF-side ports with CV32A60X timing; a
//   bridge stand-in accepts commands and returns D5's rsp_rdata after random
//   delays. For every instruction the TB checks accept, the exact bridge
//   command (or its absence), the result, and STATUS afterwards.
//   An operand-value error must never raise cmd_valid (DEC-07).
`timescale 1ns/1ps

module tb_rvne_decoder;
  import rvne_pkg::*;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------ DUT
  logic          issue_valid = 1'b0, result_ready = 1'b0;
  logic [31:0]   issue_instr = '0, rs1 = '0, rs2 = '0;
  id_t           issue_id = '0;
  hartid_t       issue_hartid = '0;
  readregflags_t rs_valid = '0;

  logic          issue_ready, accept, writeback;
  readregflags_t register_read;
  logic          result_valid, result_we;
  hartid_t       result_hartid;
  id_t           result_id;
  logic [31:0]   result_data;
  logic [4:0]    result_rd;

  logic          cmd_valid, cmd_ready = 1'b0, rsp_valid = 1'b0;
  bridge_cmd_t   cmd;
  logic [31:0]   rsp_rdata = '0;

  rvne_decoder dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .issue_valid_i        (issue_valid),
    .issue_instr_i        (issue_instr),
    .issue_id_i           (issue_id),
    .issue_hartid_i       (issue_hartid),
    .rs1_i                (rs1),
    .rs2_i                (rs2),
    .rs_valid_i           (rs_valid),
    .result_ready_i       (result_ready),
    .issue_ready_o        (issue_ready),
    .issue_accept_o       (accept),
    .issue_writeback_o    (writeback),
    .issue_register_read_o(register_read),
    .result_valid_o       (result_valid),
    .result_hartid_o      (result_hartid),
    .result_id_o          (result_id),
    .result_data_o        (result_data),
    .result_rd_o          (result_rd),
    .result_we_o          (result_we),
    .cmd_valid_o          (cmd_valid),
    .cmd_o                (cmd),
    .cmd_ready_i          (cmd_ready),
    .rsp_valid_i          (rsp_valid),
    .rsp_rdata_i          (rsp_rdata)
  );

  // ------------------------------------------------------------ bookkeeping
  int tb_errors = 0;
  task automatic fail(string what);
    tb_errors++;
    if (tb_errors <= 30) $display("TB_ERROR t=%0t %s", $time, what);
  endtask

  int cat_total [16];
  int cat_pass  [16];
  int a_vectors = 0, a_mismatch = 0;
  int b_txn = 0, b_accepted = 0, b_rejected = 0, b_cmds = 0, b_operr = 0, b_status_rd = 0;
  int cmd_count = 0;               // cmd handshakes seen by the bridge stand-in
  always @(posedge clk) if (cmd_valid && cmd_ready) cmd_count++;

  // Any cycle with cmd_valid is recorded so a forbidden command is caught even
  // if it is never handshaken.
  int cmd_valid_cycles = 0;
  always @(posedge clk) if (rst_n && cmd_valid) cmd_valid_cycles++;

  // ------------------------------------------------------------ +FAULT=1: corrupt one bridge command
  // Proves a_cmd_wellformed is live: on the first lh.* command, misalign its
  // address for one cycle while cmd_valid is high.
  int fault = 0;
  initial begin : inject_fault
    bridge_cmd_t bad;
    if (!$value$plusargs("FAULT=%d", fault)) fault = 0;
    if (fault == 1) begin
      wait (cmd_valid && (cmd.op inside {OP_LH_WV, OP_LH_SV}));
      @(negedge clk);
      bad = dut.cmd_q;
      bad.addr[2] = 1'b1;
      force dut.cmd_q = bad;
      @(negedge clk);
      release dut.cmd_q;
    end
  end

  // ------------------------------------------------------------ main
  initial begin
    int fd;
    logic [31:0] w, f_rs1, f_rs2, f_op, f_idx, f_addr, f_wdata, f_rsp, f_rd, f_data, f_status;
    logic [3:0]  a, wb, rr, cat;
    logic [31:0] f_acc, f_hascmd, f_hasres, f_we;
    hartid_t     hid;
    int          k, cmd_before, cv_before;

    // ============================ Part A
    fd = $fopen("../vectors/issue.hex", "r");
    if (fd == 0) begin $display("TB_FATAL cannot open issue.hex"); $finish; end
    repeat (2) @(posedge clk);
    while ($fscanf(fd, "%h %h %h %h %h\n", w, a, wb, rr, cat) == 5) begin
      issue_instr = w;
      #1;
      a_vectors++;
      cat_total[cat]++;
      if (accept === a[0] && writeback === wb[0] && register_read === rr[1:0]) cat_pass[cat]++;
      else begin
        a_mismatch++;
        fail($sformatf("PartA %08h cat=%0h: got acc=%b wb=%b rr=%b exp %b %b %b",
                       w, cat, accept, writeback, register_read, a[0], wb[0], rr[1:0]));
      end
    end
    $fclose(fd);
    issue_instr = '0;
    for (int c = 0; c < 16; c++)
      if (cat_total[c] != 0)
        $display("TB_PARTA_CAT %0h total=%0d pass=%0d", c, cat_total[c], cat_pass[c]);

    // ============================ Part B
    @(posedge clk); #1 rst_n = 1'b1;
    // R4 refinement: issue_ready must stay low for the INIT cycles
    @(negedge clk); if (issue_ready !== 1'b0) fail("issue_ready high in INIT cycle 1");
    @(negedge clk); if (issue_ready !== 1'b0) fail("issue_ready high in INIT cycle 2");

    fd = $fopen("../vectors/txn.hex", "r");
    if (fd == 0) begin $display("TB_FATAL cannot open txn.hex"); $finish; end
    k = 0;
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                   w, f_rs1, f_rs2, f_acc, f_hascmd, f_op, f_idx, f_addr, f_wdata, f_rsp,
                   f_hasres, f_we, f_rd, f_data, f_status) == 15) begin
      b_txn++;
      hid = $urandom;
      cmd_before = cmd_count;
      cv_before  = cmd_valid_cycles;

      // ---- issue (CV32A60X: operands with issue, commit implied same cycle)
      @(posedge clk); #1;
      issue_valid  = 1'b1;
      issue_instr  = w;
      issue_id     = id_t'(k);
      issue_hartid = hid;
      rs1          = f_rs1;
      rs2          = f_rs2;
      rs_valid     = 2'b11;
      do @(negedge clk); while (!issue_ready);
      if (accept !== f_acc[0]) fail($sformatf("txn %0d %08h accept=%b exp %b", k, w, accept, f_acc[0]));
      @(posedge clk); #1;               // handshake edge has passed
      issue_valid = 1'b0;
      issue_instr = $urandom;           // must not matter after acceptance
      rs1 = $urandom; rs2 = $urandom;

      if (!f_acc[0]) begin
        b_rejected++;
        @(negedge clk);
        if (!issue_ready)  fail($sformatf("txn %0d rejected but decoder left IDLE", k));
        if (result_valid)  fail($sformatf("txn %0d rejected but produced a result", k));
      end else begin
        b_accepted++;
        // ---- bridge stand-in
        if (f_hascmd[0]) begin
          b_cmds++;
          do @(negedge clk); while (!cmd_valid && !result_valid);
          if (!cmd_valid) fail($sformatf("txn %0d expected bridge cmd, got result first", k));
          else begin
            if (cmd.op    !== bridge_op_e'(f_op[3:0])) fail($sformatf("txn %0d cmd.op %0h exp %0h", k, cmd.op, f_op));
            if (cmd.idx   !== f_idx[3:0])               fail($sformatf("txn %0d cmd.idx %0h exp %0h", k, cmd.idx, f_idx));
            if (cmd.addr  !== f_addr[SPM_AW-1:0])       fail($sformatf("txn %0d cmd.addr %0h exp %0h", k, cmd.addr, f_addr));
            if (cmd.wdata !== f_wdata)                  fail($sformatf("txn %0d cmd.wdata %08h exp %08h", k, cmd.wdata, f_wdata));
            repeat ($urandom_range(0, 3)) @(posedge clk);
            #1 cmd_ready = 1'b1;
            @(posedge clk); #1 cmd_ready = 1'b0;
            repeat ($urandom_range(0, 4)) @(posedge clk);
            #1 rsp_valid = 1'b1; rsp_rdata = f_rsp;
            @(posedge clk); #1 rsp_valid = 1'b0; rsp_rdata = $urandom;
          end
        end else begin
          if (((w & 32'h707F) == 32'h302B)) b_status_rd++; else b_operr++;
        end

        // ---- result
        do @(negedge clk); while (!result_valid);
        repeat ($urandom_range(0, 2)) begin
          @(posedge clk); @(negedge clk);
          if (!result_valid) fail($sformatf("txn %0d result_valid dropped before ready", k));
        end
        if (result_we   !== f_we[0])     fail($sformatf("txn %0d result.we %b exp %b", k, result_we, f_we[0]));
        if (result_rd   !== f_rd[4:0])   fail($sformatf("txn %0d result.rd %0d exp %0d", k, result_rd, f_rd));
        if (result_data !== f_data)      fail($sformatf("txn %0d %08h result.data %08h exp %08h", k, w, result_data, f_data));
        if (result_id   !== id_t'(k))    fail($sformatf("txn %0d result.id %0d", k, result_id));
        if (result_hartid !== hid)       fail($sformatf("txn %0d result.hartid mismatch", k));
        #1 result_ready = 1'b1;
        @(posedge clk); #1 result_ready = 1'b0;
      end

      // ---- DEC-07: no command unless D5 says so; STATUS afterwards
      if (!f_hascmd[0] && (cmd_count != cmd_before || cmd_valid_cycles != cv_before))
        fail($sformatf("txn %0d %08h: cmd_valid raised for an instruction with no bridge command (DEC-07)", k, w));
      if (f_hascmd[0] && cmd_count != cmd_before + 1)
        fail($sformatf("txn %0d: expected exactly one bridge command", k));
      @(negedge clk);
      if (dut.status !== f_status) fail($sformatf("txn %0d %08h STATUS %08h exp %08h", k, w, dut.status, f_status));
      k++;
    end
    $fclose(fd);

    repeat (3) @(posedge clk);
    $display("TB_SUMMARY partA_vectors=%0d partA_mismatch=%0d partB_txn=%0d accepted=%0d rejected=%0d bridge_cmds=%0d operand_errors=%0d status_reads=%0d cmd_handshakes=%0d tb_errors=%0d",
             a_vectors, a_mismatch, b_txn, b_accepted, b_rejected, b_cmds, b_operr, b_status_rd, cmd_count, tb_errors);
    $finish;
  end

endmodule
