/*

Copyright 2021, The Regents of the University of California.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

   1. Redistributions of source code must retain the above copyright notice,
      this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above copyright notice,
      this list of conditions and the following disclaimer in the documentation
      and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE REGENTS OF THE UNIVERSITY OF CALIFORNIA ''AS
IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE REGENTS OF THE UNIVERSITY OF CALIFORNIA OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.

The views and conclusions contained in the software and documentation are those
of the authors and should not be interpreted as representing official policies,
either expressed or implied, of The Regents of the University of California.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Application block
 */
module mqnic_app_block #
(
    // Structural configuration
    parameter IF_COUNT = 1,
    parameter PORTS_PER_IF = 1,
    parameter SCHED_PER_IF = PORTS_PER_IF,

    parameter PORT_COUNT = IF_COUNT*PORTS_PER_IF,

    // PTP configuration
    parameter PTP_CLK_PERIOD_NS_NUM = 4,
    parameter PTP_CLK_PERIOD_NS_DENOM = 1,
    parameter PTP_TS_WIDTH = 96,
    parameter PTP_USE_SAMPLE_CLOCK = 0,
    parameter PTP_PORT_CDC_PIPELINE = 0,
    parameter PTP_PEROUT_ENABLE = 0,
    parameter PTP_PEROUT_COUNT = 1,

    // Interface configuration
    parameter PTP_TS_ENABLE = 1,
    parameter TX_TAG_WIDTH = 16,
    parameter MAX_TX_SIZE = 9214,
    parameter MAX_RX_SIZE = 9214,

    // Application configuration
    parameter APP_ID = 32'h12340100,
    parameter APP_CTRL_ENABLE = 1,
    parameter APP_DMA_ENABLE = 1,
    parameter APP_AXIS_DIRECT_ENABLE = 0,
    parameter APP_AXIS_SYNC_ENABLE = 0,
    parameter APP_AXIS_IF_ENABLE = 1,
    parameter APP_STAT_ENABLE = 1,
    parameter APP_GPIO_IN_WIDTH = 32,
    parameter APP_GPIO_OUT_WIDTH = 32,

    // DMA interface configuration
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,
    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    // AXI lite interface (application control from host)
    parameter AXIL_APP_CTRL_DATA_WIDTH = 32,
    parameter AXIL_APP_CTRL_ADDR_WIDTH = 16,
    parameter AXIL_APP_CTRL_STRB_WIDTH = (AXIL_APP_CTRL_DATA_WIDTH/8),

    // AXI lite interface (control to NIC)
    parameter AXIL_CTRL_DATA_WIDTH = 32,
    parameter AXIL_CTRL_ADDR_WIDTH = 16,
    parameter AXIL_CTRL_STRB_WIDTH = (AXIL_CTRL_DATA_WIDTH/8),

    // Ethernet interface configuration (direct, async)
    parameter AXIS_DATA_WIDTH = 512,
    parameter AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    parameter AXIS_TX_USER_WIDTH = TX_TAG_WIDTH + 1,
    parameter AXIS_RX_USER_WIDTH = (PTP_TS_ENABLE ? PTP_TS_WIDTH : 0) + 1,
    parameter AXIS_RX_USE_READY = 0,

    // Ethernet interface configuration (direct, sync)
    parameter AXIS_SYNC_DATA_WIDTH = AXIS_DATA_WIDTH,
    parameter AXIS_SYNC_KEEP_WIDTH = AXIS_SYNC_DATA_WIDTH/8,
    parameter AXIS_SYNC_TX_USER_WIDTH = AXIS_TX_USER_WIDTH,
    parameter AXIS_SYNC_RX_USER_WIDTH = AXIS_RX_USER_WIDTH,

    // Ethernet interface configuration (interface)
    parameter AXIS_IF_DATA_WIDTH = AXIS_SYNC_DATA_WIDTH*2**$clog2(PORTS_PER_IF),
    parameter AXIS_IF_KEEP_WIDTH = AXIS_IF_DATA_WIDTH/8,
    parameter AXIS_IF_TX_ID_WIDTH = 12,
    parameter AXIS_IF_RX_ID_WIDTH = PORTS_PER_IF > 1 ? $clog2(PORTS_PER_IF) : 1,
    parameter AXIS_IF_TX_DEST_WIDTH = $clog2(PORTS_PER_IF)+4,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_TX_USER_WIDTH = AXIS_SYNC_TX_USER_WIDTH,
    parameter AXIS_IF_RX_USER_WIDTH = AXIS_SYNC_RX_USER_WIDTH,

    // Statistics counter subsystem
    parameter STAT_ENABLE = 1,
    parameter STAT_INC_WIDTH = 24,
    parameter STAT_ID_WIDTH = 12
)
(
    input  wire                                           clk,
    input  wire                                           rst,

    /*
     * AXI-Lite slave interface (control from host)
     */
    input  wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]            s_axil_app_ctrl_awaddr,
    input  wire [2:0]                                     s_axil_app_ctrl_awprot,
    input  wire                                           s_axil_app_ctrl_awvalid,
    output wire                                           s_axil_app_ctrl_awready,
    input  wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]            s_axil_app_ctrl_wdata,
    input  wire [AXIL_APP_CTRL_STRB_WIDTH-1:0]            s_axil_app_ctrl_wstrb,
    input  wire                                           s_axil_app_ctrl_wvalid,
    output wire                                           s_axil_app_ctrl_wready,
    output wire [1:0]                                     s_axil_app_ctrl_bresp,
    output wire                                           s_axil_app_ctrl_bvalid,
    input  wire                                           s_axil_app_ctrl_bready,
    input  wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]            s_axil_app_ctrl_araddr,
    input  wire [2:0]                                     s_axil_app_ctrl_arprot,
    input  wire                                           s_axil_app_ctrl_arvalid,
    output wire                                           s_axil_app_ctrl_arready,
    output wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]            s_axil_app_ctrl_rdata,
    output wire [1:0]                                     s_axil_app_ctrl_rresp,
    output wire                                           s_axil_app_ctrl_rvalid,
    input  wire                                           s_axil_app_ctrl_rready,

    /*
     * AXI-Lite master interface (control to NIC)
     */
    output wire [AXIL_CTRL_ADDR_WIDTH-1:0]                m_axil_ctrl_awaddr,
    output wire [2:0]                                     m_axil_ctrl_awprot,
    output wire                                           m_axil_ctrl_awvalid,
    input  wire                                           m_axil_ctrl_awready,
    output wire [AXIL_CTRL_DATA_WIDTH-1:0]                m_axil_ctrl_wdata,
    output wire [AXIL_CTRL_STRB_WIDTH-1:0]                m_axil_ctrl_wstrb,
    output wire                                           m_axil_ctrl_wvalid,
    input  wire                                           m_axil_ctrl_wready,
    input  wire [1:0]                                     m_axil_ctrl_bresp,
    input  wire                                           m_axil_ctrl_bvalid,
    output wire                                           m_axil_ctrl_bready,
    output wire [AXIL_CTRL_ADDR_WIDTH-1:0]                m_axil_ctrl_araddr,
    output wire [2:0]                                     m_axil_ctrl_arprot,
    output wire                                           m_axil_ctrl_arvalid,
    input  wire                                           m_axil_ctrl_arready,
    input  wire [AXIL_CTRL_DATA_WIDTH-1:0]                m_axil_ctrl_rdata,
    input  wire [1:0]                                     m_axil_ctrl_rresp,
    input  wire                                           m_axil_ctrl_rvalid,
    output wire                                           m_axil_ctrl_rready,

    /*
     * DMA read descriptor output (control)
     */
    output wire [DMA_ADDR_WIDTH-1:0]                      m_axis_ctrl_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                       m_axis_ctrl_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                      m_axis_ctrl_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                       m_axis_ctrl_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                       m_axis_ctrl_dma_read_desc_tag,
    output wire                                           m_axis_ctrl_dma_read_desc_valid,
    input  wire                                           m_axis_ctrl_dma_read_desc_ready,

    /*
     * DMA read descriptor status input (control)
     */
    input  wire [DMA_TAG_WIDTH-1:0]                       s_axis_ctrl_dma_read_desc_status_tag,
    input  wire [3:0]                                     s_axis_ctrl_dma_read_desc_status_error,
    input  wire                                           s_axis_ctrl_dma_read_desc_status_valid,

    /*
     * DMA write descriptor output (control)
     */
    output wire [DMA_ADDR_WIDTH-1:0]                      m_axis_ctrl_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                       m_axis_ctrl_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                      m_axis_ctrl_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                       m_axis_ctrl_dma_write_desc_imm,
    output wire                                           m_axis_ctrl_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                       m_axis_ctrl_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                       m_axis_ctrl_dma_write_desc_tag,
    output wire                                           m_axis_ctrl_dma_write_desc_valid,
    input  wire                                           m_axis_ctrl_dma_write_desc_ready,

    /*
     * DMA write descriptor status input (control)
     */
    input  wire [DMA_TAG_WIDTH-1:0]                       s_axis_ctrl_dma_write_desc_status_tag,
    input  wire [3:0]                                     s_axis_ctrl_dma_write_desc_status_error,
    input  wire                                           s_axis_ctrl_dma_write_desc_status_valid,

    /*
     * DMA read descriptor output (data)
     */
    output wire [DMA_ADDR_WIDTH-1:0]                      m_axis_data_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                       m_axis_data_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                      m_axis_data_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                       m_axis_data_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                       m_axis_data_dma_read_desc_tag,
    output wire                                           m_axis_data_dma_read_desc_valid,
    input  wire                                           m_axis_data_dma_read_desc_ready,

    /*
     * DMA read descriptor status input (data)
     */
    input  wire [DMA_TAG_WIDTH-1:0]                       s_axis_data_dma_read_desc_status_tag,
    input  wire [3:0]                                     s_axis_data_dma_read_desc_status_error,
    input  wire                                           s_axis_data_dma_read_desc_status_valid,

    /*
     * DMA write descriptor output (data)
     */
    output wire [DMA_ADDR_WIDTH-1:0]                      m_axis_data_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                       m_axis_data_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                      m_axis_data_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                       m_axis_data_dma_write_desc_imm,
    output wire                                           m_axis_data_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                       m_axis_data_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                       m_axis_data_dma_write_desc_tag,
    output wire                                           m_axis_data_dma_write_desc_valid,
    input  wire                                           m_axis_data_dma_write_desc_ready,

    /*
     * DMA write descriptor status input (data)
     */
    input  wire [DMA_TAG_WIDTH-1:0]                       s_axis_data_dma_write_desc_status_tag,
    input  wire [3:0]                                     s_axis_data_dma_write_desc_status_error,
    input  wire                                           s_axis_data_dma_write_desc_status_valid,

    /*
     * DMA RAM interface (control)
     */
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]         ctrl_dma_ram_wr_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]      ctrl_dma_ram_wr_cmd_be,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]    ctrl_dma_ram_wr_cmd_addr,
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]    ctrl_dma_ram_wr_cmd_data,
    input  wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_wr_done,
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]         ctrl_dma_ram_rd_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]    ctrl_dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]    ctrl_dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                       ctrl_dma_ram_rd_resp_ready,

    /*
     * DMA RAM interface (data)
     */
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]         data_dma_ram_wr_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]      data_dma_ram_wr_cmd_be,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]    data_dma_ram_wr_cmd_addr,
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]    data_dma_ram_wr_cmd_data,
    input  wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_wr_done,
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]         data_dma_ram_rd_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]    data_dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]    data_dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                       data_dma_ram_rd_resp_ready,

    /*
     * PTP clock
     */
    input  wire                                           ptp_clk,
    input  wire                                           ptp_rst,
    input  wire                                           ptp_sample_clk,
    input  wire                                           ptp_pps,
    input  wire [PTP_TS_WIDTH-1:0]                        ptp_ts_96,
    input  wire                                           ptp_ts_step,
    input  wire                                           ptp_sync_pps,
    input  wire [PTP_TS_WIDTH-1:0]                        ptp_sync_ts_96,
    input  wire                                           ptp_sync_ts_step,
    input  wire [PTP_PEROUT_COUNT-1:0]                    ptp_perout_locked,
    input  wire [PTP_PEROUT_COUNT-1:0]                    ptp_perout_error,
    input  wire [PTP_PEROUT_COUNT-1:0]                    ptp_perout_pulse,

    /*
     * Ethernet (direct MAC interface - lowest latency raw traffic)
     */
    input  wire [PORT_COUNT-1:0]                          direct_tx_clk,
    input  wire [PORT_COUNT-1:0]                          direct_tx_rst,

    input  wire [PORT_COUNT*AXIS_DATA_WIDTH-1:0]          s_axis_direct_tx_tdata,
    input  wire [PORT_COUNT*AXIS_KEEP_WIDTH-1:0]          s_axis_direct_tx_tkeep,
    input  wire [PORT_COUNT-1:0]                          s_axis_direct_tx_tvalid,
    output wire [PORT_COUNT-1:0]                          s_axis_direct_tx_tready,
    input  wire [PORT_COUNT-1:0]                          s_axis_direct_tx_tlast,
    input  wire [PORT_COUNT*AXIS_TX_USER_WIDTH-1:0]       s_axis_direct_tx_tuser,

    output wire [PORT_COUNT*AXIS_DATA_WIDTH-1:0]          m_axis_direct_tx_tdata,
    output wire [PORT_COUNT*AXIS_KEEP_WIDTH-1:0]          m_axis_direct_tx_tkeep,
    output wire [PORT_COUNT-1:0]                          m_axis_direct_tx_tvalid,
    input  wire [PORT_COUNT-1:0]                          m_axis_direct_tx_tready,
    output wire [PORT_COUNT-1:0]                          m_axis_direct_tx_tlast,
    output wire [PORT_COUNT*AXIS_TX_USER_WIDTH-1:0]       m_axis_direct_tx_tuser,

    input  wire [PORT_COUNT*PTP_TS_WIDTH-1:0]             s_axis_direct_tx_cpl_ts,
    input  wire [PORT_COUNT*TX_TAG_WIDTH-1:0]             s_axis_direct_tx_cpl_tag,
    input  wire [PORT_COUNT-1:0]                          s_axis_direct_tx_cpl_valid,
    output wire [PORT_COUNT-1:0]                          s_axis_direct_tx_cpl_ready,

    output wire [PORT_COUNT*PTP_TS_WIDTH-1:0]             m_axis_direct_tx_cpl_ts,
    output wire [PORT_COUNT*TX_TAG_WIDTH-1:0]             m_axis_direct_tx_cpl_tag,
    output wire [PORT_COUNT-1:0]                          m_axis_direct_tx_cpl_valid,
    input  wire [PORT_COUNT-1:0]                          m_axis_direct_tx_cpl_ready,

    input  wire [PORT_COUNT-1:0]                          direct_rx_clk,
    input  wire [PORT_COUNT-1:0]                          direct_rx_rst,

    input  wire [PORT_COUNT*AXIS_DATA_WIDTH-1:0]          s_axis_direct_rx_tdata,
    input  wire [PORT_COUNT*AXIS_KEEP_WIDTH-1:0]          s_axis_direct_rx_tkeep,
    input  wire [PORT_COUNT-1:0]                          s_axis_direct_rx_tvalid,
    output wire [PORT_COUNT-1:0]                          s_axis_direct_rx_tready,
    input  wire [PORT_COUNT-1:0]                          s_axis_direct_rx_tlast,
    input  wire [PORT_COUNT*AXIS_RX_USER_WIDTH-1:0]       s_axis_direct_rx_tuser,

    output wire [PORT_COUNT*AXIS_DATA_WIDTH-1:0]          m_axis_direct_rx_tdata,
    output wire [PORT_COUNT*AXIS_KEEP_WIDTH-1:0]          m_axis_direct_rx_tkeep,
    output wire [PORT_COUNT-1:0]                          m_axis_direct_rx_tvalid,
    input  wire [PORT_COUNT-1:0]                          m_axis_direct_rx_tready,
    output wire [PORT_COUNT-1:0]                          m_axis_direct_rx_tlast,
    output wire [PORT_COUNT*AXIS_RX_USER_WIDTH-1:0]       m_axis_direct_rx_tuser,

    /*
     * Ethernet (synchronous MAC interface - low latency raw traffic)
     */
    input  wire [PORT_COUNT*AXIS_SYNC_DATA_WIDTH-1:0]     s_axis_sync_tx_tdata,
    input  wire [PORT_COUNT*AXIS_SYNC_KEEP_WIDTH-1:0]     s_axis_sync_tx_tkeep,
    input  wire [PORT_COUNT-1:0]                          s_axis_sync_tx_tvalid,
    output wire [PORT_COUNT-1:0]                          s_axis_sync_tx_tready,
    input  wire [PORT_COUNT-1:0]                          s_axis_sync_tx_tlast,
    input  wire [PORT_COUNT*AXIS_SYNC_TX_USER_WIDTH-1:0]  s_axis_sync_tx_tuser,

    output wire [PORT_COUNT*AXIS_SYNC_DATA_WIDTH-1:0]     m_axis_sync_tx_tdata,
    output wire [PORT_COUNT*AXIS_SYNC_KEEP_WIDTH-1:0]     m_axis_sync_tx_tkeep,
    output wire [PORT_COUNT-1:0]                          m_axis_sync_tx_tvalid,
    input  wire [PORT_COUNT-1:0]                          m_axis_sync_tx_tready,
    output wire [PORT_COUNT-1:0]                          m_axis_sync_tx_tlast,
    output wire [PORT_COUNT*AXIS_SYNC_TX_USER_WIDTH-1:0]  m_axis_sync_tx_tuser,

    input  wire [PORT_COUNT*PTP_TS_WIDTH-1:0]             s_axis_sync_tx_cpl_ts,
    input  wire [PORT_COUNT*TX_TAG_WIDTH-1:0]             s_axis_sync_tx_cpl_tag,
    input  wire [PORT_COUNT-1:0]                          s_axis_sync_tx_cpl_valid,
    output wire [PORT_COUNT-1:0]                          s_axis_sync_tx_cpl_ready,

    output wire [PORT_COUNT*PTP_TS_WIDTH-1:0]             m_axis_sync_tx_cpl_ts,
    output wire [PORT_COUNT*TX_TAG_WIDTH-1:0]             m_axis_sync_tx_cpl_tag,
    output wire [PORT_COUNT-1:0]                          m_axis_sync_tx_cpl_valid,
    input  wire [PORT_COUNT-1:0]                          m_axis_sync_tx_cpl_ready,

    input  wire [PORT_COUNT*AXIS_SYNC_DATA_WIDTH-1:0]     s_axis_sync_rx_tdata,
    input  wire [PORT_COUNT*AXIS_SYNC_KEEP_WIDTH-1:0]     s_axis_sync_rx_tkeep,
    input  wire [PORT_COUNT-1:0]                          s_axis_sync_rx_tvalid,
    output wire [PORT_COUNT-1:0]                          s_axis_sync_rx_tready,
    input  wire [PORT_COUNT-1:0]                          s_axis_sync_rx_tlast,
    input  wire [PORT_COUNT*AXIS_SYNC_RX_USER_WIDTH-1:0]  s_axis_sync_rx_tuser,

    output wire [PORT_COUNT*AXIS_SYNC_DATA_WIDTH-1:0]     m_axis_sync_rx_tdata,
    output wire [PORT_COUNT*AXIS_SYNC_KEEP_WIDTH-1:0]     m_axis_sync_rx_tkeep,
    output wire [PORT_COUNT-1:0]                          m_axis_sync_rx_tvalid,
    input  wire [PORT_COUNT-1:0]                          m_axis_sync_rx_tready,
    output wire [PORT_COUNT-1:0]                          m_axis_sync_rx_tlast,
    output wire [PORT_COUNT*AXIS_SYNC_RX_USER_WIDTH-1:0]  m_axis_sync_rx_tuser,

    /*
     * Ethernet (internal at interface module)
     */
    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]         s_axis_if_tx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]         s_axis_if_tx_tkeep,
    input  wire [IF_COUNT-1:0]                            s_axis_if_tx_tvalid,
    output wire [IF_COUNT-1:0]                            s_axis_if_tx_tready,
    input  wire [IF_COUNT-1:0]                            s_axis_if_tx_tlast,
    input  wire [IF_COUNT*AXIS_IF_TX_ID_WIDTH-1:0]        s_axis_if_tx_tid,
    input  wire [IF_COUNT*AXIS_IF_TX_DEST_WIDTH-1:0]      s_axis_if_tx_tdest,
    input  wire [IF_COUNT*AXIS_IF_TX_USER_WIDTH-1:0]      s_axis_if_tx_tuser,

    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]         m_axis_if_tx_tdata,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]         m_axis_if_tx_tkeep,
    output wire [IF_COUNT-1:0]                            m_axis_if_tx_tvalid,
    input  wire [IF_COUNT-1:0]                            m_axis_if_tx_tready,
    output wire [IF_COUNT-1:0]                            m_axis_if_tx_tlast,
    output wire [IF_COUNT*AXIS_IF_TX_ID_WIDTH-1:0]        m_axis_if_tx_tid,
    output wire [IF_COUNT*AXIS_IF_TX_DEST_WIDTH-1:0]      m_axis_if_tx_tdest,
    output wire [IF_COUNT*AXIS_IF_TX_USER_WIDTH-1:0]      m_axis_if_tx_tuser,

    input  wire [IF_COUNT*PTP_TS_WIDTH-1:0]               s_axis_if_tx_cpl_ts,
    input  wire [IF_COUNT*TX_TAG_WIDTH-1:0]               s_axis_if_tx_cpl_tag,
    input  wire [IF_COUNT-1:0]                            s_axis_if_tx_cpl_valid,
    output wire [IF_COUNT-1:0]                            s_axis_if_tx_cpl_ready,

    output wire [IF_COUNT*PTP_TS_WIDTH-1:0]               m_axis_if_tx_cpl_ts,
    output wire [IF_COUNT*TX_TAG_WIDTH-1:0]               m_axis_if_tx_cpl_tag,
    output wire [IF_COUNT-1:0]                            m_axis_if_tx_cpl_valid,
    input  wire [IF_COUNT-1:0]                            m_axis_if_tx_cpl_ready,

    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]         s_axis_if_rx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]         s_axis_if_rx_tkeep,
    input  wire [IF_COUNT-1:0]                            s_axis_if_rx_tvalid,
    output wire [IF_COUNT-1:0]                            s_axis_if_rx_tready,
    input  wire [IF_COUNT-1:0]                            s_axis_if_rx_tlast,
    input  wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]        s_axis_if_rx_tid,
    input  wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]      s_axis_if_rx_tdest,
    input  wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]      s_axis_if_rx_tuser,

    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]         m_axis_if_rx_tdata,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]         m_axis_if_rx_tkeep,
    output wire [IF_COUNT-1:0]                            m_axis_if_rx_tvalid,
    input  wire [IF_COUNT-1:0]                            m_axis_if_rx_tready,
    output wire [IF_COUNT-1:0]                            m_axis_if_rx_tlast,
    output wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]        m_axis_if_rx_tid,
    output wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]      m_axis_if_rx_tdest,
    output wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]      m_axis_if_rx_tuser,

    /*
     * Statistics increment output
     */
    output wire [STAT_INC_WIDTH-1:0]                      m_axis_stat_tdata,
    output wire [STAT_ID_WIDTH-1:0]                       m_axis_stat_tid,
    output wire                                           m_axis_stat_tvalid,
    input  wire                                           m_axis_stat_tready,

    /*
     * GPIO
     */
    input  wire [APP_GPIO_IN_WIDTH-1:0]                   gpio_in,
    output wire [APP_GPIO_OUT_WIDTH-1:0]                  gpio_out,

    /*
     * JTAG
     */
    input  wire                                           jtag_tdi,
    output wire                                           jtag_tdo,
    input  wire                                           jtag_tms,
    input  wire                                           jtag_tck
);

