/**
 * PsPIN Ingress Datapath
 *
 * Assembled ingress datapath, taking AXI stream data from Corundum and
 * configuration from ctrl_regs and giving out one AXI master interface
 * towards PsPIN.
 */

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

module pspin_ingress_datapath #(
    parameter UMATCH_WIDTH = 32,
    parameter UMATCH_ENTRIES = 4,
    parameter UMATCH_MODES = 2,

    parameter UMATCH_MATCHER_LEN = 66,
    parameter UMATCH_MTU = 1500,
    parameter UMATCH_BUF_FRAMES = 3,
 
    parameter NUM_HANDLER_CTX = 4,

    parameter AXIS_IF_DATA_WIDTH = 512,
    parameter AXIS_IF_KEEP_WIDTH = AXIS_IF_DATA_WIDTH/8,
    parameter AXIS_IF_RX_ID_WIDTH = 1,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_RX_USER_WIDTH = 16,

    parameter AXI_HOST_ADDR_WIDTH = 64, // pspin_cfg_pkg::HOST_AXI_AW
    parameter AXI_DATA_WIDTH = 512, // pspin_cfg_pkg::data_t
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_STRB_WIDTH = (AXI_DATA_WIDTH/8),
    parameter AXI_ID_WIDTH = 8,

    parameter LEN_WIDTH = 32,
    parameter TAG_WIDTH = 32,
    parameter MSG_ID_WIDTH = 10,

    parameter [AXI_ADDR_WIDTH-1:0] BUF_START = 32'h1c100000, // 1c000000 + MEM_HND_SIZE
    parameter [AXI_ADDR_WIDTH-1:0] BUF_SIZE = 512*1024 // match with pspin_cfg_pkg.sv:MEM_PKT_SIZE
) (
    input wire                                             clk,
    input wire                                             rstn,

    // matching engine configuration
    input wire [$clog2(UMATCH_MODES)*NUM_HANDLER_CTX-1:0]         match_mode,
    input wire [UMATCH_WIDTH*UMATCH_ENTRIES*NUM_HANDLER_CTX-1:0]  match_idx,
    input wire [UMATCH_WIDTH*UMATCH_ENTRIES*NUM_HANDLER_CTX-1:0]  match_mask,
    input wire [UMATCH_WIDTH*UMATCH_ENTRIES*NUM_HANDLER_CTX-1:0]  match_start,
    input wire [UMATCH_WIDTH*UMATCH_ENTRIES*NUM_HANDLER_CTX-1:0]  match_end,
    input wire                                                    match_valid,

    // HER generator execution context
`define INPUT_HER_CFG(name, width) input wire [NUM_HANDLER_CTX*(width)-1:0] her_gen_``name,
`HER_META(INPUT_HER_CFG)
    input wire [NUM_HANDLER_CTX-1:0]                   her_gen_enabled,
    input wire                                             her_gen_valid,

    // from NIC
    (* mark_debug = "true" *) input  wire [AXIS_IF_DATA_WIDTH-1:0]                   s_axis_nic_rx_tdata,
    (* mark_debug = "true" *) input  wire [AXIS_IF_KEEP_WIDTH-1:0]                   s_axis_nic_rx_tkeep,
    (* mark_debug = "true" *) input  wire                                            s_axis_nic_rx_tvalid,
    (* mark_debug = "true" *) output wire                                            s_axis_nic_rx_tready,
    (* mark_debug = "true" *) input  wire                                            s_axis_nic_rx_tlast,
    (* mark_debug = "true" *) input  wire [AXIS_IF_RX_ID_WIDTH-1:0]                  s_axis_nic_rx_tid,
    (* mark_debug = "true" *) input  wire [AXIS_IF_RX_DEST_WIDTH-1:0]                s_axis_nic_rx_tdest,
    (* mark_debug = "true" *) input  wire [AXIS_IF_RX_USER_WIDTH-1:0]                s_axis_nic_rx_tuser,

    // to NIC - unmatched
    (* mark_debug = "true" *) output wire [AXIS_IF_DATA_WIDTH-1:0]                   m_axis_nic_rx_tdata,
    (* mark_debug = "true" *) output wire [AXIS_IF_KEEP_WIDTH-1:0]                   m_axis_nic_rx_tkeep,
    (* mark_debug = "true" *) output wire                                            m_axis_nic_rx_tvalid,
    (* mark_debug = "true" *) input  wire                                            m_axis_nic_rx_tready,
    (* mark_debug = "true" *) output wire                                            m_axis_nic_rx_tlast,
    (* mark_debug = "true" *) output wire [AXIS_IF_RX_ID_WIDTH-1:0]                  m_axis_nic_rx_tid,
    (* mark_debug = "true" *) output wire [AXIS_IF_RX_DEST_WIDTH-1:0]                m_axis_nic_rx_tdest,
    (* mark_debug = "true" *) output wire [AXIS_IF_RX_USER_WIDTH-1:0]                m_axis_nic_rx_tuser,

    // to PsPIN NIC Inbound
    (* mark_debug = "true" *) output wire [AXI_ID_WIDTH-1:0]                         m_axi_pspin_ni_awid,
    (* mark_debug = "true" *) output wire [AXI_ADDR_WIDTH-1:0]                       m_axi_pspin_ni_awaddr,
    (* mark_debug = "true" *) output wire [7:0]                                      m_axi_pspin_ni_awlen,
    (* mark_debug = "true" *) output wire [2:0]                                      m_axi_pspin_ni_awsize,
    (* mark_debug = "true" *) output wire [1:0]                                      m_axi_pspin_ni_awburst,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_awlock,
    (* mark_debug = "true" *) output wire [3:0]                                      m_axi_pspin_ni_awcache,
    (* mark_debug = "true" *) output wire [2:0]                                      m_axi_pspin_ni_awprot,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_awvalid,
    (* mark_debug = "true" *) input  wire                                            m_axi_pspin_ni_awready,
    (* mark_debug = "true" *) output wire [AXI_DATA_WIDTH-1:0]                       m_axi_pspin_ni_wdata,
    (* mark_debug = "true" *) output wire [AXI_STRB_WIDTH-1:0]                       m_axi_pspin_ni_wstrb,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_wlast,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_wvalid,
    (* mark_debug = "true" *) input  wire                                            m_axi_pspin_ni_wready,
    (* mark_debug = "true" *) input  wire [AXI_ID_WIDTH-1:0]                         m_axi_pspin_ni_bid,
    (* mark_debug = "true" *) input  wire [1:0]                                      m_axi_pspin_ni_bresp,
    (* mark_debug = "true" *) input  wire                                            m_axi_pspin_ni_bvalid,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_bready,
    (* mark_debug = "true" *) output wire [AXI_ID_WIDTH-1:0]                         m_axi_pspin_ni_arid,
    (* mark_debug = "true" *) output wire [AXI_ADDR_WIDTH-1:0]                       m_axi_pspin_ni_araddr,
    (* mark_debug = "true" *) output wire [7:0]                                      m_axi_pspin_ni_arlen,
    (* mark_debug = "true" *) output wire [2:0]                                      m_axi_pspin_ni_arsize,
    (* mark_debug = "true" *) output wire [1:0]                                      m_axi_pspin_ni_arburst,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_arlock,
    (* mark_debug = "true" *) output wire [3:0]                                      m_axi_pspin_ni_arcache,
    (* mark_debug = "true" *) output wire [2:0]                                      m_axi_pspin_ni_arprot,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_arvalid,
    (* mark_debug = "true" *) input  wire                                            m_axi_pspin_ni_arready,
    (* mark_debug = "true" *) input  wire [AXI_ID_WIDTH-1:0]                         m_axi_pspin_ni_rid,
    (* mark_debug = "true" *) input  wire [AXI_DATA_WIDTH-1:0]                       m_axi_pspin_ni_rdata,
    (* mark_debug = "true" *) input  wire [1:0]                                      m_axi_pspin_ni_rresp,
    (* mark_debug = "true" *) input  wire                                            m_axi_pspin_ni_rlast,
    (* mark_debug = "true" *) input  wire                                            m_axi_pspin_ni_rvalid,
    (* mark_debug = "true" *) output wire                                            m_axi_pspin_ni_rready,

    // HER to PsPIN wrapper
    (* mark_debug = "true" *) input  wire                                            her_ready,
    (* mark_debug = "true" *) output wire                                            her_valid,
    (* mark_debug = "true" *) output wire [MSG_ID_WIDTH-1:0]                         her_msgid,
    (* mark_debug = "true" *) output wire                                            her_is_eom,
    (* mark_debug = "true" *) output wire [AXI_ADDR_WIDTH-1:0]                       her_addr,
    (* mark_debug = "true" *) output wire [AXI_ADDR_WIDTH-1:0]                       her_size,
    (* mark_debug = "true" *) output wire [AXI_ADDR_WIDTH-1:0]                       her_xfer_size,
`define OUTPUT_HER(name, width) output wire [(width)-1:0] her_meta_``name,
`HER_META(OUTPUT_HER)

    // from PsPIN
    (* mark_debug = "true" *) output wire                                            feedback_ready,
    (* mark_debug = "true" *) input  wire                                            feedback_valid,
    (* mark_debug = "true" *) input  wire [AXI_ADDR_WIDTH-1:0]                       feedback_her_addr,
    (* mark_debug = "true" *) input  wire [LEN_WIDTH-1:0]                            feedback_her_size,
    (* mark_debug = "true" *) input  wire [MSG_ID_WIDTH-1:0]                         feedback_msgid,

    // alloc stats
    output wire [31:0]                                     alloc_dropped_pkts
);

