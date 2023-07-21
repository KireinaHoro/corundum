// control registers (32bit):
// - cluster fetch enable (RW) 0x0000
// - cluster reset (high) (RW) 0x0004

// - cluster eoc          (RO) 0x0100
// - cluster busy         (RO) 0x0104

// - mpq full[ 31:  0]    (RO) 0x0200
// - mpq full[ 63: 32]    (RO) 0x0204
// - mpq full[ 95: 64]    (RO) 0x0208
// - mpq full[127: 96]    (RO) 0x020c
// - mpq full[159:128]    (RO) 0x0210
// - mpq full[191:160]    (RO) 0x0214
// - mpq full[223:192]    (RO) 0x0218
// - mpq full[255:224]    (RO) 0x021c

// - stdout FIFO          (RO) 0x1000

// - matching engine
//   match valid          (RW) 0x2000
//   match mode           (RW) 0x2100 -
//   match idx            (RW) 0x2200 -
//   match mask           (RW) 0x2300 -
//   match start          (RW) 0x2400 -
//   match end            (RW) 0x2500 -

// - in/e-gress datapath statistics
//   alloc dropped pkts   (RO) 0x2600
//   egress dma error     (RO) 0x2604

// - HER generator
//   conf_valid           (RW) 0x3000
//   conf_ctx_enabled     (RW) 0x3100 -
//   handler_mem_addr     (RW) 0x3200 -
//   handler_mem_size     (RW) 0x3300 -
//   host_mem_addr_lo     (RW) 0x3400 -
//   host_mem_addr_hi     (RW) 0x3500 -
//   host_mem_size        (RW) 0x3600 -
//   hh_addr              (RW) 0x3700 -
//   hh_size              (RW) 0x3800 -
//   ph_addr              (RW) 0x3900 -
//   ph_size              (RW) 0x3a00 -
//   th_addr              (RW) 0x3b00 -
//   th_size              (RW) 0x3c00 -
//   scratchpad_0_addr    (RW) 0x3d00 -
//   scratchpad_0_size    (RW) 0x3e00 -
//   scratchpad_1_addr    (RW) 0x3f00 -
//   scratchpad_1_size    (RW) 0x4000 -
//   scratchpad_2_addr    (RW) 0x4100 -
//   scratchpad_2_size    (RW) 0x4200 -
//   scratchpad_3_addr    (RW) 0x4300 -
//   scratchpad_3_size    (RW) 0x4400 -

`timescale 1ns / 1ps
`define SLICE(arr, idx, width) arr[(idx)*(width) +: width]

