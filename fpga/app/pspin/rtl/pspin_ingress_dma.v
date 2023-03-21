/**
 * PsPIN Ingress DMA Engine
 *
 * Writes the matched AXI Stream frame data into the packet buffer of PsPIN.
 * Holds incoming frame until allocated address from pspin_pkt_alloc arrives,
 * then pushes frame to AXI Stream to AXI engine.
 */

`timescale 1ns / 1ns

module pspin_ingress_dma #(
    parameter AXIS_IF_DATA_WIDTH = 512,
    parameter AXIS_IF_KEEP_WIDTH = AXIS_IF_DATA_WIDTH/8,
    parameter AXIS_IF_RX_ID_WIDTH = 1,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_RX_USER_WIDTH = 16,

    parameter AXI_DATA_WIDTH = 512, // pspin_cfg_pkg::data_t
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_STRB_WIDTH = (AXI_DATA_WIDTH/8),
    parameter AXI_ID_WIDTH = 8,

    parameter LEN_WIDTH = 20,
    parameter TAG_WIDTH = 8,

    parameter INGRESS_DMA_MTU = 1500
) (
    input wire clk,
    input wire rstn,

    // from packet allocator
    input  wire [AXI_ADDR_WIDTH-1:0]             write_desc_addr,
    input  wire [LEN_WIDTH-1:0]                  write_desc_len,
    input  wire [TAG_WIDTH-1:0]                  write_desc_tag,
    input  wire                                  write_desc_valid,
    output wire                                  write_desc_ready,

    // from matching engine
    input  wire [AXIS_IF_DATA_WIDTH-1:0]         s_axis_pspin_rx_tdata,
    input  wire [AXIS_IF_KEEP_WIDTH-1:0]         s_axis_pspin_rx_tkeep,
    input  wire                                  s_axis_pspin_rx_tvalid,
    output wire                                  s_axis_pspin_rx_tready,
    input  wire                                  s_axis_pspin_rx_tlast,
    input  wire [AXIS_IF_RX_ID_WIDTH-1:0]        s_axis_pspin_rx_tid,
    input  wire [AXIS_IF_RX_DEST_WIDTH-1:0]      s_axis_pspin_rx_tdest,
    input  wire [AXIS_IF_RX_USER_WIDTH-1:0]      s_axis_pspin_rx_tuser,

    // to PsPIN NIC Inbound
    output wire [AXI_ID_WIDTH-1:0]               m_axi_pspin_awid,
    output wire [AXI_ADDR_WIDTH-1:0]             m_axi_pspin_awaddr,
    output wire [7:0]                            m_axi_pspin_awlen,
    output wire [2:0]                            m_axi_pspin_awsize,
    output wire [1:0]                            m_axi_pspin_awburst,
    output wire                                  m_axi_pspin_awlock,
    output wire [3:0]                            m_axi_pspin_awcache,
    output wire [2:0]                            m_axi_pspin_awprot,
    output wire                                  m_axi_pspin_awvalid,
    input  wire                                  m_axi_pspin_awready,
    output wire [AXI_DATA_WIDTH-1:0]             m_axi_pspin_wdata,
    output wire [AXI_STRB_WIDTH-1:0]             m_axi_pspin_wstrb,
    output wire                                  m_axi_pspin_wlast,
    output wire                                  m_axi_pspin_wvalid,
    input  wire                                  m_axi_pspin_wready,
    input  wire [AXI_ID_WIDTH-1:0]               m_axi_pspin_bid,
    input  wire [1:0]                            m_axi_pspin_bresp,
    input  wire                                  m_axi_pspin_bvalid,
    output wire                                  m_axi_pspin_bready,

    // to HER gen - no ready intf, shouldn't block
    output wire [AXI_ADDR_WIDTH-1:0]             her_gen_addr,
    output wire [LEN_WIDTH-1:0]                  her_gen_len,
    output wire [TAG_WIDTH-1:0]                  her_gen_tag,
    output wire                                  her_gen_valid
);

localparam PACKET_BEATS = (UMATCH_MTU * 8 + AXIS_IF_DATA_WIDTH - 1) / (AXIS_IF_DATA_WIDTH);
localparam BUFFER_FIFO_DEPTH = 2 * PACKET_BEATS * AXIS_IF_KEEP_WIDTH;

// encode addr in tag for HER gen
localparam DMA_TAG_WIDTH = TAG_WIDTH + AXI_ADDR_WIDTH;

wire [AXIS_IF_DATA_WIDTH-1:0]         s_axis_buffered_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]         s_axis_buffered_tkeep;
wire                                  s_axis_buffered_tvalid;
wire                                  s_axis_buffered_tready;
wire                                  s_axis_buffered_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]        s_axis_buffered_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]      s_axis_buffered_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]      s_axis_buffered_tuser;
wire                                  buffered_overflow;
wire                                  buffered_good_frame;
wire                                  buffered_bad_frame;

wire [AXI_ADDR_WIDTH-1:0]             desc_status_addr;
wire [LEN_WIDTH-1:0]                  desc_status_len;
wire [TAG_WIDTH-1:0]                  desc_status_tag;
wire [AXIS_IF_RX_ID_WIDTH-1:0]        desc_status_id;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]      desc_status_dest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]      desc_status_user;
wire [3:0]                            desc_status_error;
wire                                  desc_status_valid;

assign her_gen_addr  = desc_status_addr;
assign her_gen_len   = desc_status_len;
assign her_gen_tag   = desc_status_tag;

// desc_status_error: axi_dma_wr.v
assign her_gen_valid = desc_status_valid && desc_status_error == 4'd0;

// DMA does not ready streaming intf until receiving desc
// but length always come after.  buffer here with a FIFO
axis_fifo #(
    .DEPTH(BUFFER_FIFO_DEPTH),
    .DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .KEEP_ENABLE(1),
    .KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .ID_ENABLE(1),
    .ID_WIDTH(AXIS_IF_RX_ID_WIDTH),
    .DEST_ENABLE(1),
    .DEST_WIDTH(AXIS_IF_RX_DEST_WIDTH),
    .USER_ENABLE(1),
    .USER_WIDTH(AXIS_IF_RX_USER_WIDTH),
    .FRAME_FIFO(1),
    .DROP_WHEN_FULL(1)
) i_fifo_rx (
    .clk             (clk),
    .rst             (!rstn),

    .s_axis_tdata    (s_axis_pspin_rx_tdata),
    .s_axis_tkeep    (s_axis_pspin_rx_tkeep),
    .s_axis_tvalid   (s_axis_pspin_rx_tvalid),
    .s_axis_tready   (s_axis_pspin_rx_tready),
    .s_axis_tlast    (s_axis_pspin_rx_tlast),
    .s_axis_tid      (s_axis_pspin_rx_tid),
    .s_axis_tdest    (s_axis_pspin_rx_tdest),
    .s_axis_tuser    (s_axis_pspin_rx_tuser),

    .m_axis_tdata    (s_axis_buffered_tdata),
    .m_axis_tkeep    (s_axis_buffered_tkeep),
    .m_axis_tvalid   (s_axis_buffered_tvalid),
    .m_axis_tready   (s_axis_buffered_tready),
    .m_axis_tlast    (s_axis_buffered_tlast),
    .m_axis_tid      (s_axis_buffered_tid),
    .m_axis_tdest    (s_axis_buffered_tdest),
    .m_axis_tuser    (s_axis_buffered_tuser),

    .status_overflow    (buffered_overflow),
    .status_bad_frame   (buffered_bad_frame),
    .status_good_frame  (buffered_good_frame)
);

axi_dma_wr #(
    .AXI_DATA_WIDTH,
    .AXI_ADDR_WIDTH,
    .AXI_STRB_WIDTH,
    .AXI_ID_WIDTH,
    .AXIS_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_ID_ENABLE(1),
    .AXIS_ID_WIDTH(AXIS_IF_RX_ID_WIDTH),
    .AXIS_DEST_ENABLE(1),
    .AXIS_DEST_WIDTH(AXIS_IF_RX_DEST_WIDTH),
    .AXIS_USER_ENABLE(1),
    .AXIS_USER_WIDTH(AXIS_IF_RX_USER_WIDTH)
    .LEN_WIDTH,
    .TAG_WIDTH(DMA_TAG_WIDTH)
) i_ingress_dma (
    .clk,
    .rst                                        (!rstn),

    .s_axis_write_desc_addr                     (write_desc_addr ),
    .s_axis_write_desc_len                      (write_desc_len  ),
    .s_axis_write_desc_tag                      ({write_desc_tag, write_desc_addr}),
    .s_axis_write_desc_valid                    (write_desc_valid),
    .s_axis_write_desc_ready                    (write_desc_ready),

    .m_axis_write_desc_status_len               (desc_status_len  ),
    .m_axis_write_desc_status_tag               ({desc_status_tag, desc_status_addr}),
    .m_axis_write_desc_status_id                (desc_status_id   ),
    .m_axis_write_desc_status_dest              (desc_status_dest ),
    .m_axis_write_desc_status_user              (desc_status_user ),
    .m_axis_write_desc_status_error             (desc_status_error),
    .m_axis_write_desc_status_valid             (desc_status_valid),

    .s_axis_write_data_tdata                    (s_axis_buffered_tdata ),
    .s_axis_write_data_tkeep                    (s_axis_buffered_tkeep ),
    .s_axis_write_data_tvalid                   (s_axis_buffered_tvalid),
    .s_axis_write_data_tready                   (s_axis_buffered_tready),
    .s_axis_write_data_tlast                    (s_axis_buffered_tlast ),
    .s_axis_write_data_tid                      (s_axis_buffered_tid   ),
    .s_axis_write_data_tdest                    (s_axis_buffered_tdest ),
    .s_axis_write_data_tuser                    (s_axis_buffered_tuser ),

    .m_axi_awid                                 (m_axi_pspin_awid    ),
    .m_axi_awaddr                               (m_axi_pspin_awaddr  ),
    .m_axi_awlen                                (m_axi_pspin_awlen   ),
    .m_axi_awsize                               (m_axi_pspin_awsize  ),
    .m_axi_awburst                              (m_axi_pspin_awburst ),
    .m_axi_awlock                               (m_axi_pspin_awlock  ),
    .m_axi_awcache                              (m_axi_pspin_awcache ),
    .m_axi_awprot                               (m_axi_pspin_awprot  ),
    .m_axi_awvalid                              (m_axi_pspin_awvalid ),
    .m_axi_awready                              (m_axi_pspin_awready ),
    .m_axi_wdata                                (m_axi_pspin_wdata   ),
    .m_axi_wstrb                                (m_axi_pspin_wstrb   ),
    .m_axi_wlast                                (m_axi_pspin_wlast   ),
    .m_axi_wvalid                               (m_axi_pspin_wvalid  ),
    .m_axi_wready                               (m_axi_pspin_wready  ),
    .m_axi_bid                                  (m_axi_pspin_bid     ),
    .m_axi_bresp                                (m_axi_pspin_bresp   ),
    .m_axi_bvalid                               (m_axi_pspin_bvalid  ),
    .m_axi_bready                               (m_axi_pspin_bready  ),

    .enable                                     (1'b1),
    .abort                                      (1'b0)
);

endmodule