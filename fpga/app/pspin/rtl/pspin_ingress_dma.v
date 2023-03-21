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
    parameter AXIS_IF_RX_USER_WIDTH = 97
) (
    input wire clk,
    input wire rstn,

    // from matching engine
    input  wire [AXIS_IF_DATA_WIDTH-1:0]         s_axis_pspin_rx_tdata,
    input  wire [AXIS_IF_KEEP_WIDTH-1:0]         s_axis_pspin_rx_tkeep,
    input  wire                                  s_axis_pspin_rx_tvalid,
    output wire                                  s_axis_pspin_rx_tready,
    input  wire                                  s_axis_pspin_rx_tlast,
    input  wire [AXIS_IF_RX_ID_WIDTH-1:0]        s_axis_pspin_rx_tid,
    input  wire [AXIS_IF_RX_DEST_WIDTH-1:0]      s_axis_pspin_rx_tdest,
    input  wire [AXIS_IF_RX_USER_WIDTH-1:0]      s_axis_pspin_rx_tuser,
);

endmodule