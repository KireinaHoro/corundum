/**
 * PsPIN host memory DMA read datapath
 *
 * Read datapath of the host memory DMA adapter.  Utilises the verilog-pcie
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
module pspin_hostmem_dma_rd #(
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
     * DMA read descriptor output (data)
     */
    output reg  [ADDR_WIDTH-1:0]                        m_axis_read_desc_dma_addr,
    output reg  [RAM_SEL_WIDTH-1:0]                     m_axis_read_desc_ram_sel,
    output reg  [RAM_ADDR_WIDTH-1:0]                    m_axis_read_desc_ram_addr,
    output reg  [DMA_LEN_WIDTH-1:0]                     m_axis_read_desc_len,
    output reg  [DMA_TAG_WIDTH-1:0]                     m_axis_read_desc_tag,
    output reg                                          m_axis_read_desc_valid,
    input  wire                                         m_axis_read_desc_ready,

    /*
     * DMA read descriptor status input (data)
     */
    input  wire [DMA_TAG_WIDTH-1:0]                     s_axis_read_desc_status_tag,
    input  wire [3:0]                                   s_axis_read_desc_status_error,
    input  wire                                         s_axis_read_desc_status_valid,
    
    /*
     * RAM interface
     */
    output wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]  ram_rd_cmd_addr,
    output wire [RAM_SEG_COUNT-1:0]                     ram_rd_cmd_valid,
    input  wire [RAM_SEG_COUNT-1:0]                     ram_rd_cmd_ready,
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  ram_rd_resp_data,
    input  wire [RAM_SEG_COUNT-1:0]                     ram_rd_resp_valid,
    output wire [RAM_SEG_COUNT-1:0]                     ram_rd_resp_ready,

    /* AXI AR & R channels */
    input  wire [ID_WIDTH-1:0]                          s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]                        s_axi_araddr,
    input  wire [7:0]                                   s_axi_arlen,
    input  wire [2:0]                                   s_axi_arsize,
    input  wire [1:0]                                   s_axi_arburst,
    input  wire                                         s_axi_arlock,
    input  wire [3:0]                                   s_axi_arcache,
    input  wire [2:0]                                   s_axi_arprot,
    input  wire [3:0]                                   s_axi_arqos,
    input  wire [3:0]                                   s_axi_arregion,
    input  wire [ARUSER_WIDTH-1:0]                      s_axi_aruser,
    input  wire                                         s_axi_arvalid,
    output reg                                          s_axi_arready,
    output reg  [ID_WIDTH-1:0]                          s_axi_rid,
    output reg  [DATA_WIDTH-1:0]                        s_axi_rdata,
    output reg  [1:0]                                   s_axi_rresp,
    output reg                                          s_axi_rlast,
    output reg  [RUSER_WIDTH-1:0]                       s_axi_ruser,
    output reg                                          s_axi_rvalid,
    input  wire                                         s_axi_rready
);

localparam STATE_WIDTH = 4;
localparam
    IDLE = 'h0,
    ISSUE_TO_DMA = 'h1,
    WAIT_DMA = 'h2, // wait for req FINISHED
    ISSUE_TO_CLIENT = 'h3,
    WAIT_CLIENT = 'h4, // wait for req ACCEPTED - status will only come after AXIS transfer
    CAPTURE_AXIS_DATA = 'h5, // capture data from AXI Stream and send first beat downstream
    SEND_AXI_REST_BEAT = 'h6; // stall AXI Stream, send remaining beats
localparam RAM_SIZE = DATA_WIDTH * 256; // AXI4 INCR has maximal 256-beat bursts
localparam BYTELANE_IDX_WIDTH = DATA_WIDTH / 8; // max single-byte beats

localparam DMA_ERROR_NONE = 4'b0;
localparam AXI_OKAY = 2'b00;
localparam AXI_SLVERR = 2'b10;