// XXX: We are latching most of the configuration again at the consumer side.
//      Should we only latch it once here / at the consumer (timing
//      considerations)?
module pspin_ctrl_regs #
(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH/8,
    parameter NUM_CLUSTERS = 2,
    parameter NUM_MPQ = 16,

    parameter UMATCH_WIDTH = 32,
    parameter UMATCH_ENTRIES = 4,
    parameter UMATCH_RULESETS = 4,
    parameter UMATCH_MODES = 2,

    parameter HER_NUM_HANDLER_CTX = 4
) (
    input  wire                   clk,
    input  wire                   rst,

    /*
     * AXI-Lite slave interface
     */
    input  wire [ADDR_WIDTH-1:0]  s_axil_awaddr,
    input  wire [2:0]             s_axil_awprot,
    input  wire                   s_axil_awvalid,
    output wire                   s_axil_awready,
    input  wire [DATA_WIDTH-1:0]  s_axil_wdata,
    input  wire [STRB_WIDTH-1:0]  s_axil_wstrb,
    input  wire                   s_axil_wvalid,
    output wire                   s_axil_wready,
    output wire [1:0]             s_axil_bresp,
    output wire                   s_axil_bvalid,
    input  wire                   s_axil_bready,
    input  wire [ADDR_WIDTH-1:0]  s_axil_araddr,
    input  wire [2:0]             s_axil_arprot,
    input  wire                   s_axil_arvalid,
    output wire                   s_axil_arready,
    output wire [DATA_WIDTH-1:0]  s_axil_rdata,
    output wire [1:0]             s_axil_rresp,
    output wire                   s_axil_rvalid,
    input  wire                   s_axil_rready,

    // register data
    output reg  [NUM_CLUSTERS-1:0] cl_fetch_en_o,
    output reg                     aux_rst_o,
    input  wire [NUM_CLUSTERS-1:0] cl_eoc_i,
    input  wire [NUM_CLUSTERS-1:0] cl_busy_i,
    input  wire [NUM_MPQ-1:0]      mpq_full_i,
    
    // stdout FIFO
    output reg                    stdout_rd_en,
    input  wire [31:0]            stdout_dout,
    input  wire                   stdout_data_valid,

    // packet allocator dropped packets
    input  wire [31:0]                                      alloc_dropped_pkts,

    // matching engine configuration
    output reg  [$clog2(UMATCH_MODES)*UMATCH_RULESETS-1:0]                  match_mode_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES*UMATCH_RULESETS-1:0]           match_idx_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES*UMATCH_RULESETS-1:0]           match_mask_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES*UMATCH_RULESETS-1:0]           match_start_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES*UMATCH_RULESETS-1:0]           match_end_o,
    output reg                                              match_valid_o,

    // HER generator execution context
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_handler_mem_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_handler_mem_size,
    output reg  [HER_NUM_HANDLER_CTX*64-1:0]                her_gen_host_mem_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_host_mem_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_hh_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_hh_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_ph_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_ph_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_th_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_th_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_0_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_0_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_1_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_1_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_2_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_2_size,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_3_addr,
    output reg  [HER_NUM_HANDLER_CTX*32-1:0]                her_gen_scratchpad_3_size,
    output reg  [HER_NUM_HANDLER_CTX-1:0]                   her_gen_enabled,
    output reg                                              her_gen_valid,

    // egress datapath
    input  wire [3:0]                                       egress_dma_last_error
);

localparam VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
localparam WORD_WIDTH = STRB_WIDTH;
localparam WORD_SIZE = DATA_WIDTH/WORD_WIDTH;

localparam NUM_REGS =
    4 + 1 + 1 + // PsPIN
    1 + UMATCH_RULESETS + UMATCH_RULESETS * UMATCH_ENTRIES * 4 + // MATCH
    2 + // DATAPATH_STATS
    1 + HER_NUM_HANDLER_CTX * 20 + // HER
    1; // GUARD
reg [DATA_WIDTH-1:0] ctrl_regs [NUM_REGS-1:0];

