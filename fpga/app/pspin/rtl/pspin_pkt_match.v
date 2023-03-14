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

    parameter UMATCH_MTU = 1500,
    parameter UMATCH_BUF_FRAMES = 2,

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

localparam MATCHER_BEATS = (UMATCH_MTU + AXIS_IF_DATA_WIDTH - 1) / (AXIS_IF_DATA_WIDTH);
localparam MATCHER_IDX_WIDTH = $clog2(MATCHER_BEATS);
localparam MATCHER_WIDTH = MATCHER_BEATS * AXIS_IF_DATA_WIDTH;
localparam BUFFER_FIFO_DEPTH = UMATCH_BUF_FRAMES * MATCHER_BEATS * AXIS_IF_KEEP_WIDTH;

initial begin
    if (UMATCH_MODES != 2) begin
        $error("Error: exactly 2 modes supported: AND and OR");
        $finish;
    end
end

wire [AXIS_IF_DATA_WIDTH-1:0]         buffered_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]         buffered_tkeep;
wire                                  buffered_tvalid;
wire                                  buffered_tready;
wire                                  buffered_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]        buffered_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]      buffered_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]      buffered_tuser;
wire                                  buffered_overflow;
wire                                  buffered_good_frame;
wire                                  buffered_bad_frame;

reg [AXIS_IF_DATA_WIDTH-1:0]          send_tdata;
reg [AXIS_IF_KEEP_WIDTH-1:0]          send_tkeep;
reg                                   send_tvalid;
wire                                  send_tready;
reg                                   send_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]        send_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]      send_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]      send_tuser;

// state
localparam [2:0]
    IDLE = 3'h0,
    RECV = 3'h1,
    RECV_LAST = 3'h2,
    MATCH = 3'h3,
    SEND = 3'h4,
    SEND_LAST = 3'h5;
reg [2:0] state_q, state_d;

// outputs
reg [MATCHER_WIDTH-1:0] matcher;
reg [MATCHER_IDX_WIDTH-1:0] matcher_idx;
reg [MATCHER_IDX_WIDTH-1:0] last_idx;
reg [AXIS_IF_DATA_WIDTH-1:0] last_tkeep;
localparam
    MATCH_AND = 1'b0,
    MATCH_OR = 1'b1;
reg matched;

// matching units
reg [UMATCH_WIDTH-1:0] mu_data [UMATCH_ENTRIES-1:0];
reg [MATCHER_IDX_WIDTH-1:0] mu_idx [UMATCH_ENTRIES-1:0];
reg [UMATCH_ENTRIES-1:0] mu_matched;
wire and_matched = &mu_matched;
wire or_matched = |mu_matched;
generate
genvar i;
for (i = 0; i < UMATCH_ENTRIES; i = i + 1) begin
    always @* begin
        mu_idx[i] = match_idx[i*UMATCH_WIDTH +: UMATCH_WIDTH] * UMATCH_WIDTH;
        mu_data[i] = matcher[mu_idx[i] +: UMATCH_WIDTH];
        mu_matched[i] =
            match_start[i] <= (mu_data[i] & match_mask[i]) &&
            match_end[i]   >= (mu_data[i] & match_mask[i]);
    end
end
endgenerate

always @(posedge clk) begin
    if (!rstn) begin
        state_q <= IDLE;
    end else begin
        state_q <= state_d;
    end
end

// state transition
always @* begin
    state_d = state_q;

    case (state_q)
        IDLE: if (buffered_tvalid && buffered_tready)
            state_d = RECV;
        RECV: if (buffered_tvalid && buffered_tready && buffered_tlast)
            state_d = RECV_LAST;
        RECV_LAST: state_d = MATCH;
        MATCH: state_d = SEND;
        SEND: if (send_tvalid && send_tready && last_idx == matcher_idx)
            state_d = SEND_LAST;
        SEND_LAST: state_d = IDLE;
    endcase
end