// check configuration
initial begin
    if (APP_ID != 32'h12340100) begin
        $error("Error: Invalid APP_ID (expected 32'h12340100, got 32'h%x) (instance %m)", APP_ID);
        $finish;
    end
end

localparam NUM_CLUSTERS = 2;
localparam NUM_MPQ = 256;

wire [NUM_CLUSTERS-1:0] cl_fetch_en;
wire [NUM_CLUSTERS-1:0] cl_eoc;
wire [NUM_CLUSTERS-1:0] cl_busy;
wire [NUM_MPQ-1:0] mpq_full;
wire aux_rst;
wire pspin_clk;
wire pspin_rst;
wire mmcm_locked;

// XXX: address space compressed but we don't actually need that much
// L2       starts at 32'h1c00_0000 -> 24'h00_0000
// prog mem starts at 32'h1d00_0000 -> 24'h40_0000
function [31:0] l2_addr_gen;
    input [AXIL_APP_CTRL_ADDR_WIDTH-1:0] mqnic_addr;
    reg   [23:0] real_addr;
    begin
        real_addr = {1'b0, mqnic_addr[AXIL_APP_CTRL_ADDR_WIDTH-2:0]};
        if (mqnic_addr <= 24'h40_0000)
            l2_addr_gen = {8'h1c, real_addr};
        else if (mqnic_addr <= 24'h80_0000)
            l2_addr_gen = {8'h1d, real_addr};
        `ifndef TARGET_SYNTHESIS
        else begin
            $error("Address greater than limit for L2 & program memory: 0x%0h", mqnic_addr);
            $finish;
        end
        `endif
    end
endfunction

wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]    pspin_fast_axil_awaddr;
wire [2:0]                             pspin_fast_axil_awprot;
wire                                   pspin_fast_axil_awvalid;
wire                                   pspin_fast_axil_awready;
wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]    pspin_fast_axil_wdata;
wire [AXIL_APP_CTRL_STRB_WIDTH-1:0]    pspin_fast_axil_wstrb;
wire                                   pspin_fast_axil_wvalid;
wire                                   pspin_fast_axil_wready;
wire [1:0]                             pspin_fast_axil_bresp;
wire                                   pspin_fast_axil_bvalid;
wire                                   pspin_fast_axil_bready;
wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]    pspin_fast_axil_araddr;
wire [2:0]                             pspin_fast_axil_arprot;
wire                                   pspin_fast_axil_arvalid;
wire                                   pspin_fast_axil_arready;
wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]    pspin_fast_axil_rdata;
wire [1:0]                             pspin_fast_axil_rresp;
wire                                   pspin_fast_axil_rvalid;
wire                                   pspin_fast_axil_rready;

// FIXME: allow selecting handler buffer and program buffer
wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]    pspin_axil_awaddr;
wire [2:0]                             pspin_axil_awprot;
wire                                   pspin_axil_awvalid;
wire                                   pspin_axil_awready;
wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]    pspin_axil_wdata;
wire [AXIL_APP_CTRL_STRB_WIDTH-1:0]    pspin_axil_wstrb;
wire                                   pspin_axil_wvalid;
wire                                   pspin_axil_wready;
wire [1:0]                             pspin_axil_bresp;
wire                                   pspin_axil_bvalid;
wire                                   pspin_axil_bready;
wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]    pspin_axil_araddr;
wire [2:0]                             pspin_axil_arprot;
wire                                   pspin_axil_arvalid;
wire                                   pspin_axil_arready;
wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]    pspin_axil_rdata;
wire [1:0]                             pspin_axil_rresp;
wire                                   pspin_axil_rvalid;
wire                                   pspin_axil_rready;

wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]    ctrl_reg_axil_awaddr;
wire [2:0]                             ctrl_reg_axil_awprot;
wire                                   ctrl_reg_axil_awvalid;
wire                                   ctrl_reg_axil_awready;
wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]    ctrl_reg_axil_wdata;
wire [AXIL_APP_CTRL_STRB_WIDTH-1:0]    ctrl_reg_axil_wstrb;
wire                                   ctrl_reg_axil_wvalid;
wire                                   ctrl_reg_axil_wready;
wire [1:0]                             ctrl_reg_axil_bresp;
wire                                   ctrl_reg_axil_bvalid;
wire                                   ctrl_reg_axil_bready;
wire [AXIL_APP_CTRL_ADDR_WIDTH-1:0]    ctrl_reg_axil_araddr;
wire [2:0]                             ctrl_reg_axil_arprot;
wire                                   ctrl_reg_axil_arvalid;
wire                                   ctrl_reg_axil_arready;
wire [AXIL_APP_CTRL_DATA_WIDTH-1:0]    ctrl_reg_axil_rdata;
wire [1:0]                             ctrl_reg_axil_rresp;
wire                                   ctrl_reg_axil_rvalid;
wire                                   ctrl_reg_axil_rready;

axil_interconnect_wrap_1x2 #(
    .DATA_WIDTH(AXIL_APP_CTRL_DATA_WIDTH),
    .ADDR_WIDTH(AXIL_APP_CTRL_ADDR_WIDTH),
    .STRB_WIDTH(AXIL_APP_CTRL_STRB_WIDTH),
    // total 24 bits of app addr
    .M00_BASE_ADDR(24'h00_0000),    // L2 memory write
    .M00_ADDR_WIDTH(23),
    .M01_BASE_ADDR(24'h80_0000),    // control registers
    .M01_ADDR_WIDTH(16)
) i_host_interconnect (
    .clk                    (clk),
    .rst                    (rst),

    .s00_axil_awaddr        (s_axil_app_ctrl_awaddr),
    .s00_axil_awprot        (s_axil_app_ctrl_awprot),
    .s00_axil_awvalid       (s_axil_app_ctrl_awvalid),
    .s00_axil_awready       (s_axil_app_ctrl_awready),
    .s00_axil_wdata         (s_axil_app_ctrl_wdata),
    .s00_axil_wstrb         (s_axil_app_ctrl_wstrb),
    .s00_axil_wvalid        (s_axil_app_ctrl_wvalid),
    .s00_axil_wready        (s_axil_app_ctrl_wready),
    .s00_axil_bresp         (s_axil_app_ctrl_bresp),
    .s00_axil_bvalid        (s_axil_app_ctrl_bvalid),
    .s00_axil_bready        (s_axil_app_ctrl_bready),
    .s00_axil_araddr        (s_axil_app_ctrl_araddr),
    .s00_axil_arprot        (s_axil_app_ctrl_arprot),
    .s00_axil_arvalid       (s_axil_app_ctrl_arvalid),
    .s00_axil_arready       (s_axil_app_ctrl_arready),
    .s00_axil_rdata         (s_axil_app_ctrl_rdata),
    .s00_axil_rresp         (s_axil_app_ctrl_rresp),
    .s00_axil_rvalid        (s_axil_app_ctrl_rvalid),
    .s00_axil_rready        (s_axil_app_ctrl_rready),

    .m00_axil_awaddr        (pspin_fast_axil_awaddr),
    .m00_axil_awprot        (pspin_fast_axil_awprot),
    .m00_axil_awvalid       (pspin_fast_axil_awvalid),
    .m00_axil_awready       (pspin_fast_axil_awready),
    .m00_axil_wdata         (pspin_fast_axil_wdata),
    .m00_axil_wstrb         (pspin_fast_axil_wstrb),
    .m00_axil_wvalid        (pspin_fast_axil_wvalid),
    .m00_axil_wready        (pspin_fast_axil_wready),
    .m00_axil_bresp         (pspin_fast_axil_bresp),
    .m00_axil_bvalid        (pspin_fast_axil_bvalid),
    .m00_axil_bready        (pspin_fast_axil_bready),
    .m00_axil_araddr        (pspin_fast_axil_araddr),
    .m00_axil_arprot        (pspin_fast_axil_arprot),
    .m00_axil_arvalid       (pspin_fast_axil_arvalid),
    .m00_axil_arready       (pspin_fast_axil_arready),
    .m00_axil_rdata         (pspin_fast_axil_rdata),
    .m00_axil_rresp         (pspin_fast_axil_rresp),
    .m00_axil_rvalid        (pspin_fast_axil_rvalid),
    .m00_axil_rready        (pspin_fast_axil_rready),

    .m01_axil_awaddr        (ctrl_reg_axil_awaddr),
    .m01_axil_awprot        (ctrl_reg_axil_awprot),
    .m01_axil_awvalid       (ctrl_reg_axil_awvalid),
    .m01_axil_awready       (ctrl_reg_axil_awready),
    .m01_axil_wdata         (ctrl_reg_axil_wdata),
    .m01_axil_wstrb         (ctrl_reg_axil_wstrb),
    .m01_axil_wvalid        (ctrl_reg_axil_wvalid),
    .m01_axil_wready        (ctrl_reg_axil_wready),
    .m01_axil_bresp         (ctrl_reg_axil_bresp),
    .m01_axil_bvalid        (ctrl_reg_axil_bvalid),
    .m01_axil_bready        (ctrl_reg_axil_bready),
    .m01_axil_araddr        (ctrl_reg_axil_araddr),
    .m01_axil_arprot        (ctrl_reg_axil_arprot),
    .m01_axil_arvalid       (ctrl_reg_axil_arvalid),
    .m01_axil_arready       (ctrl_reg_axil_arready),
    .m01_axil_rdata         (ctrl_reg_axil_rdata),
    .m01_axil_rresp         (ctrl_reg_axil_rresp),
    .m01_axil_rvalid        (ctrl_reg_axil_rvalid),
    .m01_axil_rready        (ctrl_reg_axil_rready)
);

wire stdout_rd_en;
always @* begin
    pspin_inst.i_pspin.i_periphs.i_stdout.rd_en <= stdout_rd_en;
end
pspin_ctrl_regs #(
    .DATA_WIDTH(AXIL_APP_CTRL_DATA_WIDTH),
    .ADDR_WIDTH(AXIL_APP_CTRL_ADDR_WIDTH),
    .STRB_WIDTH(AXIL_APP_CTRL_STRB_WIDTH),
    .NUM_CLUSTERS(NUM_CLUSTERS)
) i_pspin_ctrl (
    .clk(clk),
    .rst(rst),

    .s_axil_awaddr          (ctrl_reg_axil_awaddr),
    .s_axil_awprot          (ctrl_reg_axil_awprot),
    .s_axil_awvalid         (ctrl_reg_axil_awvalid),
    .s_axil_awready         (ctrl_reg_axil_awready),
    .s_axil_wdata           (ctrl_reg_axil_wdata),
    .s_axil_wstrb           (ctrl_reg_axil_wstrb),
    .s_axil_wvalid          (ctrl_reg_axil_wvalid),
    .s_axil_wready          (ctrl_reg_axil_wready),
    .s_axil_bresp           (ctrl_reg_axil_bresp),
    .s_axil_bvalid          (ctrl_reg_axil_bvalid),
    .s_axil_bready          (ctrl_reg_axil_bready),
    .s_axil_araddr          (ctrl_reg_axil_araddr),
    .s_axil_arprot          (ctrl_reg_axil_arprot),
    .s_axil_arvalid         (ctrl_reg_axil_arvalid),
    .s_axil_arready         (ctrl_reg_axil_arready),
    .s_axil_rdata           (ctrl_reg_axil_rdata),
    .s_axil_rresp           (ctrl_reg_axil_rresp),
    .s_axil_rvalid          (ctrl_reg_axil_rvalid),
    .s_axil_rready          (ctrl_reg_axil_rready),

    .pspin_clk,
    
    .cl_fetch_en_o          (cl_fetch_en),
    .aux_rst_o              (aux_rst),
    .cl_eoc_i               (cl_eoc),
    .cl_busy_i              (cl_busy),
    .mpq_full_i             (mpq_full),

    .stdout_rd_en           (stdout_rd_en),
    .stdout_dout            (pspin_inst.i_pspin.i_periphs.i_stdout.dout),
    .stdout_data_valid      (pspin_inst.i_pspin.i_periphs.i_stdout.data_valid)
);

