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

`define SLICE(arr, idx, width) arr[(idx)*(width) +: width]

`define HER_META(X) \
    `X(handler_mem_addr, AXI_ADDR_WIDTH) \
    `X(handler_mem_size, AXI_ADDR_WIDTH) \
    `X(host_mem_addr, AXI_HOST_ADDR_WIDTH) \
    `X(host_mem_size, AXI_ADDR_WIDTH) \
    `X(hh_addr, AXI_ADDR_WIDTH) \
    `X(hh_size, AXI_ADDR_WIDTH) \
    `X(ph_addr, AXI_ADDR_WIDTH) \
    `X(ph_size, AXI_ADDR_WIDTH) \
    `X(th_addr, AXI_ADDR_WIDTH) \
    `X(th_size, AXI_ADDR_WIDTH) \
    `X(scratchpad_0_addr, AXI_ADDR_WIDTH) \
    `X(scratchpad_0_size, AXI_ADDR_WIDTH) \
    `X(scratchpad_1_addr, AXI_ADDR_WIDTH) \
    `X(scratchpad_1_size, AXI_ADDR_WIDTH) \
    `X(scratchpad_2_addr, AXI_ADDR_WIDTH) \
    `X(scratchpad_2_size, AXI_ADDR_WIDTH) \
    `X(scratchpad_3_addr, AXI_ADDR_WIDTH) \
    `X(scratchpad_3_size, AXI_ADDR_WIDTH)

module pspin_her_gen #(
    parameter C_MSGID_WIDTH = 10,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_HOST_ADDR_WIDTH = 64,
    parameter LEN_WIDTH = 20,
    parameter TAG_WIDTH = 32,
    parameter NUM_HANDLER_CTX = 4
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
`define OUTPUT_HER_REG(name, width) output reg [(width)-1:0] her_meta_``name,
`HER_META(OUTPUT_HER_REG)

    // completion from ingress DMA
    input  wire [AXI_ADDR_WIDTH-1:0]        gen_addr,
    input  wire [LEN_WIDTH-1:0]             gen_len,
    input  wire [TAG_WIDTH-1:0]             gen_tag,
    input  wire                             gen_valid,
    output wire                             gen_ready,

    // execution context from ctrl regs
`define INPUT_CFG(name, width) input wire [NUM_HANDLER_CTX*(width)-1:0] conf_``name,
`HER_META(INPUT_CFG)
    input  wire [NUM_HANDLER_CTX-1:0]       conf_ctx_enabled,
    input  wire                             conf_valid
);

localparam CTX_ID_WIDTH = $clog2(NUM_HANDLER_CTX);
`define DEFAULT_CTX_ID {CTX_ID_WIDTH{1'b0}}

`define DEF_CTX_STORE(name, width) reg [(width)-1:0] name``_q [NUM_HANDLER_CTX-1:0];
`HER_META(DEF_CTX_STORE)
reg conf_ctx_enabled_q [NUM_HANDLER_CTX-1:0];

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
    for (idx = 0; idx < NUM_HANDLER_CTX; idx = idx + 1) begin
`define DUMP_CTX_STORE(name, width) $dumpvars(0, name``_q[idx]);
`HER_META(DUMP_CTX_STORE)
    end
end

// latch the config
integer i;
always @(posedge clk) begin
    if (!rstn) begin
        for (i = 0; i < NUM_HANDLER_CTX; i = i + 1) begin
`define RST_CTX_STORE(name, width) name``_q[i] <= {(width){1'b0}};
`HER_META(RST_CTX_STORE)
            conf_ctx_enabled_q[i] <= 1'b0;
        end
    end else if (conf_valid) begin
        for (i = 0; i < NUM_HANDLER_CTX; i = i + 1) begin
`define SET_CTX_STORE(name, width) name``_q[i] <=  `SLICE(conf_``name, i, width);
`HER_META(SET_CTX_STORE)
            conf_ctx_enabled_q[i] <= conf_ctx_enabled[i];
        end
    end
end

// decode tag => msgid, is_eom, ctx_id
assign {decode_msgid, decode_is_eom, decode_ctx_id} = gen_tag;

// default context set & PsPIN ready
assign gen_ready = conf_ctx_enabled_q[`DEFAULT_CTX_ID] && her_ready;

// generate HER on completion - 1 cycle latency
always @(posedge clk) begin
    if (gen_valid) begin
        her_msgid <= decode_msgid;
        her_is_eom <= decode_is_eom;
        her_addr <= gen_addr;
        her_size <= gen_len;
        // TODO: determine ratio of DMA to L1
        her_xfer_size <= gen_len;
`define ASSIGN_HER_META(name, width) \
    her_meta_``name <= name``_q[ \
        conf_ctx_enabled_q[decode_ctx_id] ? \
            decode_ctx_id : `DEFAULT_CTX_ID \
        ];
`HER_META(ASSIGN_HER_META)
        her_valid <= 1'b1;
    end

    if (her_valid && her_ready) begin
        her_valid <= 1'b0;
    end

    if (!rstn) begin
        her_valid <= 1'b0;
    end
end

endmodule