// moore output
always @(posedge clk) begin
    case (state_d) // next state
        IDLE: begin
            matcher <= {MATCHER_WIDTH{1'b0}};
            matcher_idx <= {MATCHER_IDX_WIDTH{1'b0}};
            last_idx <= {MATCHER_IDX_WIDTH{1'b0}};
            last_tkeep <= {AXIS_IF_DATA_WIDTH{1'b0}};
            matched <= 1'b0;
            send_tdata <= {AXIS_IF_DATA_WIDTH{1'b0}};
            send_tvalid <= 1'b0;
        end
        RECV: begin
            matcher[matcher_idx +: AXIS_IF_DATA_WIDTH] <= buffered_tdata;
            matcher_idx <= matcher_idx + AXIS_IF_DATA_WIDTH;
        end
        RECV_LAST: begin
            matcher[matcher_idx +: AXIS_IF_DATA_WIDTH] <= buffered_tdata;
            matcher_idx <= {MATCHER_IDX_WIDTH{1'b0}};
            last_idx <= matcher_idx;
            last_tkeep <= buffered_tkeep;
        end
        MATCH: begin
            matched <= 
                match_mode == MATCH_AND ? and_matched : or_matched;
        end
        SEND: begin
            send_tdata <= matcher[matcher_idx +: AXIS_IF_DATA_WIDTH];
            send_tvalid <= 1'b1;
            matcher_idx <= matcher_idx + AXIS_IF_DATA_WIDTH;
        end
        SEND_LAST: begin
            send_tdata <= matcher[matcher_idx +: AXIS_IF_DATA_WIDTH];
            send_tvalid <= 1'b1;
            send_tlast <= 1'b1;
            send_tkeep <= last_tkeep;
        end
    endcase
end
assign send_tready = matched ? m_axis_pspin_rx_tready : m_axis_nic_rx_tready;

assign m_axis_nic_rx_tdata = !matched ? send_tdata : {AXIS_IF_DATA_WIDTH{1'b0}};
assign m_axis_nic_rx_tkeep = !matched ? send_tkeep : {AXIS_IF_KEEP_WIDTH{1'b0}};
assign m_axis_nic_rx_tvalid = !matched ? send_tvalid : 1'b0;
assign m_axis_nic_rx_tlast = !matched ? send_tlast : 1'b0;
assign m_axis_nic_rx_tid = !matched ? send_tid : {AXIS_IF_RX_ID_WIDTH{1'b0}};
assign m_axis_nic_rx_tdest = !matched ? send_tdest : {AXIS_IF_RX_DEST_WIDTH{1'b0}};
assign m_axis_nic_rx_tuser = !matched ? send_tuser : {AXIS_IF_RX_USER_WIDTH{1'b0}};

assign m_axis_pspin_rx_tdata = matched ? send_tdata : {AXIS_IF_DATA_WIDTH{1'b0}};
assign m_axis_pspin_rx_tkeep = matched ? send_tkeep : {AXIS_IF_KEEP_WIDTH{1'b0}};
assign m_axis_pspin_rx_tvalid = matched ? send_tvalid : 1'b0;
assign m_axis_pspin_rx_tlast = matched ? send_tlast : 1'b0;
assign m_axis_pspin_rx_tid = matched ? send_tid : {AXIS_IF_RX_ID_WIDTH{1'b0}};
assign m_axis_pspin_rx_tdest = matched ? send_tdest : {AXIS_IF_RX_DEST_WIDTH{1'b0}};
assign m_axis_pspin_rx_tuser = matched ? send_tuser : {AXIS_IF_RX_USER_WIDTH{1'b0}};

// FIFO to buffer input packets
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

    .s_axis_tdata    (s_axis_nic_rx_tdata),
    .s_axis_tkeep    (s_axis_nic_rx_tkeep),
    .s_axis_tvalid   (s_axis_nic_rx_tvalid),
    .s_axis_tready   (s_axis_nic_rx_tready),
    .s_axis_tlast    (s_axis_nic_rx_tlast),
    .s_axis_tid      (s_axis_nic_rx_tid),
    .s_axis_tdest    (s_axis_nic_rx_tdest),
    .s_axis_tuser    (s_axis_nic_rx_tuser),

    .m_axis_tdata    (buffered_tdata),
    .m_axis_tkeep    (buffered_tkeep),
    .m_axis_tvalid   (buffered_tvalid),
    .m_axis_tready   (buffered_tready),
    .m_axis_tlast    (buffered_tlast),
    .m_axis_tid      (buffered_tid),
    .m_axis_tdest    (buffered_tdest),
    .m_axis_tuser    (buffered_tuser),

    .status_overflow    (buffered_overflow),
    .status_bad_frame   (buffered_bad_frame),
    .status_good_frame  (buffered_good_frame)
);

endmodule
