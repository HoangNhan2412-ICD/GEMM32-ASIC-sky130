`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// AxiLiteControlRegs - ASIC copy of axi_ip/Control_register_file.v (KV260).
//
// Same register map, same handshake, same reset values, so the KV260 driver
// (FPGA_GEMM.cpp, Defines.h) and the original testbench talk to it unchanged:
//
//   0x00  W: [9:0] shift, [16] clear done (self-clearing pulse)
//         R: [9:0] shift, [24] busy, [25] done, [26] idle,
//            [27] clear accepted, [28] clear refused (job busy)
//   0x04  [8:0] row count     (F_length)
//   0x08  [4:0] K block count (F_width_block_num)
//   0x0C  [4:0] N block count (W_width_block_num)
//
// One difference, on purpose: the FPGA template kept all 32 bits of
// registers 1..3 because they are readable, i.e. 96 flops nobody uses.
// Here only the bits the core takes are stored and the rest read as 0.
// Software that writes the values it means (row count < 512, block counts
// < 32) reads back exactly what it wrote, as before.
//
// The write/read channel logic is the Xilinx AXI4-Lite slave template the
// FPGA version used (awready and wready together once AWVALID and WVALID
// are both high, one outstanding write, registered read data), kept as is.
// Synchronous reset on S_AXI_ARESETN, like the template; the parent feeds
// it the output of ResetSync.
// ---------------------------------------------------------------------------
module AxiLiteControlRegs
#(
    parameter integer P_AXI_LITE_DATA_WIDTH = 32,
    parameter integer P_AXI_LITE_ADDR_WIDTH = 4
)
(
    output [9:0]    o_cfg_shift,
    output [8:0]    o_cfg_row_count,
    output [4:0]    o_cfg_k_block_count,
    output [4:0]    o_cfg_n_block_count,
    output          o_job_start_clear,
    input           i_job_busy,
    input           i_job_done,
    input           i_job_idle,
    input           i_job_clear_accepted,
    input           i_job_clear_busy_error,

    input                                   S_AXI_ACLK,
    input                                   S_AXI_ARESETN,
    input  [P_AXI_LITE_ADDR_WIDTH-1:0]      S_AXI_AWADDR,
    input  [2:0]                            S_AXI_AWPROT,
    input                                   S_AXI_AWVALID,
    output                                  S_AXI_AWREADY,
    input  [P_AXI_LITE_DATA_WIDTH-1:0]      S_AXI_WDATA,
    input  [(P_AXI_LITE_DATA_WIDTH/8)-1:0]  S_AXI_WSTRB,
    input                                   S_AXI_WVALID,
    output                                  S_AXI_WREADY,
    output [1:0]                            S_AXI_BRESP,
    output                                  S_AXI_BVALID,
    input                                   S_AXI_BREADY,
    input  [P_AXI_LITE_ADDR_WIDTH-1:0]      S_AXI_ARADDR,
    input  [2:0]                            S_AXI_ARPROT,
    input                                   S_AXI_ARVALID,
    output                                  S_AXI_ARREADY,
    output [P_AXI_LITE_DATA_WIDTH-1:0]      S_AXI_RDATA,
    output [1:0]                            S_AXI_RRESP,
    output                                  S_AXI_RVALID,
    input                                   S_AXI_RREADY
);

// word address = addr[3:2] for a 32-bit bus (template: ADDR_LSB = 2, 1 extra bit)
localparam integer LP_ADDR_LSB = (P_AXI_LITE_DATA_WIDTH / 32) + 1;

reg [P_AXI_LITE_ADDR_WIDTH-1:0] r_awaddr;
reg                             r_awready;
reg                             r_wready;
reg                             r_bvalid;
reg                             r_aw_en;
reg [P_AXI_LITE_ADDR_WIDTH-1:0] r_araddr;
reg                             r_arready;
reg                             r_rvalid;
reg [P_AXI_LITE_DATA_WIDTH-1:0] r_rdata;

reg [9:0]   r_shift;
reg [8:0]   r_row_count;
reg [4:0]   r_k_block_count;
reg [4:0]   r_n_block_count;

wire [1:0]  w_waddr = r_awaddr[LP_ADDR_LSB+1:LP_ADDR_LSB];
wire [1:0]  w_raddr = r_araddr[LP_ADDR_LSB+1:LP_ADDR_LSB];
wire        w_wren  = r_wready & S_AXI_WVALID & r_awready & S_AXI_AWVALID;
wire        w_rden  = r_arready & S_AXI_ARVALID & ~r_rvalid;

// ---- write address / data handshake (template behaviour)
always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN) begin
        r_awready <= 1'b0;
        r_aw_en   <= 1'b1;
    end
    else if (~r_awready & S_AXI_AWVALID & S_AXI_WVALID & r_aw_en) begin
        r_awready <= 1'b1;
        r_aw_en   <= 1'b0;
    end
    else if (S_AXI_BREADY & r_bvalid) begin
        r_aw_en   <= 1'b1;
        r_awready <= 1'b0;
    end
    else
        r_awready <= 1'b0;
end

always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN)
        r_awaddr <= {P_AXI_LITE_ADDR_WIDTH{1'b0}};
    else if (~r_awready & S_AXI_AWVALID & S_AXI_WVALID & r_aw_en)
        r_awaddr <= S_AXI_AWADDR;
end

always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN)
        r_wready <= 1'b0;
    else
        r_wready <= ~r_wready & S_AXI_WVALID & S_AXI_AWVALID & r_aw_en;
end

always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN)
        r_bvalid <= 1'b0;
    else if (r_awready & S_AXI_AWVALID & ~r_bvalid & r_wready & S_AXI_WVALID)
        r_bvalid <= 1'b1;
    else if (S_AXI_BREADY & r_bvalid)
        r_bvalid <= 1'b0;
end

// ---- registers, byte strobes as in the template
always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN) begin
        r_shift         <= 10'd0;
        r_row_count     <= 9'd0;
        r_k_block_count <= 5'd0;
        r_n_block_count <= 5'd0;
    end
    else if (w_wren) begin
        case (w_waddr)
            2'h0: begin
                if (S_AXI_WSTRB[0]) r_shift[7:0] <= S_AXI_WDATA[7:0];
                if (S_AXI_WSTRB[1]) r_shift[9:8] <= S_AXI_WDATA[9:8];
            end
            2'h1: begin
                if (S_AXI_WSTRB[0]) r_row_count[7:0] <= S_AXI_WDATA[7:0];
                if (S_AXI_WSTRB[1]) r_row_count[8]   <= S_AXI_WDATA[8];
            end
            2'h2: if (S_AXI_WSTRB[0]) r_k_block_count <= S_AXI_WDATA[4:0];
            default: if (S_AXI_WSTRB[0]) r_n_block_count <= S_AXI_WDATA[4:0];
        endcase
    end
end

// clear-done pulse: a write to 0x00 with bit 16 set (WSTRB not looked at,
// same as the FPGA version)
assign o_job_start_clear = w_wren & (w_waddr == 2'h0) & S_AXI_WDATA[16];

// ---- read channel (template behaviour)
always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN) begin
        r_arready <= 1'b0;
        r_araddr  <= {P_AXI_LITE_ADDR_WIDTH{1'b0}};
    end
    else if (~r_arready & S_AXI_ARVALID) begin
        r_arready <= 1'b1;
        r_araddr  <= S_AXI_ARADDR;
    end
    else
        r_arready <= 1'b0;
end

always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN)
        r_rvalid <= 1'b0;
    else if (r_arready & S_AXI_ARVALID & ~r_rvalid)
        r_rvalid <= 1'b1;
    else if (r_rvalid & S_AXI_RREADY)
        r_rvalid <= 1'b0;
end

reg [31:0] w_rdata_next;
always @(*) begin
    case (w_raddr)
        2'h0:    w_rdata_next = {3'b000, i_job_clear_busy_error, i_job_clear_accepted,
                                 i_job_idle, i_job_done, i_job_busy, 14'b0, r_shift};
        2'h1:    w_rdata_next = {23'b0, r_row_count};
        2'h2:    w_rdata_next = {27'b0, r_k_block_count};
        default: w_rdata_next = {27'b0, r_n_block_count};
    endcase
end

always @(posedge S_AXI_ACLK) begin
    if (~S_AXI_ARESETN)
        r_rdata <= {P_AXI_LITE_DATA_WIDTH{1'b0}};
    else if (w_rden)
        r_rdata <= w_rdata_next[P_AXI_LITE_DATA_WIDTH-1:0];
end

assign S_AXI_AWREADY = r_awready;
assign S_AXI_WREADY  = r_wready;
assign S_AXI_BRESP   = 2'b00;       // OKAY, as the template
assign S_AXI_BVALID  = r_bvalid;
assign S_AXI_ARREADY = r_arready;
assign S_AXI_RDATA   = r_rdata;
assign S_AXI_RRESP   = 2'b00;
assign S_AXI_RVALID  = r_rvalid;

assign o_cfg_shift         = r_shift;
assign o_cfg_row_count     = r_row_count;
assign o_cfg_k_block_count = r_k_block_count;
assign o_cfg_n_block_count = r_n_block_count;

endmodule