`define REGFILE_IDX_INVALID {VALID_ADDR_WIDTH{1'b1}}
wire [NUM_REGS-1:0] REGFILE_IDX_READONLY;

`define DECL_REG_COMMON(name, count, addr_offset) \
    localparam [ADDR_WIDTH-1:0] name``_BASE = {{ADDR_WIDTH{1'b0}}, addr_offset}; \
    localparam name``_REG_COUNT = count;
`define DECL_REG_RDONLY(name, rdonly) \
        genvar i_``name; \
        for (i_``name = name``_REG_OFF; \
            i_``name < name``_REG_OFF + name``_REG_COUNT; \
            i_``name = i_``name + 1) \
            assign REGFILE_IDX_READONLY[i_``name] = rdonly;
`define DECL_REG_HEAD(name, count, rdonly, addr_offset) \
    `DECL_REG_COMMON(name, count, addr_offset) \
    localparam [$clog2(NUM_REGS)-1:0] name``_REG_OFF = 0; \
    `DECL_REG_RDONLY(name, rdonly)
`define DECL_REG(name, count, rdonly, addr_offset, prev_block) \
    `DECL_REG_COMMON(name, count, addr_offset) \
    localparam [$clog2(NUM_REGS)-1:0] name``_REG_OFF = prev_block``_REG_OFF + prev_block``_REG_COUNT; \
    `DECL_REG_RDONLY(name, rdonly)

generate
// FIXME: ideally this is generated from one source of ground-truth for all
//        consumers (this module in Verilog AND the kernel driver)
`DECL_REG_HEAD(CL_CTRL, 2,           1'b0,   32'h0000)
`DECL_REG(CL_STAT,  2,               1'b1,   32'h0100, CL_CTRL)
`DECL_REG(MPQ,      1,               1'b1,   32'h0200, CL_STAT)
`DECL_REG(FIFO,     1,               1'b1,   32'h1000, MPQ)

`DECL_REG(ME_VALID, 1,                               1'b0,   32'h2000, FIFO)
`DECL_REG(ME_MODE,  UMATCH_RULESETS,                 1'b0,   32'h2100, ME_VALID)
`DECL_REG(ME_IDX,   UMATCH_ENTRIES*UMATCH_RULESETS,  1'b0,   32'h2200, ME_MODE)
`DECL_REG(ME_MASK,  UMATCH_ENTRIES*UMATCH_RULESETS,  1'b0,   32'h2300, ME_IDX)
`DECL_REG(ME_START, UMATCH_ENTRIES*UMATCH_RULESETS,  1'b0,   32'h2400, ME_MASK)
`DECL_REG(ME_END,   UMATCH_ENTRIES*UMATCH_RULESETS,  1'b0,   32'h2500, ME_START)

`DECL_REG(DATAPATH_STATS,           2,                      1'b1,   32'h2600, ME_END)

`DECL_REG(HER,                      1,                      1'b0,   32'h3000, DATAPATH_STATS)
`DECL_REG(HER_CTX_ENABLED,          HER_NUM_HANDLER_CTX,    1'b0,   32'h3100, HER)
`DECL_REG(HER_HANDLER_MEM_ADDR,     HER_NUM_HANDLER_CTX,    1'b0,   32'h3200, HER_CTX_ENABLED)
`DECL_REG(HER_HANDLER_MEM_SIZE,     HER_NUM_HANDLER_CTX,    1'b0,   32'h3300, HER_HANDLER_MEM_ADDR)
`DECL_REG(HER_HOST_MEM_ADDR_LO,     HER_NUM_HANDLER_CTX,    1'b0,   32'h3400, HER_HANDLER_MEM_SIZE)
`DECL_REG(HER_HOST_MEM_ADDR_HI,     HER_NUM_HANDLER_CTX,    1'b0,   32'h3500, HER_HOST_MEM_ADDR_LO)
`DECL_REG(HER_HOST_MEM_SIZE,        HER_NUM_HANDLER_CTX,    1'b0,   32'h3600, HER_HOST_MEM_ADDR_HI)
`DECL_REG(HER_HH_ADDR,              HER_NUM_HANDLER_CTX,    1'b0,   32'h3700, HER_HOST_MEM_SIZE)
`DECL_REG(HER_HH_SIZE,              HER_NUM_HANDLER_CTX,    1'b0,   32'h3800, HER_HH_ADDR)
`DECL_REG(HER_PH_ADDR,              HER_NUM_HANDLER_CTX,    1'b0,   32'h3900, HER_HH_SIZE)
`DECL_REG(HER_PH_SIZE,              HER_NUM_HANDLER_CTX,    1'b0,   32'h3a00, HER_PH_ADDR)
`DECL_REG(HER_TH_ADDR,              HER_NUM_HANDLER_CTX,    1'b0,   32'h3b00, HER_PH_SIZE)
`DECL_REG(HER_TH_SIZE,              HER_NUM_HANDLER_CTX,    1'b0,   32'h3c00, HER_TH_ADDR)
`DECL_REG(HER_SCRATCHPAD_0_ADDR,    HER_NUM_HANDLER_CTX,    1'b0,   32'h3d00, HER_TH_SIZE)
`DECL_REG(HER_SCRATCHPAD_0_SIZE,    HER_NUM_HANDLER_CTX,    1'b0,   32'h3e00, HER_SCRATCHPAD_0_ADDR)
`DECL_REG(HER_SCRATCHPAD_1_ADDR,    HER_NUM_HANDLER_CTX,    1'b0,   32'h3f00, HER_SCRATCHPAD_0_SIZE)
`DECL_REG(HER_SCRATCHPAD_1_SIZE,    HER_NUM_HANDLER_CTX,    1'b0,   32'h4000, HER_SCRATCHPAD_1_ADDR)
`DECL_REG(HER_SCRATCHPAD_2_ADDR,    HER_NUM_HANDLER_CTX,    1'b0,   32'h4100, HER_SCRATCHPAD_1_SIZE)
`DECL_REG(HER_SCRATCHPAD_2_SIZE,    HER_NUM_HANDLER_CTX,    1'b0,   32'h4200, HER_SCRATCHPAD_2_ADDR)
`DECL_REG(HER_SCRATCHPAD_3_ADDR,    HER_NUM_HANDLER_CTX,    1'b0,   32'h4300, HER_SCRATCHPAD_2_SIZE)
`DECL_REG(HER_SCRATCHPAD_3_SIZE,    HER_NUM_HANDLER_CTX,    1'b0,   32'h4400, HER_SCRATCHPAD_3_ADDR)

`DECL_REG(GUARD,                    1,                      1'b1,   32'hff00, HER_SCRATCHPAD_3_SIZE)
endgenerate

initial begin
    if (NUM_REGS != GUARD_REG_OFF + 1) begin
        $error("NUM_REGS mismatch with end of reg declaration, please update");
        $finish;
    end
end

// register interface
wire [ADDR_WIDTH-1:0] reg_intf_rd_addr;
reg [DATA_WIDTH-1:0] reg_intf_rd_data;
wire reg_intf_rd_en;
reg reg_intf_rd_ack;
wire [ADDR_WIDTH-1:0] reg_intf_wr_addr;
wire [DATA_WIDTH-1:0] reg_intf_wr_data;
wire [STRB_WIDTH-1:0] reg_intf_wr_strb;
wire reg_intf_wr_en;
reg reg_intf_wr_ack;

// address decode
`define GEN_DECODE(op, name) name``_BASE: regfile_idx_``op = name``_REG_OFF + (block_offset_``op >> (ADDR_WIDTH - VALID_ADDR_WIDTH));
`define DECODE_ADDR(op) \
    reg [VALID_ADDR_WIDTH-1:0] regfile_idx_``op; \
    reg [15:0] block_id_``op, block_offset_``op; \
    always @* begin \
        block_id_``op     = reg_intf_``op``_addr & 32'hff00; \
        block_offset_``op = reg_intf_``op``_addr & 32'h00ff; \
        case (block_id_``op) \
            `GEN_DECODE(op, CL_CTRL) \
            `GEN_DECODE(op, CL_STAT) \
            `GEN_DECODE(op, MPQ) \
            `GEN_DECODE(op, FIFO) \
            `GEN_DECODE(op, ME_VALID) \
            `GEN_DECODE(op, ME_MODE) \
            `GEN_DECODE(op, ME_IDX) \
            `GEN_DECODE(op, ME_MASK) \
            `GEN_DECODE(op, ME_START) \
            `GEN_DECODE(op, ME_END) \
            `GEN_DECODE(op, DATAPATH_STATS) \
            `GEN_DECODE(op, HER) \
            `GEN_DECODE(op, HER_CTX_ENABLED) \
            `GEN_DECODE(op, HER_HANDLER_MEM_ADDR) \
            `GEN_DECODE(op, HER_HANDLER_MEM_SIZE) \
            `GEN_DECODE(op, HER_HOST_MEM_ADDR_LO) \
            `GEN_DECODE(op, HER_HOST_MEM_ADDR_HI) \
            `GEN_DECODE(op, HER_HOST_MEM_SIZE) \
            `GEN_DECODE(op, HER_HH_ADDR) \
            `GEN_DECODE(op, HER_HH_SIZE) \
            `GEN_DECODE(op, HER_PH_ADDR) \
            `GEN_DECODE(op, HER_PH_SIZE) \
            `GEN_DECODE(op, HER_TH_ADDR) \
            `GEN_DECODE(op, HER_TH_SIZE) \
            `GEN_DECODE(op, HER_SCRATCHPAD_0_ADDR) \
            `GEN_DECODE(op, HER_SCRATCHPAD_0_SIZE) \
            `GEN_DECODE(op, HER_SCRATCHPAD_1_ADDR) \
            `GEN_DECODE(op, HER_SCRATCHPAD_1_SIZE) \
            `GEN_DECODE(op, HER_SCRATCHPAD_2_ADDR) \
            `GEN_DECODE(op, HER_SCRATCHPAD_2_SIZE) \
            `GEN_DECODE(op, HER_SCRATCHPAD_3_ADDR) \
            `GEN_DECODE(op, HER_SCRATCHPAD_3_SIZE) \
            default:  regfile_idx_``op = `REGFILE_IDX_INVALID; \
        endcase \
    end

`DECODE_ADDR(wr)
`DECODE_ADDR(rd)

integer i;
// register output
always @* begin
    cl_fetch_en_o = ctrl_regs[CL_CTRL_REG_OFF];
    aux_rst_o = ctrl_regs[CL_CTRL_REG_OFF + 1][0];

    match_valid_o = ctrl_regs[ME_VALID_REG_OFF][0];

    for (i = 0; i < UMATCH_RULESETS; i = i + 1) begin
        `SLICE(match_mode_o , i, $clog2(UMATCH_MODES)) = ctrl_regs[ME_MODE_REG_OFF + i];
    end

    for (i = 0; i < UMATCH_ENTRIES*UMATCH_RULESETS; i = i + 1) begin
        `SLICE(match_idx_o  , i, UMATCH_WIDTH) = ctrl_regs[ME_IDX_REG_OFF + i];
        `SLICE(match_mask_o , i, UMATCH_WIDTH) = ctrl_regs[ME_MASK_REG_OFF + i];
        `SLICE(match_start_o, i, UMATCH_WIDTH) = ctrl_regs[ME_START_REG_OFF + i];
        `SLICE(match_end_o  , i, UMATCH_WIDTH) = ctrl_regs[ME_END_REG_OFF + i];
    end

    her_gen_valid = ctrl_regs[HER_REG_OFF][0];
    for (i = 0; i < HER_NUM_HANDLER_CTX; i = i + 1) begin
        `SLICE(her_gen_handler_mem_addr , i, 32) = ctrl_regs[HER_HANDLER_MEM_ADDR_REG_OFF + i];
        `SLICE(her_gen_handler_mem_size , i, 32) = ctrl_regs[HER_HANDLER_MEM_SIZE_REG_OFF + i];
        `SLICE(her_gen_host_mem_addr    , i, 64) = {
            ctrl_regs[HER_HOST_MEM_ADDR_HI_REG_OFF + i],
            ctrl_regs[HER_HOST_MEM_ADDR_LO_REG_OFF + i]};
        `SLICE(her_gen_host_mem_size    , i, 32) = ctrl_regs[HER_HOST_MEM_SIZE_REG_OFF + i];
        `SLICE(her_gen_hh_addr          , i, 32) = ctrl_regs[HER_HH_ADDR_REG_OFF + i];
        `SLICE(her_gen_hh_size          , i, 32) = ctrl_regs[HER_HH_SIZE_REG_OFF + i];
        `SLICE(her_gen_ph_addr          , i, 32) = ctrl_regs[HER_PH_ADDR_REG_OFF + i];
        `SLICE(her_gen_ph_size          , i, 32) = ctrl_regs[HER_PH_SIZE_REG_OFF + i];
        `SLICE(her_gen_th_addr          , i, 32) = ctrl_regs[HER_TH_ADDR_REG_OFF + i];
        `SLICE(her_gen_th_size          , i, 32) = ctrl_regs[HER_TH_SIZE_REG_OFF + i];
        `SLICE(her_gen_scratchpad_0_addr, i, 32) = ctrl_regs[HER_SCRATCHPAD_0_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_0_size, i, 32) = ctrl_regs[HER_SCRATCHPAD_0_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_1_addr, i, 32) = ctrl_regs[HER_SCRATCHPAD_1_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_1_size, i, 32) = ctrl_regs[HER_SCRATCHPAD_1_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_2_addr, i, 32) = ctrl_regs[HER_SCRATCHPAD_2_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_2_size, i, 32) = ctrl_regs[HER_SCRATCHPAD_2_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_3_addr, i, 32) = ctrl_regs[HER_SCRATCHPAD_3_ADDR_REG_OFF + i];
        `SLICE(her_gen_scratchpad_3_size, i, 32) = ctrl_regs[HER_SCRATCHPAD_3_ADDR_REG_OFF + i];
        `SLICE(her_gen_enabled          , i, 1)  = ctrl_regs[HER_CTX_ENABLED_REG_OFF + i][0];
    end
end

always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < NUM_REGS; i = i + 1) begin
            if (i == CL_CTRL_REG_OFF + 1)
                ctrl_regs[i] = {DATA_WIDTH{1'b1}};
            else
                ctrl_regs[i] = {DATA_WIDTH{1'b0}};
        end
        reg_intf_rd_data <= {DATA_WIDTH{1'h0}};
        reg_intf_rd_ack <= 1'b0;
        reg_intf_wr_ack <= 1'b0;
    end else begin
        // read
        if (reg_intf_rd_en) begin
            if (reg_intf_rd_addr == FIFO_BASE) begin
                if (!stdout_data_valid) begin
                    // FIFO data not valid, give garbage data
                    reg_intf_rd_data <= {DATA_WIDTH{1'b1}};
                end else begin
                    stdout_rd_en <= 'b1;
                    reg_intf_rd_data <= stdout_dout;
                end
            end else begin
                if (regfile_idx_rd != `REGFILE_IDX_INVALID)
                    reg_intf_rd_data <= ctrl_regs[regfile_idx_rd];
                else
                    reg_intf_rd_data <= {DATA_WIDTH{1'b1}};
            end
            reg_intf_rd_ack <= 'b1;
        end

        if (reg_intf_rd_ack) begin
            reg_intf_rd_ack <= 'b0;
            stdout_rd_en <= 'b0;
        end

        // write
        for (i = 0; i < STRB_WIDTH; i = i + 1) begin
            if (reg_intf_wr_en && reg_intf_wr_strb[i]) begin
                if (regfile_idx_wr != `REGFILE_IDX_INVALID && !REGFILE_IDX_READONLY[regfile_idx_wr]) begin
                    `SLICE(ctrl_regs[regfile_idx_wr], i, WORD_SIZE) <= `SLICE(reg_intf_wr_data, i, WORD_SIZE);
                end
                reg_intf_wr_ack <= 'b1;
            end

            if (reg_intf_wr_ack) begin
                reg_intf_wr_ack <= 'b0;
            end
        end

        // register input
        ctrl_regs[CL_STAT_REG_OFF]     <= cl_eoc_i;   // eoc
        ctrl_regs[CL_STAT_REG_OFF + 1] <= cl_busy_i;  // busy

        // we only have 16 MPQs
        ctrl_regs[MPQ_REG_OFF] <= {{DATA_WIDTH - NUM_MPQ{1'b0}}, mpq_full_i};

        ctrl_regs[DATAPATH_STATS_REG_OFF] <= alloc_dropped_pkts;
        ctrl_regs[DATAPATH_STATS_REG_OFF + 1] <= {28'b0, egress_dma_last_error};
    end
end

axil_reg_if #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .STRB_WIDTH(STRB_WIDTH)
) ctrl_reg_inst (
    .clk(clk),
    .rst(rst),

    .s_axil_awaddr          (s_axil_awaddr),
    .s_axil_awprot          (s_axil_awprot),
    .s_axil_awvalid         (s_axil_awvalid),
    .s_axil_awready         (s_axil_awready),
    .s_axil_wdata           (s_axil_wdata),
    .s_axil_wstrb           (s_axil_wstrb),
    .s_axil_wvalid          (s_axil_wvalid),
    .s_axil_wready          (s_axil_wready),
    .s_axil_bresp           (s_axil_bresp),
    .s_axil_bvalid          (s_axil_bvalid),
    .s_axil_bready          (s_axil_bready),
    .s_axil_araddr          (s_axil_araddr),
    .s_axil_arprot          (s_axil_arprot),
    .s_axil_arvalid         (s_axil_arvalid),
    .s_axil_arready         (s_axil_arready),
    .s_axil_rdata           (s_axil_rdata),
    .s_axil_rresp           (s_axil_rresp),
    .s_axil_rvalid          (s_axil_rvalid),
    .s_axil_rready          (s_axil_rready),

    .reg_rd_addr            (reg_intf_rd_addr),
    .reg_rd_en              (reg_intf_rd_en),
    .reg_rd_data            (reg_intf_rd_data),
    .reg_rd_ack             (reg_intf_rd_ack),
    .reg_rd_wait            (1'b0),

    .reg_wr_addr            (reg_intf_wr_addr),
    .reg_wr_strb            (reg_intf_wr_strb),
    .reg_wr_en              (reg_intf_wr_en),
    .reg_wr_data            (reg_intf_wr_data),
    .reg_wr_ack             (reg_intf_wr_ack),
    .reg_wr_wait            (1'b0)
);

endmodule