module axil_split (
	clk,
	rst_n,
	s_awaddr,
	s_awvalid,
	s_awready,
	s_wdata,
	s_wstrb,
	s_wvalid,
	s_wready,
	s_bresp,
	s_bvalid,
	s_bready,
	s_araddr,
	s_arvalid,
	s_arready,
	s_rdata,
	s_rresp,
	s_rvalid,
	s_rready,
	m_awaddr,
	m_awvalid,
	m_awready,
	m_wdata,
	m_wstrb,
	m_wvalid,
	m_wready,
	m_bresp,
	m_bvalid,
	m_bready,
	m_araddr,
	m_arvalid,
	m_arready,
	m_rdata,
	m_rresp,
	m_rvalid,
	m_rready
);
	reg _sv2v_0;
	parameter signed [31:0] ADDR_W = 15;
	parameter signed [31:0] SEL_BIT = ADDR_W - 1;
	input wire clk;
	input wire rst_n;
	input wire [ADDR_W - 1:0] s_awaddr;
	input wire s_awvalid;
	output wire s_awready;
	input wire [31:0] s_wdata;
	input wire [3:0] s_wstrb;
	input wire s_wvalid;
	output wire s_wready;
	output reg [1:0] s_bresp;
	output reg s_bvalid;
	input wire s_bready;
	input wire [ADDR_W - 1:0] s_araddr;
	input wire s_arvalid;
	output wire s_arready;
	output reg [31:0] s_rdata;
	output reg [1:0] s_rresp;
	output reg s_rvalid;
	input wire s_rready;
	output reg [(2 * ADDR_W) - 1:0] m_awaddr;
	output reg [1:0] m_awvalid;
	input wire [1:0] m_awready;
	output reg [63:0] m_wdata;
	output reg [7:0] m_wstrb;
	output reg [1:0] m_wvalid;
	input wire [1:0] m_wready;
	input wire [3:0] m_bresp;
	input wire [1:0] m_bvalid;
	output reg [1:0] m_bready;
	output reg [(2 * ADDR_W) - 1:0] m_araddr;
	output reg [1:0] m_arvalid;
	input wire [1:0] m_arready;
	input wire [63:0] m_rdata;
	input wire [3:0] m_rresp;
	input wire [1:0] m_rvalid;
	output reg [1:0] m_rready;
	reg [1:0] wst;
	reg aw_held;
	reg w_held;
	reg aw_sent;
	reg w_sent;
	reg wsel;
	reg [ADDR_W - 1:0] awaddr_q;
	reg [31:0] wdata_q;
	reg [3:0] wstrb_q;
	assign s_awready = (wst == 2'd0) && !aw_held;
	assign s_wready = (wst == 2'd0) && !w_held;
	function automatic signed [0:0] sv2v_cast_1_signed;
		input reg signed [0:0] inp;
		sv2v_cast_1_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < 2; i = i + 1)
				begin
					m_awaddr[i * ADDR_W+:ADDR_W] = awaddr_q;
					m_wdata[i * 32+:32] = wdata_q;
					m_wstrb[i * 4+:4] = wstrb_q;
					m_awvalid[i] = ((wst == 2'd1) && (wsel == sv2v_cast_1_signed(i))) && !aw_sent;
					m_wvalid[i] = ((wst == 2'd1) && (wsel == sv2v_cast_1_signed(i))) && !w_sent;
					m_bready[i] = (wst == 2'd2) && (wsel == sv2v_cast_1_signed(i));
				end
		end
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			wst <= 2'd0;
			aw_held <= 0;
			w_held <= 0;
			aw_sent <= 0;
			w_sent <= 0;
			wsel <= 0;
			awaddr_q <= 1'sb0;
			wdata_q <= 1'sb0;
			wstrb_q <= 1'sb0;
			s_bvalid <= 0;
			s_bresp <= 1'sb0;
		end
		else
			case (wst)
				2'd0: begin
					if (s_awvalid && s_awready) begin
						aw_held <= 1;
						awaddr_q <= s_awaddr;
					end
					if (s_wvalid && s_wready) begin
						w_held <= 1;
						wdata_q <= s_wdata;
						wstrb_q <= s_wstrb;
					end
					if ((aw_held || (s_awvalid && s_awready)) && (w_held || (s_wvalid && s_wready))) begin
						wst <= 2'd1;
						wsel <= (aw_held ? awaddr_q[SEL_BIT] : s_awaddr[SEL_BIT]);
						aw_sent <= 0;
						w_sent <= 0;
					end
				end
				2'd1: begin : sv2v_autoblock_2
					reg aw_ok;
					reg w_ok;
					aw_ok = aw_sent || (m_awvalid[wsel] && m_awready[wsel]);
					w_ok = w_sent || (m_wvalid[wsel] && m_wready[wsel]);
					aw_sent <= aw_ok;
					w_sent <= w_ok;
					if (aw_ok && w_ok)
						wst <= 2'd2;
				end
				2'd2:
					if (m_bvalid[wsel]) begin
						s_bresp <= m_bresp[wsel * 2+:2];
						s_bvalid <= 1;
						wst <= 2'd3;
					end
				2'd3:
					if (s_bready) begin
						s_bvalid <= 0;
						aw_held <= 0;
						w_held <= 0;
						wst <= 2'd0;
					end
				default: wst <= 2'd0;
			endcase
	reg [1:0] rst_q;
	reg rsel;
	reg [ADDR_W - 1:0] araddr_q;
	assign s_arready = rst_q == 2'd0;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_3
			reg signed [31:0] i;
			for (i = 0; i < 2; i = i + 1)
				begin
					m_araddr[i * ADDR_W+:ADDR_W] = araddr_q;
					m_arvalid[i] = (rst_q == 2'd1) && (rsel == sv2v_cast_1_signed(i));
					m_rready[i] = (rst_q == 2'd2) && (rsel == sv2v_cast_1_signed(i));
				end
		end
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			rst_q <= 2'd0;
			rsel <= 0;
			araddr_q <= 1'sb0;
			s_rvalid <= 0;
			s_rdata <= 1'sb0;
			s_rresp <= 1'sb0;
		end
		else
			case (rst_q)
				2'd0:
					if (s_arvalid) begin
						araddr_q <= s_araddr;
						rsel <= s_araddr[SEL_BIT];
						rst_q <= 2'd1;
					end
				2'd1:
					if (m_arready[rsel])
						rst_q <= 2'd2;
				2'd2:
					if (m_rvalid[rsel]) begin
						s_rdata <= m_rdata[rsel * 32+:32];
						s_rresp <= m_rresp[rsel * 2+:2];
						s_rvalid <= 1;
						rst_q <= 2'd3;
					end
				2'd3:
					if (s_rready) begin
						s_rvalid <= 0;
						rst_q <= 2'd0;
					end
				default: rst_q <= 2'd0;
			endcase
	initial _sv2v_0 = 0;
endmodule