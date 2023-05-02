/**
 * PsPIN host memory DMA write datapath
 *
 * Write datapath of the host memory DMA adapter.  Utilises the verilog-pcie
 * DMA client to AXIS, driving the R channel of full AXI.
 *
 * We make a lot of assumptions against tricky corner cases; see the
 * respective assertions in the code for details.
 *
 * This module does not contain the DMA memory between the client and
 * interface, for the sake of ease of testing (verilog-pcie only provides
 * a model for the RAM and not a RAM master).  The RAM should be instantiated
 * in the parent module.
 */

`timescale 1ns / 1ps
module pspin_hostmem_dma_wr #(
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,
    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 20,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    parameter ADDR_WIDTH = 64,
    parameter DATA_WIDTH = 512,
    parameter STRB_WIDTH = (DATA_WIDTH/8),
    parameter ID_WIDTH = 8,
    parameter AWUSER_WIDTH = 1,
    parameter WUSER_WIDTH = 1,
    parameter BUSER_WIDTH = 1,
    parameter ARUSER_WIDTH = 1,
    parameter RUSER_WIDTH = 1
) (
    input  wire                                         clk,
    input  wire                                         rstn,

    /*
     * DMA write descriptor output (data)
     */
    output wire [ADDR_WIDTH-1:0]                          m_axis_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                       m_axis_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                      m_axis_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                       m_axis_write_desc_imm,
    output wire                                           m_axis_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                       m_axis_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                       m_axis_write_desc_tag,
    output wire                                           m_axis_write_desc_valid,
    input  wire                                           m_axis_write_desc_ready,

    /*
     * DMA write descriptor status input (data)
     */
    input  wire [DMA_TAG_WIDTH-1:0]                       s_axis_write_desc_status_tag,
    input  wire [3:0]                                     s_axis_write_desc_status_error,
    input  wire                                           s_axis_write_desc_status_valid,

    /*
     * DMA RAM interface (data)
     */
    output wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]      ram_wr_cmd_be,
    output wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]    ram_wr_cmd_addr,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]    ram_wr_cmd_data,
    output wire [RAM_SEG_COUNT-1:0]                       ram_wr_cmd_valid,
    input  wire [RAM_SEG_COUNT-1:0]                       ram_wr_cmd_ready,
    input  wire [RAM_SEG_COUNT-1:0]                       ram_wr_done,


    /* AXI AW, W & B channels */
    input  wire [ID_WIDTH-1:0]                            s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]                          s_axi_awaddr,
    input  wire [7:0]                                     s_axi_awlen,
    input  wire [2:0]                                     s_axi_awsize,
    input  wire [1:0]                                     s_axi_awburst,
    input  wire                                           s_axi_awlock,
    input  wire [3:0]                                     s_axi_awcache,
    input  wire [2:0]                                     s_axi_awprot,
    input  wire [3:0]                                     s_axi_awqos,
    input  wire [3:0]                                     s_axi_awregion,
    input  wire [AWUSER_WIDTH-1:0]                        s_axi_awuser,
    input  wire                                           s_axi_awvalid,
    output wire                                           s_axi_awready,
    input  wire [DATA_WIDTH-1:0]                          s_axi_wdata,
    input  wire [STRB_WIDTH-1:0]                          s_axi_wstrb,
    input  wire                                           s_axi_wlast,
    input  wire [WUSER_WIDTH-1:0]                         s_axi_wuser,
    input  wire                                           s_axi_wvalid,
    output wire                                           s_axi_wready,
    output wire [ID_WIDTH-1:0]                            s_axi_bid,
    output wire [1:0]                                     s_axi_bresp,
    output wire [BUSER_WIDTH-1:0]                         s_axi_buser,
    output wire                                           s_axi_bvalid,
    input  wire                                           s_axi_bready
);

// TODO: stub
assign m_axis_write_desc_valid = 1'b0;
assign ram_wr_cmd_valid = 1'b0;

assign s_axi_awready = 1'b0;
assign s_axi_wready = 1'b0;
assign s_axi_bvalid = 1'b0;

endmodule