pspin_clk_wiz i_pspin_clk_wiz (
    .clk_out1(pspin_clk),
    .reset(rst),
    .locked(mmcm_locked),
    .clk_in1(clk)
);

pspin_host_clk_converter i_pspin_axi_conv (
  .s_axi_aclk(clk),                         // input wire s_axi_aclk
  .s_axi_aresetn(!rst),                     // input wire s_axi_aresetn
  .s_axi_awaddr(pspin_fast_axil_awaddr),    // input wire [23 : 0] s_axi_awaddr
  .s_axi_awprot(pspin_fast_axil_awprot),    // input wire [2 : 0] s_axi_awprot
  .s_axi_awvalid(pspin_fast_axil_awvalid),  // input wire s_axi_awvalid
  .s_axi_awready(pspin_fast_axil_awready),  // output wire s_axi_awready
  .s_axi_wdata(pspin_fast_axil_wdata),      // input wire [31 : 0] s_axi_wdata
  .s_axi_wstrb(pspin_fast_axil_wstrb),      // input wire [3 : 0] s_axi_wstrb
  .s_axi_wvalid(pspin_fast_axil_wvalid),    // input wire s_axi_wvalid
  .s_axi_wready(pspin_fast_axil_wready),    // output wire s_axi_wready
  .s_axi_bresp(pspin_fast_axil_bresp),      // output wire [1 : 0] s_axi_bresp
  .s_axi_bvalid(pspin_fast_axil_bvalid),    // output wire s_axi_bvalid
  .s_axi_bready(pspin_fast_axil_bready),    // input wire s_axi_bready
  .s_axi_araddr(pspin_fast_axil_araddr),    // input wire [23 : 0] s_axi_araddr
  .s_axi_arprot(pspin_fast_axil_arprot),    // input wire [2 : 0] s_axi_arprot
  .s_axi_arvalid(pspin_fast_axil_arvalid),  // input wire s_axi_arvalid
  .s_axi_arready(pspin_fast_axil_arready),  // output wire s_axi_arready
  .s_axi_rdata(pspin_fast_axil_rdata),      // output wire [31 : 0] s_axi_rdata
  .s_axi_rresp(pspin_fast_axil_rresp),      // output wire [1 : 0] s_axi_rresp
  .s_axi_rvalid(pspin_fast_axil_rvalid),    // output wire s_axi_rvalid
  .s_axi_rready(pspin_fast_axil_rready),    // input wire s_axi_rready

  .m_axi_aclk(pspin_clk),              // input wire m_axi_aclk
  .m_axi_aresetn(!pspin_rst),          // input wire m_axi_aresetn
  .m_axi_awaddr(pspin_axil_awaddr),    // output wire [23 : 0] m_axi_awaddr
  .m_axi_awprot(pspin_axil_awprot),    // output wire [2 : 0] m_axi_awprot
  .m_axi_awvalid(pspin_axil_awvalid),  // output wire m_axi_awvalid
  .m_axi_awready(pspin_axil_awready),  // input wire m_axi_awready
  .m_axi_wdata(pspin_axil_wdata),      // output wire [31 : 0] m_axi_wdata
  .m_axi_wstrb(pspin_axil_wstrb),      // output wire [3 : 0] m_axi_wstrb
  .m_axi_wvalid(pspin_axil_wvalid),    // output wire m_axi_wvalid
  .m_axi_wready(pspin_axil_wready),    // input wire m_axi_wready
  .m_axi_bresp(pspin_axil_bresp),      // input wire [1 : 0] m_axi_bresp
  .m_axi_bvalid(pspin_axil_bvalid),    // input wire m_axi_bvalid
  .m_axi_bready(pspin_axil_bready),    // output wire m_axi_bready
  .m_axi_araddr(pspin_axil_araddr),    // output wire [23 : 0] m_axi_araddr
  .m_axi_arprot(pspin_axil_arprot),    // output wire [2 : 0] m_axi_arprot
  .m_axi_arvalid(pspin_axil_arvalid),  // output wire m_axi_arvalid
  .m_axi_arready(pspin_axil_arready),  // input wire m_axi_arready
  .m_axi_rdata(pspin_axil_rdata),      // input wire [31 : 0] m_axi_rdata
  .m_axi_rresp(pspin_axil_rresp),      // input wire [1 : 0] m_axi_rresp
  .m_axi_rvalid(pspin_axil_rvalid),    // input wire m_axi_rvalid
  .m_axi_rready(pspin_axil_rready)     // output wire m_axi_rready
);