wire [AXIS_IF_DATA_WIDTH-1:0]         m_axis_pspin_rx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]         m_axis_pspin_rx_tkeep;
wire                                  m_axis_pspin_rx_tvalid;
wire                                  m_axis_pspin_rx_tready;
wire                                  m_axis_pspin_rx_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]        m_axis_pspin_rx_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]      m_axis_pspin_rx_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]      m_axis_pspin_rx_tuser;

wire [TAG_WIDTH-1:0]                  packet_meta_tag;
wire [LEN_WIDTH-1:0]                  packet_meta_size;
wire                                  packet_meta_valid;
wire                                  packet_meta_ready;

wire [AXI_ADDR_WIDTH-1:0]             write_addr;
wire [LEN_WIDTH-1:0]                  write_len;
wire [TAG_WIDTH-1:0]                  write_tag;
wire                                  write_valid;
wire                                  write_ready;

wire [AXI_ADDR_WIDTH-1:0]             to_her_gen_addr;
wire [LEN_WIDTH-1:0]                  to_her_gen_len;
wire [TAG_WIDTH-1:0]                  to_her_gen_tag;
wire                                  to_her_gen_valid;
wire                                  to_her_gen_ready;

pspin_pkt_match #(
    .UMATCH_WIDTH(UMATCH_WIDTH),
    .UMATCH_ENTRIES(UMATCH_ENTRIES),
    .UMATCH_MODES(UMATCH_MODES),
    .UMATCH_RULESETS(NUM_HANDLER_CTX),
    
    .UMATCH_MATCHER_LEN(UMATCH_MATCHER_LEN),
    .UMATCH_MTU(UMATCH_MTU),
    .UMATCH_BUF_FRAMES(UMATCH_BUF_FRAMES),

    .AXIS_IF_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_IF_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_IF_RX_ID_WIDTH(AXIS_IF_RX_ID_WIDTH),
    .AXIS_IF_RX_DEST_WIDTH(AXIS_IF_RX_DEST_WIDTH),
    .AXIS_IF_RX_USER_WIDTH(AXIS_IF_RX_USER_WIDTH),
    
    .TAG_WIDTH(TAG_WIDTH),
    .MSG_ID_WIDTH(MSG_ID_WIDTH)
) i_me (
    .clk,
    .rstn,

    .s_axis_nic_rx_tdata,
    .s_axis_nic_rx_tkeep,
    .s_axis_nic_rx_tvalid,
    .s_axis_nic_rx_tready,
    .s_axis_nic_rx_tlast,
    .s_axis_nic_rx_tid,
    .s_axis_nic_rx_tdest,
    .s_axis_nic_rx_tuser,

    .m_axis_nic_rx_tdata,
    .m_axis_nic_rx_tkeep,
    .m_axis_nic_rx_tvalid,
    .m_axis_nic_rx_tready,
    .m_axis_nic_rx_tlast,
    .m_axis_nic_rx_tid,
    .m_axis_nic_rx_tdest,
    .m_axis_nic_rx_tuser,

    .m_axis_pspin_rx_tdata,
    .m_axis_pspin_rx_tkeep,
    .m_axis_pspin_rx_tvalid,
    .m_axis_pspin_rx_tready,
    .m_axis_pspin_rx_tlast,
    .m_axis_pspin_rx_tid,
    .m_axis_pspin_rx_tdest,
    .m_axis_pspin_rx_tuser,

    .match_mode,
    .match_idx,
    .match_mask,
    .match_start,
    .match_end,
    .match_valid,

    .packet_meta_tag,
    .packet_meta_size,
    .packet_meta_valid,
    .packet_meta_ready
);

