// RVNE-ASYNC — shared parameters and types.
// Contract: docs/rtl_module_spec.md §3.2. Values: D1 §2, D2 §1/§6, D3 §3, DEC-03.
// CV-X-IF struct member order matches CVA6 cv32a60x-v6.0.0 (b1f80bd)
// core/include/cvxif_types.svh exactly; do not reorder.
`timescale 1ns/1ps

package rvne_pkg;

  // ---------------------------------------------------------------- D1 §2
  localparam int XLEN       = 32;
  localparam int W_BITS     = 4;
  localparam int N_WVR      = 16;
  localparam int N_SVR      = 16;
  localparam int ENTRY_BITS = 32;
  localparam int SPM_BYTES  = 16384;
  localparam int SPM_BANKS  = 16;
  localparam int SPM_ROWS   = 256;
  localparam int SPM_AW     = 14;

  // ---------------------------------------------------------------- D2
  localparam logic [6:0] OPC_CUSTOM0    = 7'b0001011;
  localparam logic [6:0] OPC_CUSTOM1    = 7'b0101011;
  localparam logic [7:0] STATUS_VERSION = 8'h01;

  // ---------------------------------------------------------------- D3 §3
  typedef enum logic [3:0] {
    OP_SPM_SW = 4'h0,
    OP_SPM_LW = 4'h1,
    OP_LW_WV  = 4'h2,
    OP_LH_WV  = 4'h3,
    OP_LA_WV  = 4'h4,
    OP_LW_SV  = 4'h5,
    OP_LH_SV  = 4'h6,
    OP_LA_SV  = 4'h7,
    OP_RD_WV  = 4'h8,
    OP_RD_SV  = 4'h9
  } bridge_op_e;

  typedef struct packed {
    bridge_op_e        op;
    logic [3:0]        idx;
    logic [SPM_AW-1:0] addr;
    logic [31:0]       wdata;
  } bridge_cmd_t;  // 54 b

  typedef logic [N_WVR-1:0][ENTRY_BITS-1:0] vec_t;  // 16 x 32 b

  // ---------------------------------------------------------------- CV-X-IF (DEC-03)
  localparam int X_NUM_RS       = 2;
  localparam int X_ID_WIDTH     = 2;
  localparam int X_RFR_WIDTH    = 32;
  localparam int X_RFW_WIDTH    = 32;
  localparam int X_HARTID_WIDTH = 32;
  localparam int X_DUALREAD     = 0;
  localparam int X_DUALWRITE    = 0;

  typedef logic [X_NUM_RS+X_DUALREAD-1:0] readregflags_t;
  typedef logic [X_DUALWRITE:0]           writeregflags_t;
  typedef logic [X_ID_WIDTH-1:0]          id_t;
  typedef logic [X_HARTID_WIDTH-1:0]      hartid_t;

  typedef struct packed {
    logic [15:0] instr;
    hartid_t     hartid;
  } x_compressed_req_t;

  typedef struct packed {
    logic [31:0] instr;
    logic        accept;
  } x_compressed_resp_t;

  typedef struct packed {
    logic [31:0] instr;
    hartid_t     hartid;
    id_t         id;
  } x_issue_req_t;

  typedef struct packed {
    logic           accept;
    writeregflags_t writeback;
    readregflags_t  register_read;
  } x_issue_resp_t;

  typedef struct packed {
    hartid_t                                 hartid;
    id_t                                     id;
    logic [X_NUM_RS-1:0][X_RFR_WIDTH-1:0]    rs;
    readregflags_t                           rs_valid;
  } x_register_t;

  typedef struct packed {
    hartid_t hartid;
    id_t     id;
    logic    commit_kill;
  } x_commit_t;

  typedef struct packed {
    hartid_t                hartid;
    id_t                    id;
    logic [X_RFW_WIDTH-1:0] data;
    logic [4:0]             rd;
    writeregflags_t         we;
  } x_result_t;

  typedef struct packed {
    logic              compressed_valid;
    x_compressed_req_t compressed_req;
    logic              issue_valid;
    x_issue_req_t      issue_req;
    logic              register_valid;
    x_register_t       register;
    logic              commit_valid;
    x_commit_t         commit;
    logic              result_ready;
  } cvxif_req_t;

  typedef struct packed {
    logic               compressed_ready;
    x_compressed_resp_t compressed_resp;
    logic               issue_ready;
    x_issue_resp_t      issue_resp;
    logic               register_ready;
    logic               result_valid;
    x_result_t          result;
  } cvxif_resp_t;

endpackage