proc_sys_reset_0 i_pspin_rst (
  .slowest_sync_clk(pspin_clk),        // input wire slowest_sync_clk
  .ext_reset_in(rst),                  // input wire ext_reset_in
  .aux_reset_in(aux_rst),              // input wire aux_reset_in
  .mb_debug_sys_rst('b0),              // input wire mb_debug_sys_rst
  .dcm_locked(mmcm_locked),            // input wire dcm_locked
  .mb_reset(pspin_rst),                // output wire mb_reset
  .bus_struct_reset(),                 // output wire [0 : 0] bus_struct_reset
  .peripheral_reset(),                 // output wire [0 : 0] peripheral_reset
  .interconnect_aresetn(),             // output wire [0 : 0] interconnect_aresetn
  .peripheral_aresetn()                // output wire [0 : 0] peripheral_aresetn
);

pspin_wrap #(
    .N_CLUSTERS(NUM_CLUSTERS), // pspin_cfg_pkg::NUM_CLUSTERS
    .N_MPQ(NUM_MPQ)     // pspin_cfg_pkg::NUM_MPQ
)
pspin_inst (
    .clk_i(pspin_clk),
    .rst_ni(!pspin_rst),

    .cl_fetch_en_i(cl_fetch_en),
    .cl_eoc_o(cl_eoc),
    .cl_busy_o(cl_busy),

    .mpq_full_o(mpq_full),

    .host_slave_aw_addr_i   (l2_addr_gen(pspin_axil_awaddr)),
    .host_slave_aw_prot_i   (pspin_axil_awprot),
    .host_slave_aw_valid_i  (pspin_axil_awvalid),
    .host_slave_aw_ready_o  (pspin_axil_awready),
    .host_slave_w_data_i    (pspin_axil_wdata),
    .host_slave_w_strb_i    (pspin_axil_wstrb),
    .host_slave_w_valid_i   (pspin_axil_wvalid),
    .host_slave_w_ready_o   (pspin_axil_wready),
    .host_slave_b_resp_o    (pspin_axil_bresp),
    .host_slave_b_valid_o   (pspin_axil_bvalid),
    .host_slave_b_ready_i   (pspin_axil_bready),
    .host_slave_ar_addr_i   (l2_addr_gen(pspin_axil_araddr)),
    .host_slave_ar_prot_i   (pspin_axil_arprot),
    .host_slave_ar_valid_i  (pspin_axil_arvalid),
    .host_slave_ar_ready_o  (pspin_axil_arready),
    .host_slave_r_data_o    (pspin_axil_rdata),
    .host_slave_r_resp_o    (pspin_axil_rresp),
    .host_slave_r_valid_o   (pspin_axil_rvalid),
    .host_slave_r_ready_i   (pspin_axil_rready)
);

