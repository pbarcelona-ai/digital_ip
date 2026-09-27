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
module scaler_ctrl (
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
	s_axis_tdata,
	s_axis_tvalid,
	s_axis_tready,
	s_axis_tuser,
	s_axis_tlast,
	fb_we,
	fb_wx,
	fb_wy,
	fb_wdata,
	fb_wbuf,
	gen_buf,
	gen_start,
	gen_done,
	lb_nxt_y,
	lb_nxt_v,
	lb_o_y,
	lb_o_v,
	lb_a_y,
	lb_a_v,
	lb_hold,
	cfg_in_w,
	cfg_in_h,
	cfg_out_w,
	cfg_out_h,
	cfg_step_x,
	cfg_step_y,
	cfg_offs_x,
	cfg_offs_y,
	ext_wr,
	ext_waddr,
	ext_wdata,
	ext_rd,
	ext_raddr,
	ext_rdata
);
	reg _sv2v_0;
	parameter signed [31:0] PIX_W = 24;
	parameter signed [31:0] ADDR_W = 14;
	parameter signed [31:0] MAX_W = 1920;
	parameter signed [31:0] MAX_H = 1080;
	parameter [31:0] IP_ID = 32'h00000000;
	parameter [31:0] CAPS = 32'h00000000;
	parameter signed [31:0] NBUF = 1;
	parameter signed [31:0] LB_ROWS = 0;
	parameter signed [31:0] LB_TAPS = 1;
	parameter signed [31:0] LB_CTR = 0;
	parameter signed [31:0] LB_RND = 0;
	input wire clk;
	input wire rst_n;
	input wire [ADDR_W - 1:0] s_axil_awaddr;
	input wire s_axil_awvalid;
	output wire s_axil_awready;
	input wire [31:0] s_axil_wdata;
	input wire [3:0] s_axil_wstrb;
	input wire s_axil_wvalid;
	output wire s_axil_wready;
	output wire [1:0] s_axil_bresp;
	output wire s_axil_bvalid;
	input wire s_axil_bready;
	input wire [ADDR_W - 1:0] s_axil_araddr;
	input wire s_axil_arvalid;
	output wire s_axil_arready;
	output wire [31:0] s_axil_rdata;
	output wire [1:0] s_axil_rresp;
	output wire s_axil_rvalid;
	input wire s_axil_rready;
	input wire [PIX_W - 1:0] s_axis_tdata;
	input wire s_axis_tvalid;
	output wire s_axis_tready;
	input wire s_axis_tuser;
	input wire s_axis_tlast;
	output reg fb_we;
	output reg [15:0] fb_wx;
	output reg [15:0] fb_wy;
	output reg [PIX_W - 1:0] fb_wdata;
	output reg fb_wbuf;
	output reg gen_buf;
	output reg gen_start;
	input wire gen_done;
	input wire signed [31:0] lb_nxt_y;
	input wire lb_nxt_v;
	input wire signed [31:0] lb_o_y;
	input wire lb_o_v;
	input wire signed [31:0] lb_a_y;
	input wire lb_a_v;
	output wire lb_hold;
	output reg [15:0] cfg_in_w;
	output reg [15:0] cfg_in_h;
	output reg [15:0] cfg_out_w;
	output reg [15:0] cfg_out_h;
	output reg [31:0] cfg_step_x;
	output reg [31:0] cfg_step_y;
	output reg signed [31:0] cfg_offs_x;
	output reg signed [31:0] cfg_offs_y;
	output wire ext_wr;
	output wire [ADDR_W - 1:0] ext_waddr;
	output wire [31:0] ext_wdata;
	output wire ext_rd;
	output wire [ADDR_W - 1:0] ext_raddr;
	input wire [31:0] ext_rdata;
	wire reg_wr;
	wire reg_rd;
	wire [ADDR_W - 1:0] reg_waddr;
	wire [ADDR_W - 1:0] reg_raddr;
	wire [31:0] reg_wdata;
	wire [31:0] reg_rdata;
	wire [3:0] reg_wstrb;
	axil_regbus #(
		.ADDR_W(ADDR_W),
		.DATA_W(32)
	) u_axil(
		.clk(clk),
		.rst_n(rst_n),
		.s_axil_awaddr(s_axil_awaddr),
		.s_axil_awvalid(s_axil_awvalid),
		.s_axil_awready(s_axil_awready),
		.s_axil_wdata(s_axil_wdata),
		.s_axil_wstrb(s_axil_wstrb),
		.s_axil_wvalid(s_axil_wvalid),
		.s_axil_wready(s_axil_wready),
		.s_axil_bresp(s_axil_bresp),
		.s_axil_bvalid(s_axil_bvalid),
		.s_axil_bready(s_axil_bready),
		.s_axil_araddr(s_axil_araddr),
		.s_axil_arvalid(s_axil_arvalid),
		.s_axil_arready(s_axil_arready),
		.s_axil_rdata(s_axil_rdata),
		.s_axil_rresp(s_axil_rresp),
		.s_axil_rvalid(s_axil_rvalid),
		.s_axil_rready(s_axil_rready),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(reg_rdata)
	);
	function automatic [ADDR_W - 1:0] sv2v_cast_8FFD8;
		input reg [ADDR_W - 1:0] inp;
		sv2v_cast_8FFD8 = inp;
	endfunction
	localparam [ADDR_W - 1:0] EXT_BASE = sv2v_cast_8FFD8('h40);
	reg [1:0] state;
	reg cap_buf;
	reg gen_busy;
	reg [15:0] rows_rcvd;
	reg lb_run;
	reg enable;
	reg st_done;
	reg st_sof_err;
	reg st_eol_err;
	reg [31:0] frame_cnt;
	reg set_sof_err;
	reg set_eol_err;
	reg set_done;
	wire wr_common = reg_wr && (reg_waddr < EXT_BASE);
	wire [5:0] widx = reg_waddr[7:2];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			enable <= 1'b0;
			cfg_in_w <= 16'd1;
			cfg_in_h <= 16'd1;
			cfg_out_w <= 16'd1;
			cfg_out_h <= 16'd1;
			cfg_step_x <= 32'h00010000;
			cfg_step_y <= 32'h00010000;
			cfg_offs_x <= 1'sb0;
			cfg_offs_y <= 1'sb0;
			st_done <= 1'b0;
			st_sof_err <= 1'b0;
			st_eol_err <= 1'b0;
		end
		else begin
			if (wr_common)
				case (widx)
					6'h00: enable <= reg_wdata[0];
					6'h01: begin
						if (reg_wdata[1])
							st_done <= 1'b0;
						if (reg_wdata[2])
							st_sof_err <= 1'b0;
						if (reg_wdata[3])
							st_eol_err <= 1'b0;
					end
					6'h02: begin
						cfg_in_w <= reg_wdata[15:0];
						cfg_in_h <= reg_wdata[31:16];
					end
					6'h03: begin
						cfg_out_w <= reg_wdata[15:0];
						cfg_out_h <= reg_wdata[31:16];
					end
					6'h04: cfg_step_x <= reg_wdata;
					6'h05: cfg_step_y <= reg_wdata;
					6'h06: cfg_offs_x <= reg_wdata;
					6'h07: cfg_offs_y <= reg_wdata;
					default:
						;
				endcase
			if (set_done)
				st_done <= 1'b1;
			if (set_sof_err)
				st_sof_err <= 1'b1;
			if (set_eol_err)
				st_eol_err <= 1'b1;
		end
	assign ext_wr = reg_wr && (reg_waddr >= EXT_BASE);
	assign ext_waddr = reg_waddr;
	assign ext_raddr = reg_raddr;
	assign ext_wdata = reg_wdata;
	assign ext_rd = reg_rd && (reg_raddr >= EXT_BASE);
	reg [31:0] common_rdata;
	reg rd_ext_q;
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			common_rdata <= 1'sb0;
			rd_ext_q <= 1'b0;
		end
		else if (reg_rd) begin
			rd_ext_q <= reg_raddr >= EXT_BASE;
			case (reg_raddr[7:2])
				6'h00: common_rdata <= {31'd0, enable};
				6'h01: common_rdata <= {26'd0, gen_busy, state == 2'd1, st_eol_err, st_sof_err, st_done, (state != 2'd0) || gen_busy};
				6'h02: common_rdata <= {cfg_in_h, cfg_in_w};
				6'h03: common_rdata <= {cfg_out_h, cfg_out_w};
				6'h04: common_rdata <= cfg_step_x;
				6'h05: common_rdata <= cfg_step_y;
				6'h06: common_rdata <= cfg_offs_x;
				6'h07: common_rdata <= cfg_offs_y;
				6'h08: common_rdata <= frame_cnt;
				6'h09: common_rdata <= IP_ID;
				6'h0a: common_rdata <= CAPS;
				6'h0b: common_rdata <= {sv2v_cast_16_signed(MAX_H), sv2v_cast_16_signed(MAX_W)};
				default: common_rdata <= 1'sb0;
			endcase
		end
	assign reg_rdata = (rd_ext_q ? ext_rdata : common_rdata);
	localparam [0:0] LB = LB_ROWS > 0;
	reg [15:0] cx;
	reg [15:0] cy;
	reg started;
	function automatic [15:0] lb_row;
		input reg signed [31:0] y;
		input reg signed [31:0] add;
		reg signed [31:0] r;
		begin
			r = (((y + LB_RND) >>> 16) - LB_CTR) + add;
			if (r < 0)
				lb_row = 16'd0;
			else if (r > ($signed({16'd0, cfg_in_h}) - 1))
				lb_row = cfg_in_h - 16'd1;
			else
				lb_row = r[15:0];
		end
	endfunction
	reg [15:0] lb_need;
	reg [15:0] lb_low;
	reg lb_row_ok;
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	always @(lb_low or cy or started or cfg_in_h or lb_run or lb_nxt_y or cfg_in_h or cfg_in_h or lb_nxt_v or lb_o_y or cfg_in_h or cfg_in_h or lb_o_v or lb_a_y or cfg_in_h or cfg_in_h or lb_a_v or lb_nxt_y or cfg_in_h or cfg_in_h or _sv2v_0) begin
		if (_sv2v_0)
			;
		lb_need = lb_row(lb_nxt_y, LB_TAPS - 1);
		if (lb_a_v)
			lb_low = lb_row(lb_a_y, 0);
		else if (lb_o_v)
			lb_low = lb_row(lb_o_y, 0);
		else if (lb_nxt_v)
			lb_low = lb_row(lb_nxt_y, 0);
		else
			lb_low = (lb_run ? cfg_in_h : 16'd0);
		lb_row_ok = !LB || (sv2v_cast_32((started ? cy : 16'd0)) < (sv2v_cast_32(lb_low) + LB_ROWS));
	end
	assign lb_hold = (LB && lb_nxt_v) && (rows_rcvd <= lb_need);
	assign s_axis_tready = (state == 2'd1) && lb_row_ok;
	wire restart = s_axis_tuser && (!LB || !started);
	wire beat = s_axis_tvalid && s_axis_tready;
	wire [15:0] px = (restart ? 16'd0 : cx);
	wire [15:0] py = (restart ? 16'd0 : cy);
	wire accept = s_axis_tuser || started;
	wire last_x = px == (cfg_in_w - 16'd1);
	wire last_px = last_x && (py == (cfg_in_h - 16'd1));
	wire gen_free = !gen_busy || gen_done;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= 2'd0;
			cx <= 1'sb0;
			cy <= 1'sb0;
			started <= 1'b0;
			cap_buf <= 1'b0;
			gen_buf <= 1'b0;
			gen_busy <= 1'b0;
			rows_rcvd <= 1'sb0;
			lb_run <= 1'b0;
			fb_we <= 1'b0;
			fb_wx <= 1'sb0;
			fb_wy <= 1'sb0;
			fb_wdata <= 1'sb0;
			fb_wbuf <= 1'b0;
			gen_start <= 1'b0;
			set_sof_err <= 1'b0;
			set_eol_err <= 1'b0;
			set_done <= 1'b0;
			frame_cnt <= 1'sb0;
		end
		else begin
			fb_we <= 1'b0;
			gen_start <= 1'b0;
			set_sof_err <= 1'b0;
			set_eol_err <= 1'b0;
			set_done <= 1'b0;
			if (gen_start)
				lb_run <= 1'b0;
			else if (lb_nxt_v)
				lb_run <= 1'b1;
			if (gen_done) begin
				gen_busy <= 1'b0;
				frame_cnt <= frame_cnt + 32'd1;
				set_done <= 1'b1;
			end
			case (state)
				2'd0: begin
					started <= 1'b0;
					if (enable && (!LB || gen_free))
						state <= 2'd1;
				end
				2'd1:
					if (beat) begin
						if ((s_axis_tuser && started) && ((cx != 0) || (cy != 0)))
							set_sof_err <= 1'b1;
						if (!accept)
							set_sof_err <= 1'b1;
						else begin
							fb_we <= 1'b1;
							fb_wx <= px;
							fb_wy <= py;
							fb_wdata <= s_axis_tdata;
							fb_wbuf <= cap_buf;
							if (s_axis_tlast != last_x)
								set_eol_err <= 1'b1;
							if (LB && !started) begin
								rows_rcvd <= 1'sb0;
								gen_buf <= cap_buf;
								gen_busy <= 1'b1;
								gen_start <= 1'b1;
							end
							if (last_x)
								rows_rcvd <= py + 16'd1;
							if (last_px) begin
								started <= 1'b0;
								cx <= 1'sb0;
								cy <= 1'sb0;
								if (LB)
									state <= 2'd2;
								else if (gen_free) begin
									gen_buf <= cap_buf;
									gen_busy <= 1'b1;
									gen_start <= 1'b1;
									if (NBUF == 2) begin
										cap_buf <= !cap_buf;
										state <= (enable ? 2'd1 : 2'd0);
									end
									else
										state <= 2'd2;
								end
								else
									state <= 2'd3;
							end
							else begin
								started <= 1'b1;
								if (last_x) begin
									cx <= 1'sb0;
									cy <= py + 16'd1;
								end
								else begin
									cx <= px + 16'd1;
									cy <= py;
								end
							end
						end
					end
					else if (!enable && !started)
						state <= 2'd0;
				2'd2:
					if (gen_free) begin
						if (enable)
							state <= 2'd1;
						else
							state <= 2'd0;
					end
				2'd3:
					if (gen_free) begin
						gen_buf <= cap_buf;
						gen_busy <= 1'b1;
						gen_start <= 1'b1;
						cap_buf <= !cap_buf;
						if (enable)
							state <= 2'd1;
						else
							state <= 2'd0;
					end
				default: state <= 2'd0;
			endcase
		end
	initial _sv2v_0 = 0;
endmodule