reg [STATE_WIDTH-1:0] state_q, state_d;
reg dma_error_q, dma_error_d;
// only used on SLVERR
reg [7:0] beat_idx_d, beat_idx_q, num_beats;

reg [DMA_LEN_WIDTH-1:0] saved_dma_len;
reg [ID_WIDTH-1:0] saved_id;

// bytelane info after AR
reg [BYTELANE_IDX_WIDTH-1:0] init_bl_idx, end_bl_idx;
wire [BYTELANE_IDX_WIDTH-1:0] curr_bl_idx = (init_bl_idx + beat_idx_q) % (end_bl_idx + 1);

// DMA client AXIS
reg [RAM_ADDR_WIDTH-1:0] dma_read_desc_ram_addr;
reg [DMA_LEN_WIDTH-1:0] dma_read_desc_len;
// FIXME: when we support multiple inflight txns:
// - tag should be internal idx into txn table
// - id should be (saved) ARID/RID
reg [ID_WIDTH-1:0] dma_read_desc_id;
reg dma_read_desc_valid;
wire dma_read_desc_ready;
wire dma_read_desc_status_valid;

wire [DATA_WIDTH-1:0] axis_tdata;
wire [ID_WIDTH-1:0] axis_tid;
wire axis_tlast;
reg axis_tlast_q;
wire axis_tvalid;
reg  axis_tready;

initial begin
    if (DMA_TAG_WIDTH < ID_WIDTH) begin
        $error("DMA interface tag too narrow: %d vs AXI ID_WIDTH %d\n", DMA_TAG_WIDTH, ID_WIDTH);
        $finish;
    end
end

always @(posedge clk) begin
    state_q <= state_d;
    dma_error_q <= dma_error_d;
    beat_idx_q <= beat_idx_d;
    if (!rstn) begin
        state_q <= IDLE;
        dma_error_q <= 1'b0;
        beat_idx_q <= 8'b0;
    end
end