pspin_pkt_alloc #(
    .LEN_WIDTH(LEN_WIDTH),
    .TAG_WIDTH(TAG_WIDTH),
    .ADDR_WIDTH(AXI_ADDR_WIDTH),
    .MSGID_WIDTH(MSG_ID_WIDTH),
    .SLOT0_COUNT(256),
    .SLOT1_SIZE(128),
    .SLOT1_COUNT(1024),
    .BUF_START(BUF_START),
    .BUF_SIZE(BUF_SIZE)
) i_alloc (
    .clk,
    .rstn,

    .pkt_tag_i                              (packet_meta_tag),
    .pkt_len_i                              (packet_meta_size),
    .pkt_valid_i                            (packet_meta_valid),
    .pkt_ready_o                            (packet_meta_ready),

    .feedback_ready_o                       (feedback_ready),
    .feedback_valid_i                       (feedback_valid),
    .feedback_her_addr_i                    (feedback_her_addr),
    .feedback_her_size_i                    (feedback_her_size),
    .feedback_msgid_i                       (feedback_msgid),

    .write_addr_o                           (write_addr),
    .write_len_o                            (write_len),
    .write_tag_o                            (write_tag),
    .write_valid_o                          (write_valid),
    .write_ready_i                          (write_ready),

    .dropped_pkts_o                         (alloc_dropped_pkts)
);