/*
 * AXI-Lite master interface (control to NIC)
 */
assign m_axil_ctrl_awaddr = 0;
assign m_axil_ctrl_awprot = 0;
assign m_axil_ctrl_awvalid = 1'b0;
assign m_axil_ctrl_wdata = 0;
assign m_axil_ctrl_wstrb = 0;
assign m_axil_ctrl_wvalid = 1'b0;
assign m_axil_ctrl_bready = 1'b1;
assign m_axil_ctrl_araddr = 0;
assign m_axil_ctrl_arprot = 0;
assign m_axil_ctrl_arvalid = 1'b0;
assign m_axil_ctrl_rready = 1'b1;

/*
 * Ethernet (direct MAC interface - lowest latency raw traffic)
 */
assign m_axis_direct_tx_tdata = s_axis_direct_tx_tdata;
assign m_axis_direct_tx_tkeep = s_axis_direct_tx_tkeep;
assign m_axis_direct_tx_tvalid = s_axis_direct_tx_tvalid;
assign s_axis_direct_tx_tready = m_axis_direct_tx_tready;
assign m_axis_direct_tx_tlast = s_axis_direct_tx_tlast;
assign m_axis_direct_tx_tuser = s_axis_direct_tx_tuser;

assign m_axis_direct_tx_cpl_ts = s_axis_direct_tx_cpl_ts;
assign m_axis_direct_tx_cpl_tag = s_axis_direct_tx_cpl_tag;
assign m_axis_direct_tx_cpl_valid = s_axis_direct_tx_cpl_valid;
assign s_axis_direct_tx_cpl_ready = m_axis_direct_tx_cpl_ready;

