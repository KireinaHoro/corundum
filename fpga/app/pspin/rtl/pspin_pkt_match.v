/**
 * PsPIN Packet Match Engine
 *
 * Match against a total of UMATCH_ENTRIES number of packets.  For each rule:
 *     matched == (start <= packet[idx] & mask <= end)
 * Multiple rules are combined based on match_mode.  Currently supported
 * modes:
 *     0: AND of all rules
 *     1: OR of all rules
 * To disable a rule, put UMATCH_WIDTH{1'b0} in mask.  The rule would generate
 * the respective unit value in the combining modes.
 */

module pspin_pkt_match #(
    parameter UMATCH_WIDTH = 32,
    parameter UMATCH_ENTRIES = 16,
    parameter UMATCH_MODES = 2,

    parameter AXIS_IF_DATA_WIDTH = 512,
    parameter AXIS_IF_KEEP_WIDTH = AXIS_IF_DATA_WIDTH/8,
    parameter AXIS_IF_RX_ID_WIDTH = 1,
    parameter AXIS_IF_RX_DEST_WIDTH = 8,
    parameter AXIS_IF_RX_USER_WIDTH = 97
) (
    input wire clk,
    input wire rstn,

    // from NIC
    input  wire [AXIS_IF_DATA_WIDTH-1:0]         s_axis_nic_rx_tdata,
    input  wire [AXIS_IF_KEEP_WIDTH-1:0]         s_axis_nic_rx_tkeep,
    input  wire                                  s_axis_nic_rx_tvalid,
    output wire                                  s_axis_nic_rx_tready,
    input  wire                                  s_axis_nic_rx_tlast,
    input  wire [AXIS_IF_RX_ID_WIDTH-1:0]        s_axis_nic_rx_tid,
    input  wire [AXIS_IF_RX_DEST_WIDTH-1:0]      s_axis_nic_rx_tdest,
    input  wire [AXIS_IF_RX_USER_WIDTH-1:0]      s_axis_nic_rx_tuser,

    // to NIC - unmatched
    output wire [AXIS_IF_DATA_WIDTH-1:0]         m_axis_nic_rx_tdata,
    output wire [AXIS_IF_KEEP_WIDTH-1:0]         m_axis_nic_rx_tkeep,
    output wire                                  m_axis_nic_rx_tvalid,
    input  wire                                  m_axis_nic_rx_tready,
    output wire                                  m_axis_nic_rx_tlast,
    output wire [AXIS_IF_RX_ID_WIDTH-1:0]        m_axis_nic_rx_tid,
    output wire [AXIS_IF_RX_DEST_WIDTH-1:0]      m_axis_nic_rx_tdest,
    output wire [AXIS_IF_RX_USER_WIDTH-1:0]      m_axis_nic_rx_tuser,

    // to PsPIN - matched
    output wire [AXIS_IF_DATA_WIDTH-1:0]         m_axis_pspin_rx_tdata,
    output wire [AXIS_IF_KEEP_WIDTH-1:0]         m_axis_pspin_rx_tkeep,
    output wire                                  m_axis_pspin_rx_tvalid,
    input  wire                                  m_axis_pspin_rx_tready,
    output wire                                  m_axis_pspin_rx_tlast,
    output wire [AXIS_IF_RX_ID_WIDTH-1:0]        m_axis_pspin_rx_tid,
    output wire [AXIS_IF_RX_DEST_WIDTH-1:0]      m_axis_pspin_rx_tdest,
    output wire [AXIS_IF_RX_USER_WIDTH-1:0]      m_axis_pspin_rx_tuser,

    // matching rules
    input  wire [$clog2(UMATCH_MODES)-1:0]        match_mode,
    input  wire [UMATCH_WIDTH*UMATCH_ENTRIES-1:0] match_idx,
    input  wire [UMATCH_WIDTH*UMATCH_ENTRIES-1:0] match_mask,
    input  wire [UMATCH_WIDTH*UMATCH_ENTRIES-1:0] match_start,
    input  wire [UMATCH_WIDTH*UMATCH_ENTRIES-1:0] match_end,
    input  wire                                   match_valid
);

endmodule