pspin_ingress_dma #(
    .AXIS_IF_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_IF_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_IF_RX_ID_WIDTH(AXIS_IF_RX_ID_WIDTH),
    .AXIS_IF_RX_DEST_WIDTH(AXIS_IF_RX_DEST_WIDTH),
    .AXIS_IF_RX_USER_WIDTH(AXIS_IF_RX_USER_WIDTH),

    .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
    .AXI_ID_WIDTH(AXI_ID_WIDTH),

    .LEN_WIDTH(LEN_WIDTH),
    .TAG_WIDTH(TAG_WIDTH),
    
    .INGRESS_DMA_MTU(UMATCH_MTU)
) i_ig_dma (
    .clk,
    .rstn,

    .write_desc_addr                           (write_addr),
    .write_desc_len                            (write_len),
    .write_desc_tag                            (write_tag),
    .write_desc_valid                          (write_valid),
    .write_desc_ready                          (write_ready),

    .s_axis_pspin_rx_tdata                     (m_axis_pspin_rx_tdata),
    .s_axis_pspin_rx_tkeep                     (m_axis_pspin_rx_tkeep),
    .s_axis_pspin_rx_tvalid                    (m_axis_pspin_rx_tvalid),
    .s_axis_pspin_rx_tready                    (m_axis_pspin_rx_tready),
    .s_axis_pspin_rx_tlast                     (m_axis_pspin_rx_tlast),
    .s_axis_pspin_rx_tid                       (m_axis_pspin_rx_tid),
    .s_axis_pspin_rx_tdest                     (m_axis_pspin_rx_tdest),
    .s_axis_pspin_rx_tuser                     (m_axis_pspin_rx_tuser),

    .m_axi_pspin_awid(m_axi_pspin_ni_awid),
    .m_axi_pspin_awaddr(m_axi_pspin_ni_awaddr),
    .m_axi_pspin_awlen(m_axi_pspin_ni_awlen),
    .m_axi_pspin_awsize(m_axi_pspin_ni_awsize),
    .m_axi_pspin_awburst(m_axi_pspin_ni_awburst),
    .m_axi_pspin_awlock(m_axi_pspin_ni_awlock),
    .m_axi_pspin_awcache(m_axi_pspin_ni_awcache),
    .m_axi_pspin_awprot(m_axi_pspin_ni_awprot),
    .m_axi_pspin_awvalid(m_axi_pspin_ni_awvalid),
    .m_axi_pspin_awready(m_axi_pspin_ni_awready),
    .m_axi_pspin_wdata(m_axi_pspin_ni_wdata),
    .m_axi_pspin_wstrb(m_axi_pspin_ni_wstrb),
    .m_axi_pspin_wlast(m_axi_pspin_ni_wlast),
    .m_axi_pspin_wvalid(m_axi_pspin_ni_wvalid),
    .m_axi_pspin_wready(m_axi_pspin_ni_wready),
    .m_axi_pspin_bid(m_axi_pspin_ni_bid),
    .m_axi_pspin_bresp(m_axi_pspin_ni_bresp),
    .m_axi_pspin_bvalid(m_axi_pspin_ni_bvalid),
    .m_axi_pspin_bready(m_axi_pspin_ni_bready),
    .m_axi_pspin_arid(m_axi_pspin_ni_arid),
    .m_axi_pspin_araddr(m_axi_pspin_ni_araddr),
    .m_axi_pspin_arlen(m_axi_pspin_ni_arlen),
    .m_axi_pspin_arsize(m_axi_pspin_ni_arsize),
    .m_axi_pspin_arburst(m_axi_pspin_ni_arburst),
    .m_axi_pspin_arlock(m_axi_pspin_ni_arlock),
    .m_axi_pspin_arcache(m_axi_pspin_ni_arcache),
    .m_axi_pspin_arprot(m_axi_pspin_ni_arprot),
    .m_axi_pspin_arvalid(m_axi_pspin_ni_arvalid),
    .m_axi_pspin_arready(m_axi_pspin_ni_arready),
    .m_axi_pspin_rid(m_axi_pspin_ni_rid),
    .m_axi_pspin_rdata(m_axi_pspin_ni_rdata),
    .m_axi_pspin_rresp(m_axi_pspin_ni_rresp),
    .m_axi_pspin_rlast(m_axi_pspin_ni_rlast),
    .m_axi_pspin_rvalid(m_axi_pspin_ni_rvalid),
    .m_axi_pspin_rready(m_axi_pspin_ni_rready),

    .her_gen_addr                              (to_her_gen_addr),
    .her_gen_len                               (to_her_gen_len),
    .her_gen_tag                               (to_her_gen_tag),
    .her_gen_valid                             (to_her_gen_valid),
    .her_gen_ready                             (to_her_gen_ready)
);

pspin_her_gen #(
    .C_MSGID_WIDTH(MSG_ID_WIDTH),
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .AXI_HOST_ADDR_WIDTH(AXI_HOST_ADDR_WIDTH),
    .LEN_WIDTH(LEN_WIDTH),
    .TAG_WIDTH(TAG_WIDTH),
    .NUM_HANDLER_CTX(NUM_HANDLER_CTX)
) i_her_gen (
    .clk,
    .rstn,

    .her_ready,
    .her_valid,
    .her_msgid,
    .her_is_eom,
    .her_addr,
    .her_size,
    .her_xfer_size,
`define HER_INST(name, width) .her_meta_``name,
`HER_META(HER_INST)

    .gen_addr                   (to_her_gen_addr),
    .gen_len                    (to_her_gen_len),
    .gen_tag                    (to_her_gen_tag),
    .gen_valid                  (to_her_gen_valid),
    .gen_ready                  (to_her_gen_ready),

`define HER_CTRL_INST(name, width) .conf_``name(her_gen_``name),
`HER_META(HER_CTRL_INST)
    .conf_ctx_enabled           (her_gen_enabled),
    .conf_valid                 (her_gen_valid)
);

endmodule