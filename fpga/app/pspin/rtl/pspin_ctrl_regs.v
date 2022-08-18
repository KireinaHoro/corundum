// control registers (32bit):
// - cluster fetch enable (W) 0x0000
// - cluster reset (high) (W) 0x0004
// - cluster eoc          (R) 0x0100
// - cluster busy         (R) 0x0104
// - mpq full[ 31:  0]    (R) 0x0108
// - mpq full[ 63: 32]    (R) 0x010c
// - mpq full[ 95: 64]    (R) 0x0110
// - mpq full[127: 96]    (R) 0x0114
// - mpq full[159:128]    (R) 0x0118
// - mpq full[191:160]    (R) 0x011c
// - mpq full[223:192]    (R) 0x0120
// - mpq full[255:224]    (R) 0x0124
// - stdout FIFO          (R) 0x1000

module pspin_ctrl_regs #
(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter STRB_WIDTH = DATA_WIDTH/8,
    parameter NUM_CLUSTERS = 2,
    parameter NUM_MPQ = 256
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

    // PsPIN-facing interfaces are in this clock
    input  wire                   pspin_clk,

    // register data - in pspin_clk
    output wire [NUM_CLUSTERS-1:0] cl_fetch_en_o,
    output wire                    aux_rst_o,
    input  wire [NUM_CLUSTERS-1:0] cl_eoc_i,
    input  wire [NUM_CLUSTERS-1:0] cl_busy_i,
    input  wire [NUM_MPQ-1:0]      mpq_full_i,
    
    // stdout FIFO - in pspin_clk
    output wire                   stdout_rd_en,
    input  wire                   stdout_rd_rst_busy,
    input  wire [31:0]            stdout_dout
);

localparam VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
localparam WORD_WIDTH = STRB_WIDTH;
localparam WORD_SIZE = DATA_WIDTH/WORD_WIDTH;

// base of read regs 0x100
localparam [VALID_ADDR_WIDTH-1:0] FILLED_BASE = {{VALID_ADDR_WIDTH{1'b0}}, 'h100};
localparam [VALID_ADDR_WIDTH-1:0] FIFO_BASE = {{VALID_ADDR_WIDTH{1'b0}}, 'h1000};

localparam NUM_RDONLY_REGS = 10;
localparam NUM_WRONLY_REGS = 2;
reg [DATA_WIDTH-1:0] ctrl_rd_regs [NUM_RDONLY_REGS-1:0];
reg [DATA_WIDTH-1:0] ctrl_wr_regs [NUM_WRONLY_REGS-1:0];

reg [DATA_WIDTH-1:0] reg_intf_rd_data;
wire [DATA_WIDTH-1:0] reg_intf_wr_data;
reg reg_intf_rd_ack;
reg reg_intf_wr_ack;

wire reg_intf_rd_en;
wire reg_intf_wr_en;
wire [ADDR_WIDTH-1:0] reg_intf_rd_addr;
wire [ADDR_WIDTH-1:0] reg_intf_wr_addr;
wire [STRB_WIDTH-1:0] reg_intf_wr_strb;
wire [VALID_ADDR_WIDTH-1:0] reg_rd_addr_valid = (reg_intf_rd_addr - FILLED_BASE) >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [VALID_ADDR_WIDTH-1:0] reg_wr_addr_valid = reg_intf_wr_addr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire reg_rd_in_range = reg_intf_rd_addr >= FILLED_BASE && reg_rd_addr_valid < NUM_RDONLY_REGS;
wire reg_wr_in_range = reg_wr_addr_valid < NUM_WRONLY_REGS;

reg stdout_rd_en_reg;
assign stdout_rd_en = stdout_rd_en_reg;

// CDC
wire [NUM_CLUSTERS-1:0] cl_eoc_x;
wire [NUM_CLUSTERS-1:0] cl_busy_x;
wire [NUM_MPQ-1:0]      mpq_full_x;

bus_cdc_wrap #(.WIDTH(2*NUM_CLUSTERS+NUM_MPQ)) i_cdc_in (
    .src_clk(pspin_clk),
    .dest_clk(clk),
    .src_in({cl_eoc_i, cl_busy_i, mpq_full_i}),
    .dest_out({cl_eoc_x, cl_busy_x, mpq_full_x})
);

bus_cdc_wrap #(.WIDTH(NUM_CLUSTERS+1)) i_cdc_out (
    .src_clk(clk),
    .dest_clk(pspin_clk),
    .src_in({ctrl_wr_regs[0], ctrl_wr_regs[1][0]}),
    .dest_out({cl_fetch_en_o, aux_rst_o})
);

integer i;
always @(posedge clk, posedge rst) begin
    if (rst) begin
        for (i = 0; i < NUM_RDONLY_REGS; i = i + 1) begin
            ctrl_rd_regs[i] <= {DATA_WIDTH{1'b0}};
        end
        for (i = 0; i < NUM_WRONLY_REGS; i = i + 1) begin
            if (i == 1) // reset output - reset high
                ctrl_wr_regs[i] <= {DATA_WIDTH{1'b1}};
            else
                ctrl_wr_regs[i] <= {DATA_WIDTH{1'h0}};
        end
        reg_intf_rd_data <= {DATA_WIDTH{1'h0}};
        reg_intf_rd_ack <= 1'b0;
        reg_intf_wr_ack <= 1'b0;
    end else begin
        // read
        if (reg_intf_rd_en) begin
            if (reg_intf_rd_addr == FIFO_BASE) begin
                if (stdout_rd_rst_busy) begin
                    // FIFO not ready, give garbage data
                    reg_intf_rd_data <= {DATA_WIDTH{1'b1}};
                end else begin
                    stdout_rd_en_reg <= 'b1;
                    reg_intf_rd_data <= stdout_dout;
                end
            end else begin
                if (reg_rd_in_range)
                    reg_intf_rd_data <= ctrl_rd_regs[reg_rd_addr_valid];
                else
                    reg_intf_rd_data <= {DATA_WIDTH{1'b1}};
            end
            reg_intf_rd_ack <= 'b1;
        end else if (reg_intf_rd_ack) begin
            reg_intf_rd_ack <= 'b0;
            stdout_rd_en_reg <= 'b0;
        end

        // write
        for (i = 0; i < STRB_WIDTH; i = i + 1) begin
            if (reg_intf_wr_en && reg_intf_wr_strb[i] && reg_wr_in_range) begin
                ctrl_wr_regs[reg_wr_addr_valid][WORD_SIZE*i +: WORD_SIZE] <= reg_intf_wr_data[WORD_SIZE*i +: WORD_SIZE];
                reg_intf_wr_ack <= 'b1;
            end else if (reg_intf_wr_ack) begin
                reg_intf_wr_ack <= 'b0;
            end
        end

        // update
        ctrl_rd_regs[0] <= cl_eoc_x;   // eoc
        ctrl_rd_regs[1] <= cl_busy_x;  // busy
        
        for (i = 0; i < 8; i = i + 1) begin
            ctrl_rd_regs[2 + i] <= mpq_full_x[i*DATA_WIDTH +: DATA_WIDTH];
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