`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// AxisSkidBuffer - two-entry register slice for one valid/ready stream.
//
// Every output of this block comes straight from a flop: m_valid, m_data and
// s_ready. Nothing combinational runs from the s_ side to the m_ side or
// back, so a stream port behind one of these has no in->out feedthrough and
// its timing does not depend on whoever drives or receives it.
//
//   main entry  (r_m_valid, r_m_data)   : what the m_ side sees
//   skid entry  (r_s_valid, r_s_data)   : catches the one beat that arrives
//                                         in the cycle the m_ side stalls,
//                                         because s_ready is a cycle late
//
// Full throughput (one beat per cycle) while m_ready stays high; after a
// stall the beat in the skid entry goes out first, so order is kept and no
// beat is lost or repeated.
//
// s_ready stays low during reset and for the first cycle after it (r_ready):
// the parent resets this block from a synchronised reset that releases a few
// cycles after the port reset, and a beat offered in that gap must not be
// taken and lost.
//
// The data flops have no reset (only the valid/ready flops do): they are
// loaded before they are used, and leaving the reset off saves area and the
// reset fanout on P_WIDTH bits. They only load when a beat is taken, which
// also keeps their toggling (power) down to the real traffic.
// ---------------------------------------------------------------------------
module AxisSkidBuffer
#(
    parameter integer P_WIDTH = 258
)
(
    input                   i_clk,
    input                   i_rst_n,

    input                   i_s_valid,
    output                  o_s_ready,
    input  [P_WIDTH-1:0]    i_s_data,

    output                  o_m_valid,
    input                   i_m_ready,
    output [P_WIDTH-1:0]    o_m_data
);

reg                 r_m_valid;
reg [P_WIDTH-1:0]   r_m_data;
reg                 r_s_valid;      // skid entry full
reg [P_WIDTH-1:0]   r_s_data;
reg                 r_ready;        // 0 in reset, 1 from the first cycle after it

wire w_s_ready  = ~r_s_valid & r_ready;
wire w_m_free   = i_m_ready | ~r_m_valid;   // main entry empty or leaving this cycle
wire w_s_accept = i_s_valid & w_s_ready;

always @(posedge i_clk or negedge i_rst_n) begin
    if (~i_rst_n) begin
        r_m_valid <= 1'b0;
        r_s_valid <= 1'b0;
        r_ready   <= 1'b0;
    end
    else begin
        r_ready <= 1'b1;
        if (w_m_free) begin
            if (r_s_valid) begin
                r_m_valid <= 1'b1;          // skid beat moves to main
                r_s_valid <= 1'b0;
            end
            else
                r_m_valid <= w_s_accept;    // new beat straight into main
        end
        else if (w_s_accept)
            r_s_valid <= 1'b1;              // main is stalled: park the new beat
    end
end

always @(posedge i_clk) begin
    if (w_m_free) begin
        if (r_s_valid)
            r_m_data <= r_s_data;
        else if (w_s_accept)
            r_m_data <= i_s_data;
    end
    if (~w_m_free & w_s_accept)
        r_s_data <= i_s_data;
end

assign o_s_ready = w_s_ready;
assign o_m_valid = r_m_valid;
assign o_m_data  = r_m_data;

endmodule
