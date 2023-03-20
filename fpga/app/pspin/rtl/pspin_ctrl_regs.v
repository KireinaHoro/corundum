// control registers (32bit):
// - cluster fetch enable (RW) 0x0000
// - cluster reset (high) (RW) 0x0004

// - cluster eoc          (RO) 0x0108
// - cluster busy         (RO) 0x010c

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
//   match mode           (RW) 0x2000
//   match valid          (RW) 0x2004
//   match idx            (RW) 0x2100 - 0x2140
//   match mask           (RW) 0x2200 - 0x2240
//   match start          (RW) 0x2300 - 0x2340
//   match end            (RW) 0x2400 - 0x2440

module pspin_ctrl_regs #
(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH/8,
    parameter NUM_CLUSTERS = 2,
    parameter NUM_MPQ = 256,

    parameter UMATCH_WIDTH = 32,
    parameter UMATCH_ENTRIES = 16,
    parameter UMATCH_MODES = 2
) (
    input  wire                   clk,
    input  wire                   rst,

    /*
     * AXI-Lite slave interface
     */
    (* mark_debug = "true" *) input  wire [ADDR_WIDTH-1:0]  s_axil_awaddr,
    (* mark_debug = "true" *) input  wire [2:0]             s_axil_awprot,
    (* mark_debug = "true" *) input  wire                   s_axil_awvalid,
    (* mark_debug = "true" *) output wire                   s_axil_awready,
    (* mark_debug = "true" *) input  wire [DATA_WIDTH-1:0]  s_axil_wdata,
    (* mark_debug = "true" *) input  wire [STRB_WIDTH-1:0]  s_axil_wstrb,
    (* mark_debug = "true" *) input  wire                   s_axil_wvalid,
    (* mark_debug = "true" *) output wire                   s_axil_wready,
    (* mark_debug = "true" *) output wire [1:0]             s_axil_bresp,
    (* mark_debug = "true" *) output wire                   s_axil_bvalid,
    (* mark_debug = "true" *) input  wire                   s_axil_bready,
    (* mark_debug = "true" *) input  wire [ADDR_WIDTH-1:0]  s_axil_araddr,
    (* mark_debug = "true" *) input  wire [2:0]             s_axil_arprot,
    (* mark_debug = "true" *) input  wire                   s_axil_arvalid,
    (* mark_debug = "true" *) output wire                   s_axil_arready,
    (* mark_debug = "true" *) output wire [DATA_WIDTH-1:0]  s_axil_rdata,
    (* mark_debug = "true" *) output wire [1:0]             s_axil_rresp,
    (* mark_debug = "true" *) output wire                   s_axil_rvalid,
    (* mark_debug = "true" *) input  wire                   s_axil_rready,

    // register data
    (* mark_debug = "true" *) output reg  [NUM_CLUSTERS-1:0] cl_fetch_en_o,
    (* mark_debug = "true" *) output reg                     aux_rst_o,
    (* mark_debug = "true" *) input  wire [NUM_CLUSTERS-1:0] cl_eoc_i,
    (* mark_debug = "true" *) input  wire [NUM_CLUSTERS-1:0] cl_busy_i,
    (* mark_debug = "true" *) input  wire [NUM_MPQ-1:0]      mpq_full_i,
    
    // stdout FIFO
    (* mark_debug = "true" *) output reg                    stdout_rd_en,
    (* mark_debug = "true" *) input  wire [31:0]            stdout_dout,
    (* mark_debug = "true" *) input  wire                   stdout_data_valid,

    // matching engine configuration
    output reg  [$clog2(UMATCH_MODES)-1:0]                  match_mode_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES-1:0]           match_idx_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES-1:0]           match_mask_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES-1:0]           match_start_o,
    output reg  [UMATCH_WIDTH*UMATCH_ENTRIES-1:0]           match_end_o,
    output reg                                              match_valid_o
);

