module axil_regbus (
	clk,
	rst_n,
	s_axil_awaddr,
	s_axil_awvalid,
	s_axil_awready,
	s_axil_wdata,
	s_axil_wstrb,
	s_axil_wvalid,
	s_axil_wready,
	s_axil_bresp,
	s_axil_bvalid,
	s_axil_bready,
	s_axil_araddr,
	s_axil_arvalid,
	s_axil_arready,
	s_axil_rdata,
	s_axil_rresp,
	s_axil_rvalid,
	s_axil_rready,
	reg_wr,
	reg_waddr,
	reg_wdata,
	reg_wstrb,
	reg_rd,
	reg_raddr,
	reg_rdata
);
	parameter signed [31:0] ADDR_W = 16;
	parameter signed [31:0] DATA_W = 32;
	input wire clk;
	input wire rst_n;
	input wire [ADDR_W - 1:0] s_axil_awaddr;
	input wire s_axil_awvalid;
	output wire s_axil_awready;
	input wire [DATA_W - 1:0] s_axil_wdata;
	input wire [(DATA_W / 8) - 1:0] s_axil_wstrb;
	input wire s_axil_wvalid;
	output wire s_axil_wready;
	output wire [1:0] s_axil_bresp;
	output reg s_axil_bvalid;
	input wire s_axil_bready;
	input wire [ADDR_W - 1:0] s_axil_araddr;
	input wire s_axil_arvalid;
	output wire s_axil_arready;
	output reg [DATA_W - 1:0] s_axil_rdata;
	output wire [1:0] s_axil_rresp;
	output reg s_axil_rvalid;
	input wire s_axil_rready;
	output reg reg_wr;
	output reg [ADDR_W - 1:0] reg_waddr;
	output reg [DATA_W - 1:0] reg_wdata;
	output reg [(DATA_W / 8) - 1:0] reg_wstrb;
	output reg reg_rd;
	output reg [ADDR_W - 1:0] reg_raddr;
	input wire [DATA_W - 1:0] reg_rdata;
	reg aw_held;
	reg w_held;
	reg [ADDR_W - 1:0] awaddr_q;
	reg [DATA_W - 1:0] wdata_q;
	reg [(DATA_W / 8) - 1:0] wstrb_q;
	assign s_axil_awready = !aw_held;
	assign s_axil_wready = !w_held;
	assign s_axil_bresp = 2'b00;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			aw_held <= 1'b0;
			w_held <= 1'b0;
			awaddr_q <= 1'sb0;
			wdata_q <= 1'sb0;
			wstrb_q <= 1'sb0;
			s_axil_bvalid <= 1'b0;
			reg_wr <= 1'b0;
			reg_waddr <= 1'sb0;
			reg_wdata <= 1'sb0;
			reg_wstrb <= 1'sb0;
		end
		else begin
			reg_wr <= 1'b0;
			if (s_axil_awvalid && s_axil_awready) begin
				aw_held <= 1'b1;
				awaddr_q <= s_axil_awaddr;
			end
			if (s_axil_wvalid && s_axil_wready) begin
				w_held <= 1'b1;
				wdata_q <= s_axil_wdata;
				wstrb_q <= s_axil_wstrb;
			end
			if ((aw_held && w_held) && !s_axil_bvalid) begin
				reg_wr <= 1'b1;
				reg_waddr <= awaddr_q;
				reg_wdata <= wdata_q;
				reg_wstrb <= wstrb_q;
				aw_held <= 1'b0;
				w_held <= 1'b0;
				s_axil_bvalid <= 1'b1;
			end
			else if (s_axil_bvalid && s_axil_bready)
				s_axil_bvalid <= 1'b0;
		end
	reg rd_pend;
	reg rd_d;
	assign s_axil_arready = !rd_pend && !s_axil_rvalid;
	assign s_axil_rresp = 2'b00;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			rd_pend <= 1'b0;
			rd_d <= 1'b0;
			reg_rd <= 1'b0;
			reg_raddr <= 1'sb0;
			s_axil_rvalid <= 1'b0;
			s_axil_rdata <= 1'sb0;
		end
		else begin
			reg_rd <= 1'b0;
			rd_d <= reg_rd;
			if (s_axil_arvalid && s_axil_arready) begin
				reg_rd <= 1'b1;
				reg_raddr <= s_axil_araddr;
				rd_pend <= 1'b1;
			end
			if (rd_d) begin
				s_axil_rdata <= reg_rdata;
				s_axil_rvalid <= 1'b1;
				rd_pend <= 1'b0;
			end
			else if (s_axil_rvalid && s_axil_rready)
				s_axil_rvalid <= 1'b0;
		end
endmodule