assign m_axis_direct_rx_tdata = s_axis_direct_rx_tdata;
assign m_axis_direct_rx_tkeep = s_axis_direct_rx_tkeep;
assign m_axis_direct_rx_tvalid = s_axis_direct_rx_tvalid;
assign s_axis_direct_rx_tready = m_axis_direct_rx_tready;
assign m_axis_direct_rx_tlast = s_axis_direct_rx_tlast;
assign m_axis_direct_rx_tuser = s_axis_direct_rx_tuser;

/*
 * Ethernet (synchronous MAC interface - low latency raw traffic)
 */
assign m_axis_sync_tx_tdata = s_axis_sync_tx_tdata;
assign m_axis_sync_tx_tkeep = s_axis_sync_tx_tkeep;
assign m_axis_sync_tx_tvalid = s_axis_sync_tx_tvalid;
assign s_axis_sync_tx_tready = m_axis_sync_tx_tready;
assign m_axis_sync_tx_tlast = s_axis_sync_tx_tlast;
assign m_axis_sync_tx_tuser = s_axis_sync_tx_tuser;

assign m_axis_sync_tx_cpl_ts = s_axis_sync_tx_cpl_ts;
assign m_axis_sync_tx_cpl_tag = s_axis_sync_tx_cpl_tag;
assign m_axis_sync_tx_cpl_valid = s_axis_sync_tx_cpl_valid;
assign s_axis_sync_tx_cpl_ready = m_axis_sync_tx_cpl_ready;

