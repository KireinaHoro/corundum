/**
 * PsPIN Handler Execution Request (HER) Generator
 *
 * The HER generator decodes metadata from the completion notification
 * from the ingress DMA to generate HERs for PsPIN.  The required metadata
 * is passed from the matching engine over the allocator, encoded in the tag
 * as an index for the execution contexts.
 *
 * The control registers interface programs the execution contexts enabled
 * for HER generation.  Packets that come with an invalid (disabled)
 * execution context will be dispatched to the default handler (id 0).  This
 * should always be set up before enabling the matching engine.
 */

`timescale 1ns / 1ps
`define SLICE(arr, idx, width) arr[(idx)*(width) +: width]

module pspin_her_gen #(
    parameter C_MSGID_WIDTH = 10,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_HOST_ADDR_WIDTH = 64,
    parameter LEN_WIDTH = 20,
    parameter TAG_WIDTH = 32,
) (
    input                                   clk,
    input                                   rstn,

    // HER to PsPIN wrapper
    input  wire                             her_ready,
    output reg                              her_valid,
    output reg  [C_MSGID_WIDTH-1:0]         her_msgid,
    output reg                              her_is_eom,
    output reg  [AXI_ADDR_WIDTH-1:0]        her_addr,
    output reg  [AXI_ADDR_WIDTH-1:0]        her_size,
    output reg  [AXI_ADDR_WIDTH-1:0]        her_xfer_size,
    output reg  [127:0] her_meta_handler_mem_addr_o,
    output reg  [127:0] her_meta_handler_mem_size_o,
    output reg  [255:0] her_meta_host_mem_addr_o,
    output reg  [127:0] her_meta_host_mem_size_o,
    output reg  [127:0] her_meta_hh_addr_o,
    output reg  [127:0] her_meta_hh_size_o,
    output reg  [127:0] her_meta_ph_addr_o,
    output reg  [127:0] her_meta_ph_size_o,
    output reg  [127:0] her_meta_th_addr_o,
    output reg  [127:0] her_meta_th_size_o,
    output reg  [127:0] her_meta_scratchpad_0_addr_o,
    output reg  [127:0] her_meta_scratchpad_0_size_o,
    output reg  [127:0] her_meta_scratchpad_1_addr_o,
    output reg  [127:0] her_meta_scratchpad_1_size_o,
    output reg  [127:0] her_meta_scratchpad_2_addr_o,
    output reg  [127:0] her_meta_scratchpad_2_size_o,
    output reg  [127:0] her_meta_scratchpad_3_addr_o,
    output reg  [127:0] her_meta_scratchpad_3_size_o,

    // execution context from ctrl regs
    input wire [127:0] conf_handler_mem_addr_o,
    input wire [127:0] conf_handler_mem_size_o,
    input wire [255:0] conf_host_mem_addr_o,
    input wire [127:0] conf_host_mem_size_o,
    input wire [127:0] conf_hh_addr_o,
    input wire [127:0] conf_hh_size_o,
    input wire [127:0] conf_ph_addr_o,
    input wire [127:0] conf_ph_size_o,
    input wire [127:0] conf_th_addr_o,
    input wire [127:0] conf_th_size_o,
    input wire [127:0] conf_scratchpad_0_addr_o,
    input wire [127:0] conf_scratchpad_0_size_o,
    input wire [127:0] conf_scratchpad_1_addr_o,
    input wire [127:0] conf_scratchpad_1_size_o,
    input wire [127:0] conf_scratchpad_2_addr_o,
    input wire [127:0] conf_scratchpad_2_size_o,
    input wire [127:0] conf_scratchpad_3_addr_o,
    input wire [127:0] conf_scratchpad_3_size_o,
    input wire [0:0] conf_valid_o,
    input wire [3:0] conf_ctx_enabled_o,

    // completion from ingress DMA
    input  wire [AXI_ADDR_WIDTH-1:0]        gen_addr,
    input  wire [LEN_WIDTH-1:0]             gen_len,
    input  wire [TAG_WIDTH-1:0]             gen_tag,
    input  wire                             gen_valid,
    output reg                              gen_ready
);


