// control registers (32bit):
// - cluster fetch enable (W) 0x0000
// - cluster reset (high) (W) 0x0004
// - cluster eoc          (R) 0x0100
// - cluster busy         (R) 0x0104
// - mpq full             (R) 0x0108
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

    // register data out
    output wire [NUM_CLUSTERS-1:0] cl_fetch_en_o,
    output wire                    aux_rst_o,
    input  wire [NUM_CLUSTERS-1:0] cl_eoc_i,
    input  wire [NUM_CLUSTERS-1:0] cl_busy_i,
    input  wire [NUM_MPQ-1:0]      mpq_full_i,
    
    // stdout FIFO
    output wire                   stdout_rd_en,
    input  wire                   stdout_rd_rst_busy,
    input  wire [31:0]            stdout_dout
);

localparam VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
localparam WORD_WIDTH = STRB_WIDTH;
localparam WORD_SIZE = DATA_WIDTH/WORD_WIDTH;

localparam NUM_RDONLY_REGS = 3;
localparam NUM_WRONLY_REGS = 2;
reg [DATA_WIDTH-1:0] ctrl_rd_regs [NUM_RDONLY_REGS-1:0];
reg [DATA_WIDTH-1:0] ctrl_wr_regs [NUM_WRONLY_REGS-1:0];
reg [DATA_WIDTH-1:0] reg_intf_rd_data;
reg reg_intf_rd_ack;
reg reg_intf_wr_ack;
assign ctrl_reg_inst.reg_rd_data = reg_intf_rd_data;
assign ctrl_reg_inst.reg_rd_ack = reg_intf_rd_ack;
assign ctrl_reg_inst.reg_wr_ack = reg_intf_wr_ack;
assign ctrl_reg_inst.reg_rd_wait = 'b0;
assign ctrl_reg_inst.reg_wr_wait = 'b0;

wire [VALID_ADDR_WIDTH-1:0] reg_rd_addr_valid = ctrl_reg_inst.reg_rd_addr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire reg_rd_in_range = reg_rd_addr_valid < NUM_RDONLY_REGS;
wire [VALID_ADDR_WIDTH-1:0] reg_wr_addr_valid = ctrl_reg_inst.reg_wr_addr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire reg_wr_in_range = reg_wr_addr_valid < NUM_WRONLY_REGS;

reg stdout_rd_en_reg;
assign stdout_rd_en = stdout_rd_en_reg;
assign cl_fetch_en_o = ctrl_wr_regs[0];
assign aux_rst_o = ctrl_wr_regs[1][0];

integer i;
always @(posedge clk, posedge rst) begin
    if (rst) begin
        for (i = 0; i < NUM_RDONLY_REGS; i = i + 1) begin
            ctrl_rd_regs[i] <= 'h0;
        end
        for (i = 0; i < NUM_WRONLY_REGS; i = i + 1) begin
            ctrl_wr_regs[i] <= 'h0;
        end
        reg_intf_rd_data <= 'h0;
        reg_intf_rd_ack <= 'b0;
        reg_intf_wr_ack <= 'b0;
    end else begin
        // read
        if (ctrl_reg_inst.reg_rd_en) begin
            if (ctrl_reg_inst.reg_rd_addr == 'h1000) begin
                if (stdout_rd_rst_busy) begin
                    // FIFO not ready, give garbage data
                    reg_intf_rd_data <= 'hffffffff;
                end else begin
                    stdout_rd_en_reg <= 'b1;
                    reg_intf_rd_data <= stdout_dout;
                end
            end else begin
                if (reg_rd_in_range)
                    reg_intf_rd_data <= ctrl_rd_regs[reg_rd_addr_valid];
                else
                    reg_intf_rd_data <= 'hffffffff;
            end
            reg_intf_rd_ack <= 'b1;
        end else if (reg_intf_rd_ack) begin
            reg_intf_rd_ack <= 'b0;
            stdout_rd_en_reg <= 'b0;
        end

        // write
        for (i = 0; i < STRB_WIDTH; i = i + 1) begin
            if (ctrl_reg_inst.reg_wr_en && ctrl_reg_inst.reg_wr_strb[i] && reg_wr_in_range) begin
                ctrl_wr_regs[reg_wr_addr_valid][WORD_SIZE*i +: WORD_SIZE] <= ctrl_reg_inst.reg_wr_data[WORD_SIZE*i +: WORD_SIZE];
                reg_intf_wr_ack <= 'b1;
            end else if (reg_intf_wr_ack) begin
                reg_intf_wr_ack <= 'b0;
            end
        end

        // update
        ctrl_rd_regs[0] <= cl_eoc_i;   // eoc
        ctrl_rd_regs[1] <= cl_busy_i;  // busy
        ctrl_rd_regs[2] <= mpq_full_i; // mpq full
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
    .s_axil_rready          (s_axil_rready)
);

endmodule