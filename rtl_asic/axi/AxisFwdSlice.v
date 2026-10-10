`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// AxisFwdSlice - one-entry forward register slice for a valid/ready stream.
//
// m_valid and m_data come from flops; s_ready is combinational:
//     s_ready = r_ready & (~m_valid | m_ready)
// i.e. one AND-OR between the m_side ready and the s_side port. Half the
// flops of AxisSkidBuffer (one data bank instead of two) and still one beat
// per cycle while m_ready stays high.
//
// Where it is used ("lean" variant of GemmAxiShell): the feature and weight
// inputs. On that side the core is already close to registered: the data
// goes straight into the OpenRAM write port and the core's ready is a
// counter compare on flops (In_buffer.v), so registering the backward path
// as well (a full skid buffer) buys little and costs 258 flops per stream.
//
// s_ready stays low during reset and for the first cycle after it (r_ready),
// for the same reason as in AxisSkidBuffer: the parent's reset releases a
// few cycles after the port reset.
// P_CLOCK_GATE = 1: the data bank is clocked through an AxisClockGate whose
// enable is the load condition.
// ---------------------------------------------------------------------------
module AxisFwdSlice
#(
    parameter integer P_WIDTH      = 258,
    parameter integer P_CLOCK_GATE = 0
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

reg                 r_valid;
reg [P_WIDTH-1:0]   r_data;
reg                 r_ready;

wire w_s_ready = r_ready & (~r_valid | i_m_ready);
wire w_load    = i_s_valid & w_s_ready;

always @(posedge i_clk or negedge i_rst_n) begin
    if (~i_rst_n) begin
        r_valid <= 1'b0;
        r_ready <= 1'b0;
    end
    else begin
        r_ready <= 1'b1;
        if (~r_valid | i_m_ready)
            r_valid <= w_load;          // empty or leaving: take the new beat if there is one
    end
end

generate
if (P_CLOCK_GATE) begin : g_cg
    wire w_gclk;
    AxisClockGate u_cg (.i_clk(i_clk), .i_en(w_load), .o_gclk(w_gclk));
    always @(posedge w_gclk)
        r_data <= i_s_data;
end
else begin : g_en
    always @(posedge i_clk)
        if (w_load)
            r_data <= i_s_data;
end
endgenerate

assign o_s_ready = w_s_ready;
assign o_m_valid = r_valid;
assign o_m_data  = r_data;

endmodule