// state transition
always @* begin
    state_d = state_q;
    dma_error_d = dma_error_q;
    beat_idx_d = beat_idx_q;
    case (state_q)
        IDLE: begin
            if (s_axi_arready && s_axi_arvalid)
                state_d = ISSUE_TO_DMA;
            dma_error_d = 1'b0;
            beat_idx_d = 8'b0;
        end
        ISSUE_TO_DMA: if (m_axis_read_desc_valid && m_axis_read_desc_ready)
            state_d = WAIT_DMA;
        WAIT_DMA: if (s_axis_read_desc_status_valid) begin
            if (s_axis_read_desc_status_error != DMA_ERROR_NONE) begin
                state_d = SEND_AXI_REST_BEAT; // in case of slave error we still need the required number of beats
                dma_error_d = 1'b1;
            end else
                state_d = ISSUE_TO_CLIENT;
        end
        ISSUE_TO_CLIENT, WAIT_CLIENT: if (dma_read_desc_valid && dma_read_desc_ready)
            state_d = CAPTURE_AXIS_DATA;
        else
            state_d = WAIT_CLIENT;
        CAPTURE_AXIS_DATA: begin
            if (axis_tvalid && axis_tready) begin
                state_d = SEND_AXI_REST_BEAT;
                beat_idx_d = beat_idx_q + 8'h1;
                if (s_axi_rready) begin
                    // if we use the full bus - implies curr_bl_idx == end_bl_idx
                    // if not last beat of AXI Stream: capture again
                    if (end_bl_idx == {BYTELANE_IDX_WIDTH{1'b0}})
                        state_d = CAPTURE_AXIS_DATA;
                end
            end
            if (beat_idx_q == num_beats && s_axi_rready)
                state_d = IDLE;
        end
        SEND_AXI_REST_BEAT: if (s_axi_rvalid && s_axi_rready) begin
            if (!dma_error_q && curr_bl_idx == end_bl_idx)
                state_d = axis_tlast_q ? SEND_AXI_REST_BEAT : CAPTURE_AXIS_DATA;
            if (curr_bl_idx > {BYTELANE_IDX_WIDTH{1'b0}})
                beat_idx_d = beat_idx_q + 8'h1;
            if (beat_idx_q == num_beats)
                state_d = IDLE;
        end
        default: begin /* nothing */ end
    endcase
end

// calculate initial address
reg [31:0] num_bytes_arsize, num_beats_in_axis_beat;
reg [8:0] num_beats_d; // one more bit due to possibility of overflowing
localparam NUM_BYTES_BUS = BYTELANE_IDX_WIDTH;
reg [ADDR_WIDTH-1:0] addr_align_arsize, addr_align_bus;
reg [BYTELANE_IDX_WIDTH-1:0] init_bl_idx_d, end_bl_idx_d;
reg [DMA_LEN_WIDTH-1:0] dma_len_d; // in bytes
always @* begin
    num_bytes_arsize = 1 << s_axi_arsize;
    num_beats_d = s_axi_arlen + 1;
    num_beats_in_axis_beat = NUM_BYTES_BUS / num_bytes_arsize;
    addr_align_arsize = s_axi_araddr / num_bytes_arsize * num_bytes_arsize;
    addr_align_bus = s_axi_araddr / NUM_BYTES_BUS * NUM_BYTES_BUS;
    init_bl_idx_d = (addr_align_arsize - addr_align_bus) / num_bytes_arsize;
    end_bl_idx_d = num_beats_in_axis_beat - 1;
    dma_len_d = NUM_BYTES_BUS * ((num_beats_d + num_beats_in_axis_beat - 1) / num_beats_in_axis_beat);
end

// state-machine output
always @(posedge clk) begin
    case (state_d)
        IDLE: begin
            saved_dma_len <= {DMA_LEN_WIDTH{1'b0}};
            m_axis_read_desc_valid <= 1'b0;
            s_axi_arready <= m_axis_read_desc_ready;
            s_axi_rid <= {ID_WIDTH{1'b0}};
            s_axi_rdata <= {DATA_WIDTH{1'b0}};
            s_axi_rresp <= AXI_OKAY;
            s_axi_rlast <= 1'b0;
            s_axi_ruser <= {RUSER_WIDTH{1'b0}};
            s_axi_rvalid <= 1'b0;
            axis_tready <= 1'b0;
            init_bl_idx <= {BYTELANE_IDX_WIDTH{1'b0}};
            end_bl_idx <= {BYTELANE_IDX_WIDTH{1'b0}};
        end
        ISSUE_TO_DMA: begin
            // save bytelane calculations
            init_bl_idx <= init_bl_idx_d;
            end_bl_idx <= end_bl_idx_d;
            // save dma len
            saved_dma_len <= dma_len_d;
            // save number of beats in total for error handling
            num_beats <= num_beats_d;
            // issue to DMA intf
            m_axis_read_desc_dma_addr <= addr_align_bus;
            m_axis_read_desc_ram_sel <= {RAM_SEL_WIDTH{1'b0}};
            m_axis_read_desc_ram_addr <= {RAM_ADDR_WIDTH{1'b0}};
            m_axis_read_desc_len <= dma_len_d;
            // FIXME: when we support multiple inflight txns:
            // - tag should be internal idx into txn table
            // - id should be (saved) ARID/RID
            m_axis_read_desc_tag <= s_axi_arid;
            saved_id <= s_axi_arid;
            m_axis_read_desc_valid <= 1'b1;
            // block AR
            s_axi_arready <= 1'b0;
        end
        WAIT_DMA: if (m_axis_read_desc_ready)
            m_axis_read_desc_valid <= 1'b0;
        ISSUE_TO_CLIENT: begin
            dma_read_desc_ram_addr <= {RAM_ADDR_WIDTH{1'b0}};
            dma_read_desc_len <= saved_dma_len;
            dma_read_desc_id <= s_axis_read_desc_status_tag;
            dma_read_desc_valid <= 1'b1;
        end
        // WAIT_CLIENT: nothing
        CAPTURE_AXIS_DATA: begin
            axis_tready <= 1'b1;
            dma_read_desc_valid <= 1'b0;

            // latch AXI Stream data
            if (axis_tvalid && axis_tready) begin
                // latch last for state transfer
                axis_tlast_q <= axis_tlast;

                // send first beat
                s_axi_rvalid <= 1'b1;
                s_axi_rdata <= axis_tdata;
                s_axi_rid <= axis_tid;
                s_axi_rresp <= AXI_OKAY;
                s_axi_rlast <= beat_idx_d == num_beats;
            end else begin
                // valid=0 if acknowledged
                if (s_axi_rready)
                    s_axi_rvalid <= 1'b0;
            end
        end
        SEND_AXI_REST_BEAT: begin
            // latch AXI Stream data
            if (axis_tvalid && axis_tready) begin
                // latch last for state transfer
                axis_tlast_q <= axis_tlast;

                // send next beat
                s_axi_rvalid <= 1'b1;
                s_axi_rdata <= axis_tdata;
                s_axi_rid <= axis_tid;
                s_axi_rresp <= AXI_OKAY;
                s_axi_rlast <= beat_idx_d == num_beats;
            end

            axis_tready <= 1'b0;

            s_axi_rlast <= beat_idx_d == num_beats;
            if (dma_error_d) begin
                // handle error
                s_axi_rid <= saved_id;
                s_axi_rresp <= AXI_SLVERR;
            end
        end
        default: begin /* nothing */ end
    endcase
end


dma_client_axis_source #(
    .SEG_COUNT(RAM_SEG_COUNT),
    .SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .AXIS_DATA_WIDTH(DATA_WIDTH),
    .AXIS_KEEP_ENABLE(1),
    .AXIS_LAST_ENABLE(1),
    .AXIS_ID_ENABLE(1),
    .AXIS_ID_WIDTH(ID_WIDTH),
    .AXIS_DEST_ENABLE(0),
    .AXIS_DEST_WIDTH(1),
    .AXIS_USER_ENABLE(0),
    .AXIS_USER_WIDTH(1),
    .LEN_WIDTH(DMA_LEN_WIDTH),
    .TAG_WIDTH(1)
) i_dma_client_axis (
    .clk(clk),
    .rst(!rstn),

    /*
     * DMA read descriptor input
     */
    .s_axis_read_desc_ram_addr(dma_read_desc_ram_addr),
    .s_axis_read_desc_len(dma_read_desc_len),
    .s_axis_read_desc_tag(1'b0),
    .s_axis_read_desc_id(dma_read_desc_id),
    .s_axis_read_desc_dest(1'b0),
    .s_axis_read_desc_user(1'b0),
    .s_axis_read_desc_valid(dma_read_desc_valid),
    .s_axis_read_desc_ready(dma_read_desc_ready),

    /*
     * DMA read descriptor status output
     */
    .m_axis_read_desc_status_tag(),
    .m_axis_read_desc_status_error(),
    .m_axis_read_desc_status_valid(dma_read_desc_status_valid),

    /*
     * AXI stream read data output
     */
    .m_axis_read_data_tdata(axis_tdata),
    .m_axis_read_data_tkeep(),
    .m_axis_read_data_tvalid(axis_tvalid),
    .m_axis_read_data_tready(axis_tready),
    .m_axis_read_data_tlast(axis_tlast),
    .m_axis_read_data_tid(axis_tid),
    .m_axis_read_data_tdest(),
    .m_axis_read_data_tuser(),

    /*
     * RAM interface
     */
    .ram_rd_cmd_addr,
    .ram_rd_cmd_valid,
    .ram_rd_cmd_ready,
    .ram_rd_resp_data,
    .ram_rd_resp_valid,
    .ram_rd_resp_ready,

    /*
     * Configuration
     */
    .enable(1'b1)
);


endmodule