assign m_axis_sync_rx_tdata = s_axis_sync_rx_tdata;
assign m_axis_sync_rx_tkeep = s_axis_sync_rx_tkeep;
assign m_axis_sync_rx_tvalid = s_axis_sync_rx_tvalid;
assign s_axis_sync_rx_tready = m_axis_sync_rx_tready;
assign m_axis_sync_rx_tlast = s_axis_sync_rx_tlast;
assign m_axis_sync_rx_tuser = s_axis_sync_rx_tuser;

/*
 * Ethernet (internal at interface module)
 */
assign m_axis_if_tx_tdata = s_axis_if_tx_tdata;
assign m_axis_if_tx_tkeep = s_axis_if_tx_tkeep;
assign m_axis_if_tx_tvalid = s_axis_if_tx_tvalid;
assign s_axis_if_tx_tready = m_axis_if_tx_tready;
assign m_axis_if_tx_tlast = s_axis_if_tx_tlast;
assign m_axis_if_tx_tid = s_axis_if_tx_tid;
assign m_axis_if_tx_tdest = s_axis_if_tx_tdest;
assign m_axis_if_tx_tuser = s_axis_if_tx_tuser;

assign m_axis_if_tx_cpl_ts = s_axis_if_tx_cpl_ts;
assign m_axis_if_tx_cpl_tag = s_axis_if_tx_cpl_tag;
assign m_axis_if_tx_cpl_valid = s_axis_if_tx_cpl_valid;
assign s_axis_if_tx_cpl_ready = m_axis_if_tx_cpl_ready;

assign m_axis_if_rx_tdata = s_axis_if_rx_tdata;
assign m_axis_if_rx_tkeep = s_axis_if_rx_tkeep;
assign m_axis_if_rx_tvalid = s_axis_if_rx_tvalid;
assign s_axis_if_rx_tready = m_axis_if_rx_tready;
assign m_axis_if_rx_tlast = s_axis_if_rx_tlast;
assign m_axis_if_rx_tid = s_axis_if_rx_tid;
assign m_axis_if_rx_tdest = s_axis_if_rx_tdest;
assign m_axis_if_rx_tuser = s_axis_if_rx_tuser;

/*
 * DMA interface (control)
 */
assign m_axis_ctrl_dma_read_desc_dma_addr = 0;
assign m_axis_ctrl_dma_read_desc_ram_sel = 0;
assign m_axis_ctrl_dma_read_desc_ram_addr = 0;
assign m_axis_ctrl_dma_read_desc_len = 0;
assign m_axis_ctrl_dma_read_desc_tag = 0;
assign m_axis_ctrl_dma_read_desc_valid = 1'b0;
assign m_axis_ctrl_dma_write_desc_dma_addr = 0;
assign m_axis_ctrl_dma_write_desc_ram_sel = 0;
assign m_axis_ctrl_dma_write_desc_ram_addr = 0;
assign m_axis_ctrl_dma_write_desc_imm = 0;
assign m_axis_ctrl_dma_write_desc_imm_en = 0;
assign m_axis_ctrl_dma_write_desc_len = 0;
assign m_axis_ctrl_dma_write_desc_tag = 0;
assign m_axis_ctrl_dma_write_desc_valid = 1'b0;

assign ctrl_dma_ram_wr_cmd_ready = 1'b1;
assign ctrl_dma_ram_wr_done = ctrl_dma_ram_wr_cmd_valid;
assign ctrl_dma_ram_rd_cmd_ready = ctrl_dma_ram_rd_resp_ready;
assign ctrl_dma_ram_rd_resp_data = 0;
assign ctrl_dma_ram_rd_resp_valid = ctrl_dma_ram_rd_cmd_valid;

/*
 * DMA interface (data)
 */
assign m_axis_data_dma_read_desc_dma_addr = 0;
assign m_axis_data_dma_read_desc_ram_sel = 0;
assign m_axis_data_dma_read_desc_ram_addr = 0;
assign m_axis_data_dma_read_desc_len = 0;
assign m_axis_data_dma_read_desc_tag = 0;
assign m_axis_data_dma_read_desc_valid = 1'b0;
assign m_axis_data_dma_write_desc_dma_addr = 0;
assign m_axis_data_dma_write_desc_ram_sel = 0;
assign m_axis_data_dma_write_desc_ram_addr = 0;
assign m_axis_data_dma_write_desc_imm = 0;
assign m_axis_data_dma_write_desc_imm_en = 0;
assign m_axis_data_dma_write_desc_len = 0;
assign m_axis_data_dma_write_desc_tag = 0;
assign m_axis_data_dma_write_desc_valid = 1'b0;

assign data_dma_ram_wr_cmd_ready = 1'b1;
assign data_dma_ram_wr_done = data_dma_ram_wr_cmd_valid;
assign data_dma_ram_rd_cmd_ready = data_dma_ram_rd_resp_ready;
assign data_dma_ram_rd_resp_data = 0;
assign data_dma_ram_rd_resp_valid = data_dma_ram_rd_cmd_valid;

/*
 * Statistics increment output
 */
assign m_axis_stat_tdata = 0;
assign m_axis_stat_tid = 0;
assign m_axis_stat_tvalid = 1'b0;

/*
 * GPIO
 */
assign gpio_out = 0;

/*
 * JTAG
 */
assign jtag_tdo = jtag_tdi;

endmodule

`resetall