localparam VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
localparam WORD_WIDTH = STRB_WIDTH;
localparam WORD_SIZE = DATA_WIDTH/WORD_WIDTH;

localparam NUM_REGS = 4 + 8 + 1 + 2 + UMATCH_ENTRIES * 4;
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
`DECL_REG_HEAD(CL_CTRL, 2,           1'b0,   32'h0000)
`DECL_REG(CL_STAT,  2,               1'b1,   32'h0100, CL_CTRL)
`DECL_REG(MPQ,      8,               1'b1,   32'h0200, CL_STAT)
`DECL_REG(FIFO,     1,               1'b1,   32'h1000, MPQ)
`DECL_REG(ME,       2,               1'b0,   32'h2000, FIFO)
`DECL_REG(ME_IDX,   UMATCH_ENTRIES,  1'b0,   32'h2100, ME)
`DECL_REG(ME_MASK,  UMATCH_ENTRIES,  1'b0,   32'h2200, ME_IDX)
`DECL_REG(ME_START, UMATCH_ENTRIES,  1'b0,   32'h2300, ME_MASK)
`DECL_REG(ME_END,   UMATCH_ENTRIES,  1'b0,   32'h2400, ME_START)
endgenerate

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

`define GEN_DECODE(name) name``_BASE: regfile_idx = name``_REG_OFF + (block_offset >> (ADDR_WIDTH - VALID_ADDR_WIDTH));

// address decode
reg [VALID_ADDR_WIDTH-1:0] regfile_idx;
reg [15:0] block_id, block_offset;
always @* begin
    block_id     = reg_intf_wr_addr & 32'hff00;
    block_offset = reg_intf_wr_addr & 32'h00ff;
    case (block_id)
        `GEN_DECODE(CL_CTRL)
        `GEN_DECODE(MPQ)
        `GEN_DECODE(FIFO)
        `GEN_DECODE(ME)
        `GEN_DECODE(ME_IDX)
        `GEN_DECODE(ME_MASK)
        `GEN_DECODE(ME_START)
        `GEN_DECODE(ME_END)
        default:  regfile_idx = `REGFILE_IDX_INVALID;
    endcase
end

integer i;
// register output
always @* begin
    cl_fetch_en_o = ctrl_regs[CL_CTRL_REG_OFF];
    aux_rst_o = ctrl_regs[CL_CTRL_REG_OFF + 1][0];

    match_mode_o = ctrl_regs[ME_REG_OFF];
    match_valid_o = ctrl_regs[ME_REG_OFF + 1][0];
    for (i = 0; i < UMATCH_ENTRIES; i = i + 1) begin
        match_idx_o[i * UMATCH_WIDTH +: UMATCH_WIDTH] = ctrl_regs[ME_IDX_REG_OFF + i];
        match_mask_o[i * UMATCH_WIDTH +: UMATCH_WIDTH] = ctrl_regs[ME_MASK_REG_OFF + i];
        match_start_o[i * UMATCH_WIDTH +: UMATCH_WIDTH] = ctrl_regs[ME_START_REG_OFF + i];
        match_end_o[i * UMATCH_WIDTH +: UMATCH_WIDTH] = ctrl_regs[ME_END_REG_OFF + i];
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
                if (regfile_idx != `REGFILE_IDX_INVALID)
                    reg_intf_rd_data <= ctrl_regs[regfile_idx];
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
                if (regfile_idx != `REGFILE_IDX_INVALID && !REGFILE_IDX_READONLY[regfile_idx]) begin
                    ctrl_regs[regfile_idx][WORD_SIZE*i +: WORD_SIZE] <= reg_intf_wr_data[WORD_SIZE*i +: WORD_SIZE];
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
        for (i = 0; i < 8; i = i + 1) begin
            ctrl_regs[MPQ_REG_OFF] <= mpq_full_i[i*DATA_WIDTH +: DATA_WIDTH];
        end
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