localparam UMATCH_WIDTH = 32;
localparam UMATCH_ENTRIES = 4;
localparam UMATCH_RULESETS = 4;
localparam UMATCH_MODES = 2;
localparam HER_NUM_HANDLER_CTX = 4;

localparam CTX_ID_WIDTH = $clog2(HER_NUM_HANDLER_CTX);
`define DEFAULT_CTX_ID {CTX_ID_WIDTH{1'b0}}
reg [3:0] store_handler_mem_addr [31:0];
reg [3:0] store_handler_mem_size [31:0];
reg [3:0] store_host_mem_addr [63:0];
reg [3:0] store_host_mem_size [31:0];
reg [3:0] store_hh_addr [31:0];
reg [3:0] store_hh_size [31:0];
reg [3:0] store_ph_addr [31:0];
reg [3:0] store_ph_size [31:0];
reg [3:0] store_th_addr [31:0];
reg [3:0] store_th_size [31:0];
reg [3:0] store_scratchpad_0_addr [31:0];
reg [3:0] store_scratchpad_0_size [31:0];
reg [3:0] store_scratchpad_1_addr [31:0];
reg [3:0] store_scratchpad_1_size [31:0];
reg [3:0] store_scratchpad_2_addr [31:0];
reg [3:0] store_scratchpad_2_size [31:0];
reg [3:0] store_scratchpad_3_addr [31:0];
reg [3:0] store_scratchpad_3_size [31:0];
reg [0:0] store_valid [0:0];
reg [3:0] store_ctx_enabled [0:0];

wire [C_MSGID_WIDTH-1:0] decode_msgid;
wire decode_is_eom;
wire [CTX_ID_WIDTH-1:0] decode_ctx_id;

integer idx;
initial begin
    if (C_MSGID_WIDTH + 1 + CTX_ID_WIDTH > TAG_WIDTH) begin
        $error("TAG_WIDTH = %d too small for C_MSGID_WIDTH = %d and CTX_ID_WIDTH = %d",
            TAG_WIDTH, C_MSGID_WIDTH, CTX_ID_WIDTH);
        $finish;
    end

    // dump for icarus verilog
    for (idx = 0; idx < HER_NUM_HANDLER_CTX; idx = idx + 1) begin
$dumpvars(0, store_handler_mem_addr[idx]);
$dumpvars(0, store_handler_mem_size[idx]);
$dumpvars(0, store_host_mem_addr[idx]);
$dumpvars(0, store_host_mem_size[idx]);
$dumpvars(0, store_hh_addr[idx]);
$dumpvars(0, store_hh_size[idx]);
$dumpvars(0, store_ph_addr[idx]);
$dumpvars(0, store_ph_size[idx]);
$dumpvars(0, store_th_addr[idx]);
$dumpvars(0, store_th_size[idx]);
$dumpvars(0, store_scratchpad_0_addr[idx]);
$dumpvars(0, store_scratchpad_0_size[idx]);
$dumpvars(0, store_scratchpad_1_addr[idx]);
$dumpvars(0, store_scratchpad_1_size[idx]);
$dumpvars(0, store_scratchpad_2_addr[idx]);
$dumpvars(0, store_scratchpad_2_size[idx]);
$dumpvars(0, store_scratchpad_3_addr[idx]);
$dumpvars(0, store_scratchpad_3_size[idx]);
$dumpvars(0, store_valid[idx]);
$dumpvars(0, store_ctx_enabled[idx]);
    end
end

// latch the config
always @(posedge clk) begin
    if (!rstn) begin
        for (idx = 0; idx < HER_NUM_HANDLER_CTX; idx = idx + 1) begin
store_handler_mem_addr[idx] <= 32'b0;
store_handler_mem_size[idx] <= 32'b0;
store_host_mem_addr[idx] <= 64'b0;
store_host_mem_size[idx] <= 32'b0;
store_hh_addr[idx] <= 32'b0;
store_hh_size[idx] <= 32'b0;
store_ph_addr[idx] <= 32'b0;
store_ph_size[idx] <= 32'b0;
store_th_addr[idx] <= 32'b0;
store_th_size[idx] <= 32'b0;
store_scratchpad_0_addr[idx] <= 32'b0;
store_scratchpad_0_size[idx] <= 32'b0;
store_scratchpad_1_addr[idx] <= 32'b0;
store_scratchpad_1_size[idx] <= 32'b0;
store_scratchpad_2_addr[idx] <= 32'b0;
store_scratchpad_2_size[idx] <= 32'b0;
store_scratchpad_3_addr[idx] <= 32'b0;
store_scratchpad_3_size[idx] <= 32'b0;
store_valid[idx] <= 1'b0;
store_ctx_enabled[idx] <= 1'b0;
        end
    end else if (conf_valid) begin
        for (idx = 0; idx < HER_NUM_HANDLER_CTX; idx = idx + 1) begin
store_handler_mem_addr[idx] <= conf_handler_mem_addr[idx];
store_handler_mem_size[idx] <= conf_handler_mem_size[idx];
store_host_mem_addr[idx] <= conf_host_mem_addr[idx];
store_host_mem_size[idx] <= conf_host_mem_size[idx];
store_hh_addr[idx] <= conf_hh_addr[idx];
store_hh_size[idx] <= conf_hh_size[idx];
store_ph_addr[idx] <= conf_ph_addr[idx];
store_ph_size[idx] <= conf_ph_size[idx];
store_th_addr[idx] <= conf_th_addr[idx];
store_th_size[idx] <= conf_th_size[idx];
store_scratchpad_0_addr[idx] <= conf_scratchpad_0_addr[idx];
store_scratchpad_0_size[idx] <= conf_scratchpad_0_size[idx];
store_scratchpad_1_addr[idx] <= conf_scratchpad_1_addr[idx];
store_scratchpad_1_size[idx] <= conf_scratchpad_1_size[idx];
store_scratchpad_2_addr[idx] <= conf_scratchpad_2_addr[idx];
store_scratchpad_2_size[idx] <= conf_scratchpad_2_size[idx];
store_scratchpad_3_addr[idx] <= conf_scratchpad_3_addr[idx];
store_scratchpad_3_size[idx] <= conf_scratchpad_3_size[idx];
store_valid[idx] <= conf_valid[idx];
store_ctx_enabled[idx] <= conf_ctx_enabled[idx];
        end
    end
end

// decode tag => msgid, is_eom, ctx_id
assign {decode_msgid, decode_is_eom, decode_ctx_id} = gen_tag;

// generate HER on completion - combinatorial
// FIXME: use a skid buffer if timing becomes an issue
always @* begin
    her_msgid = decode_msgid;
    her_is_eom = decode_is_eom;
    her_addr = gen_addr;
    her_size = gen_len;
    // TODO: determine ratio of DMA to L1
    her_xfer_size = gen_len;

    her_meta_handler_mem_addr = store_handler_mem_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_handler_mem_size = store_handler_mem_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_host_mem_addr = store_host_mem_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_host_mem_size = store_host_mem_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_hh_addr = store_hh_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_hh_size = store_hh_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_ph_addr = store_ph_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_ph_size = store_ph_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_th_addr = store_th_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_th_size = store_th_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_0_addr = store_scratchpad_0_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_0_size = store_scratchpad_0_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_1_addr = store_scratchpad_1_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_1_size = store_scratchpad_1_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_2_addr = store_scratchpad_2_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_2_size = store_scratchpad_2_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_3_addr = store_scratchpad_3_addr[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_meta_scratchpad_3_size = store_scratchpad_3_size[store_ctx_enabled[decode_ctx_id] ? decode_ctx_id : `DEFAULT_CTX_ID];
    her_valid = gen_valid;

    // default context set & PsPIN ready
    gen_ready = store_ctx_enabled[`DEFAULT_CTX_ID] && her_ready;
end

endmodule