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
module scaler_dda (
	clk,
	rst_n,
	start,
	adv,
	hold,
	out_w,
	out_h,
	step_x,
	step_y,
	offs_x,
	offs_y,
	busy,
	nxt_y,
	o_valid,
	o_x,
	o_y,
	o_sof,
	o_eol,
	o_eof
);
	input wire clk;
	input wire rst_n;
	input wire start;
	input wire adv;
	input wire hold;
	input wire [15:0] out_w;
	input wire [15:0] out_h;
	input wire [31:0] step_x;
	input wire [31:0] step_y;
	input wire signed [31:0] offs_x;
	input wire signed [31:0] offs_y;
	output reg busy;
	output wire signed [31:0] nxt_y;
	output reg o_valid;
	output reg signed [31:0] o_x;
	output reg signed [31:0] o_y;
	output reg o_sof;
	output reg o_eol;
	output reg o_eof;
	reg [15:0] ox;
	reg [15:0] oy;
	reg signed [31:0] ax;
	reg signed [31:0] ay;
	wire last_col = ox == (out_w - 16'd1);
	wire last_row = oy == (out_h - 16'd1);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			busy <= 1'b0;
			ox <= 1'sb0;
			oy <= 1'sb0;
			ax <= 1'sb0;
			ay <= 1'sb0;
			o_valid <= 1'b0;
			o_x <= 1'sb0;
			o_y <= 1'sb0;
			o_sof <= 1'b0;
			o_eol <= 1'b0;
			o_eof <= 1'b0;
		end
		else if (start) begin
			busy <= 1'b1;
			ox <= 1'sb0;
			oy <= 1'sb0;
			ax <= offs_x;
			ay <= offs_y;
			o_valid <= 1'b0;
		end
		else if (adv) begin
			o_valid <= busy && !hold;
			if (busy && !hold) begin
				o_x <= ax;
				o_y <= ay;
				o_sof <= (ox == 16'd0) && (oy == 16'd0);
				o_eol <= last_col;
				o_eof <= last_col && last_row;
				if (last_col) begin
					ox <= 1'sb0;
					ax <= offs_x;
					ay <= ay + $signed(step_y);
					oy <= oy + 16'd1;
					if (last_row)
						busy <= 1'b0;
				end
				else begin
					ox <= ox + 16'd1;
					ax <= ax + $signed(step_x);
				end
			end
		end
	assign nxt_y = ay;
endmodule
module banked_framebuf (
	clk,
	wr_en,
	wr_x,
	wr_y,
	wr_data,
	wr_buf,
	rd_adv,
	rd_buf,
	rd_x0,
	rd_y0,
	img_w,
	img_h,
	rd_win
);
	reg _sv2v_0;
	parameter signed [31:0] PIX_W = 24;
	parameter signed [31:0] TAPS = 4;
	parameter signed [31:0] MAX_W = 1920;
	parameter signed [31:0] MAX_H = 1080;
	parameter signed [31:0] NBUF = 1;
	parameter signed [31:0] RING = 0;
	input wire clk;
	input wire wr_en;
	input wire [15:0] wr_x;
	input wire [15:0] wr_y;
	input wire [PIX_W - 1:0] wr_data;
	input wire wr_buf;
	input wire rd_adv;
	input wire rd_buf;
	input wire signed [17:0] rd_x0;
	input wire signed [17:0] rd_y0;
	input wire [15:0] img_w;
	input wire [15:0] img_h;
	output reg [((TAPS * TAPS) * PIX_W) - 1:0] rd_win;
	function automatic signed [31:0] pow2ceil;
		input reg signed [31:0] v;
		reg signed [31:0] p;
		begin
			p = 1;
			while (p < v) p = p * 2;
			pow2ceil = p;
		end
	endfunction
	localparam signed [31:0] B = pow2ceil(TAPS);
	localparam signed [31:0] LB = $clog2(B);
	localparam signed [31:0] SELW = (LB == 0 ? 1 : LB);
	localparam signed [31:0] BW = ((MAX_W + B) - 1) / B;
	localparam signed [31:0] SROWS = (RING > 0 ? RING : MAX_H);
	localparam signed [31:0] BH = ((SROWS + B) - 1) / B;
	localparam signed [31:0] DEPTH = BW * BH;
	localparam signed [31:0] DALL = DEPTH * NBUF;
	localparam signed [31:0] AW = (DALL <= 2 ? 1 : $clog2(DALL));
	initial begin
		if ((NBUF < 1) || (NBUF > 2)) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_anisotropic/src/../../banked_framebuf/src/banked_framebuf.sv:71:31 - banked_framebuf.<unnamed_block>.<unnamed_block>\n msg: ", $time, "banked_framebuf: NBUF must be 1 or 2");
			$finish(1);
		end
		if ((RING > 0) && ((RING < B) || ((RING & (RING - 1)) != 0))) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_anisotropic/src/../../banked_framebuf/src/banked_framebuf.sv:73:7 - banked_framebuf.<unnamed_block>.<unnamed_block>\n msg: ", $time, "banked_framebuf: RING must be a power of two >= %0d", B);
			$finish(1);
		end
	end
	function automatic signed [31:0] prow;
		input reg signed [31:0] y;
		prow = (RING > 0 ? y % (RING > 0 ? RING : 1) : y);
	endfunction
	function automatic signed [31:0] boff;
		input reg b;
		boff = ((NBUF == 2) && b ? DEPTH : 0);
	endfunction
	function automatic [15:0] clampc;
		input reg signed [17:0] v;
		input reg [15:0] size;
		if (v < 0)
			clampc = 16'd0;
		else if (v > ($signed({2'b00, size}) - 18'sd1))
			clampc = size - 16'd1;
		else
			clampc = v[15:0];
	endfunction
	reg [SELW - 1:0] wbx;
	reg [SELW - 1:0] wby;
	reg [AW - 1:0] waddr;
	reg wen;
	reg [PIX_W - 1:0] wdat;
	function automatic [SELW - 1:0] sv2v_cast_3C5FC;
		input reg [SELW - 1:0] inp;
		sv2v_cast_3C5FC = inp;
	endfunction
	function automatic [AW - 1:0] sv2v_cast_DE851;
		input reg [AW - 1:0] inp;
		sv2v_cast_DE851 = inp;
	endfunction
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(posedge clk) begin
		wen <= wr_en;
		wbx <= sv2v_cast_3C5FC(wr_x % B);
		wby <= sv2v_cast_3C5FC(wr_y % B);
		waddr <= sv2v_cast_DE851((boff(wr_buf) + ((prow(sv2v_cast_32_signed(wr_y)) / B) * BW)) + (wr_x / B));
		wdat <= wr_data;
	end
	reg [15:0] lo_x;
	reg [15:0] hi_x;
	reg [15:0] lo_y;
	reg [15:0] hi_y;
	reg [15:0] bcx [0:B - 1];
	reg [15:0] bcy [0:B - 1];
	reg [SELW - 1:0] tsx [0:TAPS - 1];
	reg [SELW - 1:0] tsy [0:TAPS - 1];
	function automatic signed [17:0] sv2v_cast_18_signed;
		input reg signed [17:0] inp;
		sv2v_cast_18_signed = inp;
	endfunction
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		lo_x = clampc(rd_x0, img_w);
		hi_x = clampc(rd_x0 + sv2v_cast_18_signed(TAPS - 1), img_w);
		lo_y = clampc(rd_y0, img_h);
		hi_y = clampc(rd_y0 + sv2v_cast_18_signed(TAPS - 1), img_h);
		begin : sv2v_autoblock_1
			reg signed [31:0] b;
			for (b = 0; b < B; b = b + 1)
				begin : sv2v_autoblock_2
					reg [15:0] c;
					c = lo_x + sv2v_cast_16_signed((b - sv2v_cast_32_signed(lo_x % B)) & (B - 1));
					bcx[b] = (c > hi_x ? hi_x : c);
					c = lo_y + sv2v_cast_16_signed((b - sv2v_cast_32_signed(lo_y % B)) & (B - 1));
					bcy[b] = (c > hi_y ? hi_y : c);
				end
		end
		begin : sv2v_autoblock_3
			reg signed [31:0] t;
			for (t = 0; t < TAPS; t = t + 1)
				begin
					tsx[t] = sv2v_cast_3C5FC(clampc(rd_x0 + sv2v_cast_18_signed(t), img_w) % B);
					tsy[t] = sv2v_cast_3C5FC(clampc(rd_y0 + sv2v_cast_18_signed(t), img_h) % B);
				end
		end
	end
	reg [AW - 1:0] colpart_q [0:B - 1];
	reg [AW - 1:0] rowpart_q [0:B - 1];
	reg [SELW - 1:0] tsx_q [0:TAPS - 1];
	reg [SELW - 1:0] tsy_q [0:TAPS - 1];
	reg [SELW - 1:0] tsx_qq [0:TAPS - 1];
	reg [SELW - 1:0] tsy_qq [0:TAPS - 1];
	function automatic signed [AW - 1:0] sv2v_cast_DE851_signed;
		input reg signed [AW - 1:0] inp;
		sv2v_cast_DE851_signed = inp;
	endfunction
	always @(posedge clk)
		if (rd_adv) begin
			begin : sv2v_autoblock_4
				reg signed [31:0] b;
				for (b = 0; b < B; b = b + 1)
					begin
						colpart_q[b] <= sv2v_cast_DE851(bcx[b] / B);
						rowpart_q[b] <= sv2v_cast_DE851_signed(boff(rd_buf) + ((prow(sv2v_cast_32_signed(bcy[b])) / B) * BW));
					end
			end
			begin : sv2v_autoblock_5
				reg signed [31:0] t;
				for (t = 0; t < TAPS; t = t + 1)
					begin
						tsx_q[t] <= tsx[t];
						tsy_q[t] <= tsy[t];
						tsx_qq[t] <= tsx_q[t];
						tsy_qq[t] <= tsy_q[t];
					end
			end
		end
	reg [PIX_W - 1:0] bank_q [0:B - 1][0:B - 1];
	genvar _gv_gy_1;
	function automatic signed [SELW - 1:0] sv2v_cast_3C5FC_signed;
		input reg signed [SELW - 1:0] inp;
		sv2v_cast_3C5FC_signed = inp;
	endfunction
	generate
		for (_gv_gy_1 = 0; _gv_gy_1 < B; _gv_gy_1 = _gv_gy_1 + 1) begin : g_by
			localparam gy = _gv_gy_1;
			genvar _gv_gx_1;
			for (_gv_gx_1 = 0; _gv_gx_1 < B; _gv_gx_1 = _gv_gx_1 + 1) begin : g_bx
				localparam gx = _gv_gx_1;
				reg [PIX_W - 1:0] mem [0:DALL - 1];
				always @(posedge clk) begin
					if ((wen && (wbx == sv2v_cast_3C5FC_signed(gx))) && (wby == sv2v_cast_3C5FC_signed(gy)))
						mem[waddr] <= wdat;
					if (rd_adv)
						bank_q[gy][gx] <= mem[rowpart_q[gy] + colpart_q[gx]];
				end
			end
		end
	endgenerate
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_6
			reg signed [31:0] j;
			for (j = 0; j < TAPS; j = j + 1)
				begin : sv2v_autoblock_7
					reg signed [31:0] i;
					for (i = 0; i < TAPS; i = i + 1)
						rd_win[((j * TAPS) + i) * PIX_W+:PIX_W] = bank_q[tsy_qq[j]][tsx_qq[i]];
				end
		end
	end
	initial _sv2v_0 = 0;
endmodule
module scaler_mip (
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
	m_axis_tdata,
	m_axis_tvalid,
	m_axis_tready,
	m_axis_tuser,
	m_axis_tlast
);
	reg _sv2v_0;
	parameter signed [31:0] CHANNELS = 3;
	parameter signed [31:0] COMP_W = 8;
	parameter signed [31:0] MAX_W = 1920;
	parameter signed [31:0] MAX_H = 1080;
	parameter signed [31:0] ADDR_W = 14;
	parameter signed [31:0] LEVELS = 4;
	parameter signed [31:0] ANISO_MAX_LOG2 = 0;
	parameter signed [31:0] PHASE_BITS = 8;
	parameter [31:0] IP_ID = 32'h4d49504d;
	parameter signed [31:0] PINGPONG = 0;
	localparam signed [31:0] PIX_W = CHANNELS * COMP_W;
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
	output reg [PIX_W - 1:0] m_axis_tdata;
	output reg m_axis_tvalid;
	input wire m_axis_tready;
	output reg m_axis_tuser;
	output reg m_axis_tlast;
	function automatic signed [7:0] sv2v_cast_8_signed;
		input reg signed [7:0] inp;
		sv2v_cast_8_signed = inp;
	endfunction
	localparam [31:0] CAPS = {sv2v_cast_8_signed(PHASE_BITS), sv2v_cast_8_signed(COMP_W), sv2v_cast_8_signed(CHANNELS), sv2v_cast_8_signed(LEVELS)};
	localparam signed [31:0] ONE = 1 << PHASE_BITS;
	localparam signed [31:0] LW = (LEVELS <= 1 ? 1 : $clog2(LEVELS));
	initial begin
		if ((LEVELS < 1) || (LEVELS > 8)) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_anisotropic/src/../../scaler_mip/src/scaler_mip.sv:86:40 - scaler_mip.<unnamed_block>.<unnamed_block>\n msg: ", $time, "scaler_mip: LEVELS must be 1..8");
			$finish(1);
		end
		if ((ANISO_MAX_LOG2 < 0) || (ANISO_MAX_LOG2 > 4)) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_anisotropic/src/../../scaler_mip/src/scaler_mip.sv:88:7 - scaler_mip.<unnamed_block>.<unnamed_block>\n msg: ", $time, "scaler_mip: ANISO_MAX_LOG2 must be 0..4");
			$finish(1);
		end
	end
	reg [31:0] ext_rdata;
	wire fb_we;
	wire [15:0] fb_wx;
	wire [15:0] fb_wy;
	wire [PIX_W - 1:0] fb_wdata;
	wire fb_wbuf;
	wire gen_buf;
	wire unused_lb_hold;
	wire signed [31:0] unused_nxt_y;
	wire gen_start;
	wire gen_done;
	wire [15:0] in_w;
	wire [15:0] in_h;
	wire [15:0] out_w;
	wire [15:0] out_h;
	wire [31:0] step_x;
	wire [31:0] step_y;
	wire signed [31:0] offs_x;
	wire signed [31:0] offs_y;
	wire ext_wr;
	wire ext_rd;
	wire [ADDR_W - 1:0] ext_waddr;
	wire [ADDR_W - 1:0] ext_raddr;
	wire [31:0] ext_wdata;
	scaler_ctrl #(
		.PIX_W(PIX_W),
		.ADDR_W(ADDR_W),
		.MAX_W(MAX_W),
		.MAX_H(MAX_H),
		.IP_ID(IP_ID),
		.CAPS(CAPS),
		.NBUF((PINGPONG ? 2 : 1))
	) u_ctrl(
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
		.s_axis_tdata(s_axis_tdata),
		.s_axis_tvalid(s_axis_tvalid),
		.s_axis_tready(s_axis_tready),
		.s_axis_tuser(s_axis_tuser),
		.s_axis_tlast(s_axis_tlast),
		.fb_we(fb_we),
		.fb_wx(fb_wx),
		.fb_wy(fb_wy),
		.fb_wdata(fb_wdata),
		.fb_wbuf(fb_wbuf),
		.gen_buf(gen_buf),
		.gen_start(gen_start),
		.gen_done(gen_done),
		.lb_nxt_y(32'sd0),
		.lb_nxt_v(1'b0),
		.lb_o_y(32'sd0),
		.lb_o_v(1'b0),
		.lb_a_y(32'sd0),
		.lb_a_v(1'b0),
		.lb_hold(unused_lb_hold),
		.cfg_in_w(in_w),
		.cfg_in_h(in_h),
		.cfg_out_w(out_w),
		.cfg_out_h(out_h),
		.cfg_step_x(step_x),
		.cfg_step_y(step_y),
		.cfg_offs_x(offs_x),
		.cfg_offs_y(offs_y),
		.ext_wr(ext_wr),
		.ext_waddr(ext_waddr),
		.ext_wdata(ext_wdata),
		.ext_rd(ext_rd),
		.ext_raddr(ext_raddr),
		.ext_rdata(ext_rdata)
	);
	reg [15:0] lod;
	reg [3:0] aniso_log2_r;
	reg signed [31:0] pstep_x;
	reg signed [31:0] pstep_y;
	reg signed [31:0] pstart_x;
	reg signed [31:0] pstart_y;
	reg [15:0] lw [0:LEVELS - 1];
	reg [15:0] lh [0:LEVELS - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		lw[0] = in_w;
		lh[0] = in_h;
		begin : sv2v_autoblock_1
			reg signed [31:0] k;
			for (k = 1; k < LEVELS; k = k + 1)
				begin
					lw[k] = (lw[k - 1] > 16'd1 ? lw[k - 1] >> 1 : 16'd1);
					lh[k] = (lh[k - 1] > 16'd1 ? lh[k - 1] >> 1 : 16'd1);
				end
		end
	end
	function automatic signed [3:0] sv2v_cast_4_signed;
		input reg signed [3:0] inp;
		sv2v_cast_4_signed = inp;
	endfunction
	function automatic [7:0] sv2v_cast_8;
		input reg [7:0] inp;
		sv2v_cast_8 = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			lod <= 1'sb0;
			aniso_log2_r <= 1'sb0;
			pstep_x <= 1'sb0;
			pstep_y <= 1'sb0;
			pstart_x <= 1'sb0;
			pstart_y <= 1'sb0;
			ext_rdata <= 1'sb0;
		end
		else begin
			if (ext_wr)
				case (ext_waddr[7:0])
					8'h40: lod <= ext_wdata[15:0];
					8'h44: aniso_log2_r <= (ext_wdata[3:0] > sv2v_cast_4_signed(ANISO_MAX_LOG2) ? sv2v_cast_4_signed(ANISO_MAX_LOG2) : ext_wdata[3:0]);
					8'h48: pstep_x <= ext_wdata;
					8'h4c: pstep_y <= ext_wdata;
					8'h50: pstart_x <= ext_wdata;
					8'h54: pstart_y <= ext_wdata;
					default:
						;
				endcase
			if (ext_rd) begin
				ext_rdata <= 1'sb0;
				case (ext_raddr[7:0])
					8'h40: ext_rdata <= {16'd0, lod};
					8'h44: ext_rdata <= {28'd0, aniso_log2_r};
					8'h48: ext_rdata <= pstep_x;
					8'h4c: ext_rdata <= pstep_y;
					8'h50: ext_rdata <= pstart_x;
					8'h54: ext_rdata <= pstart_y;
					8'h58: ext_rdata <= {8'd0, sv2v_cast_8_signed(PHASE_BITS), sv2v_cast_8_signed(ANISO_MAX_LOG2), sv2v_cast_8_signed(LEVELS)};
					default: begin : sv2v_autoblock_2
						reg signed [31:0] k;
						for (k = 0; k < LEVELS; k = k + 1)
							if (ext_raddr[7:0] == sv2v_cast_8(8'h60 + (4 * k)))
								ext_rdata <= {lh[k], lw[k]};
					end
				endcase
			end
		end
	reg [LW - 1:0] lvl_a;
	reg [LW - 1:0] lvl_b;
	reg [7:0] lod_f;
	function automatic signed [LW - 1:0] sv2v_cast_4587C_signed;
		input reg signed [LW - 1:0] inp;
		sv2v_cast_4587C_signed = inp;
	endfunction
	function automatic [LW - 1:0] sv2v_cast_4587C;
		input reg [LW - 1:0] inp;
		sv2v_cast_4587C = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		if (lod[15:8] >= sv2v_cast_8_signed(LEVELS - 1)) begin
			lvl_a = sv2v_cast_4587C_signed(LEVELS - 1);
			lvl_b = sv2v_cast_4587C_signed(LEVELS - 1);
			lod_f = 8'd0;
		end
		else begin
			lvl_a = sv2v_cast_4587C(lod[15:8]);
			lvl_b = sv2v_cast_4587C(lod[15:8] + 8'd1);
			lod_f = lod[7:0];
		end
	end
	reg [1:0] gstate;
	wire adv = !m_axis_tvalid || m_axis_tready;
	reg [LW - 1:0] mip_src;
	reg [15:0] mx;
	reg [15:0] my;
	reg [1:0] mv;
	reg [15:0] mpx [0:1];
	reg [15:0] mpy [0:1];
	reg mw_en;
	reg [LW - 1:0] mw_lvl;
	reg [15:0] mw_x;
	reg [15:0] mw_y;
	reg [PIX_W - 1:0] mw_data;
	reg dda_start;
	wire [LW:0] mip_dst = mip_src + 1'b1;
	wire [15:0] dst_w = lw[mip_dst[LW - 1:0]];
	wire [15:0] dst_h = lh[mip_dst[LW - 1:0]];
	wire mip_issue = gstate == 2'd1;
	wire mip_last = (mx == (dst_w - 16'd1)) && (my == (dst_h - 16'd1));
	wire [(4 * PIX_W) - 1:0] win [0:LEVELS - 1];
	reg signed [17:0] ra_x;
	reg signed [17:0] ra_y;
	reg signed [17:0] rb_x;
	reg signed [17:0] rb_y;
	reg [PHASE_BITS - 1:0] fa_x;
	reg [PHASE_BITS - 1:0] fa_y;
	reg [PHASE_BITS - 1:0] fb_x;
	reg [PHASE_BITS - 1:0] fb_y;
	genvar _gv_k_1;
	function automatic [17:0] sv2v_cast_18;
		input reg [17:0] inp;
		sv2v_cast_18 = inp;
	endfunction
	generate
		for (_gv_k_1 = 0; _gv_k_1 < LEVELS; _gv_k_1 = _gv_k_1 + 1) begin : g_lvl
			localparam k = _gv_k_1;
			reg we;
			reg [15:0] wx;
			reg [15:0] wy;
			reg [PIX_W - 1:0] wd;
			reg wb;
			reg signed [17:0] rx;
			reg signed [17:0] ry;
			reg radv;
			always @(*) begin
				if (_sv2v_0)
					;
				if (k == 0) begin
					we = fb_we;
					wx = fb_wx;
					wy = fb_wy;
					wd = fb_wdata;
					wb = fb_wbuf;
				end
				else begin
					we = mw_en && (mw_lvl == sv2v_cast_4587C_signed(k));
					wx = mw_x;
					wy = mw_y;
					wd = mw_data;
					wb = gen_buf;
				end
				if (gstate != 2'd3) begin
					rx = sv2v_cast_18(mx) <<< 1;
					ry = sv2v_cast_18(my) <<< 1;
					radv = 1'b1;
				end
				else begin
					rx = (sv2v_cast_4587C_signed(k) == lvl_a ? ra_x : rb_x);
					ry = (sv2v_cast_4587C_signed(k) == lvl_a ? ra_y : rb_y);
					radv = adv;
				end
			end
			banked_framebuf #(
				.PIX_W(PIX_W),
				.TAPS(2),
				.MAX_W(((MAX_W >> k) > 0 ? MAX_W >> k : 1)),
				.MAX_H(((MAX_H >> k) > 0 ? MAX_H >> k : 1)),
				.NBUF((PINGPONG ? 2 : 1))
			) u_fb(
				.clk(clk),
				.wr_en(we),
				.wr_x(wx),
				.wr_y(wy),
				.wr_data(wd),
				.wr_buf(wb),
				.rd_adv(radv),
				.rd_buf(gen_buf),
				.rd_x0(rx),
				.rd_y0(ry),
				.img_w(lw[k]),
				.img_h(lh[k]),
				.rd_win(win[k])
			);
		end
	endgenerate
	reg [PIX_W - 1:0] box;
	function automatic [((COMP_W + 1) >= 0 ? COMP_W + 2 : 1 - (COMP_W + 1)) - 1:0] sv2v_cast_051FD;
		input reg [((COMP_W + 1) >= 0 ? COMP_W + 2 : 1 - (COMP_W + 1)) - 1:0] inp;
		sv2v_cast_051FD = inp;
	endfunction
	function automatic [COMP_W - 1:0] sv2v_cast_8F3CA;
		input reg [COMP_W - 1:0] inp;
		sv2v_cast_8F3CA = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_3
			reg signed [31:0] c;
			for (c = 0; c < CHANNELS; c = c + 1)
				begin : sv2v_autoblock_4
					reg [COMP_W + 1:0] s;
					s = (((sv2v_cast_051FD(win[mip_src][0 + (c * COMP_W)+:COMP_W]) + sv2v_cast_051FD(win[mip_src][(1 * PIX_W) + (c * COMP_W)+:COMP_W])) + sv2v_cast_051FD(win[mip_src][(2 * PIX_W) + (c * COMP_W)+:COMP_W])) + sv2v_cast_051FD(win[mip_src][(3 * PIX_W) + (c * COMP_W)+:COMP_W])) + 2;
					box[c * COMP_W+:COMP_W] = sv2v_cast_8F3CA(s >> 2);
				end
		end
	end
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			gstate <= 2'd0;
			mip_src <= 1'sb0;
			mx <= 1'sb0;
			my <= 1'sb0;
			mv <= 1'sb0;
			mw_en <= 1'b0;
			mw_lvl <= 1'sb0;
			mw_x <= 1'sb0;
			mw_y <= 1'sb0;
			mw_data <= 1'sb0;
			dda_start <= 1'b0;
			begin : sv2v_autoblock_5
				reg signed [31:0] i;
				for (i = 0; i < 2; i = i + 1)
					begin
						mpx[i] <= 1'sb0;
						mpy[i] <= 1'sb0;
					end
			end
		end
		else begin
			dda_start <= 1'b0;
			mw_en <= 1'b0;
			mv[0] <= mip_issue;
			mpx[0] <= mx;
			mpy[0] <= my;
			mv[1] <= mv[0];
			mpx[1] <= mpx[0];
			mpy[1] <= mpy[0];
			if (mv[1]) begin
				mw_en <= 1'b1;
				mw_lvl <= mip_dst[LW - 1:0];
				mw_x <= mpx[1];
				mw_y <= mpy[1];
				mw_data <= box;
			end
			case (gstate)
				2'd0:
					if (gen_start) begin
						mip_src <= 1'sb0;
						mx <= 1'sb0;
						my <= 1'sb0;
						if (LEVELS > 1)
							gstate <= 2'd1;
						else begin
							gstate <= 2'd3;
							dda_start <= 1'b1;
						end
					end
				2'd1:
					if (mip_last)
						gstate <= 2'd2;
					else if (mx == (dst_w - 16'd1)) begin
						mx <= 1'sb0;
						my <= my + 16'd1;
					end
					else
						mx <= mx + 16'd1;
				2'd2:
					if (((mv == 2'b00) && !mv[1]) && !mw_en) begin
						mx <= 1'sb0;
						my <= 1'sb0;
						if (sv2v_cast_32(mip_dst) < (LEVELS - 1)) begin
							mip_src <= mip_dst[LW - 1:0];
							gstate <= 2'd1;
						end
						else begin
							gstate <= 2'd3;
							dda_start <= 1'b1;
						end
					end
				2'd3:
					if (gen_done)
						gstate <= 2'd0;
				default: gstate <= 2'd0;
			endcase
		end
	wire d_valid;
	wire d_sof;
	wire d_eol;
	wire d_eof;
	wire d_busy;
	wire signed [31:0] d_x;
	wire signed [31:0] d_y;
	reg [3:0] pn;
	reg signed [31:0] off_x;
	reg signed [31:0] off_y;
	wire [3:0] np_last = sv2v_cast_4_signed((1 << aniso_log2_r) - 1);
	wire probe_last = pn == np_last;
	wire dda_adv = (adv && (gstate == 2'd3)) && (!d_valid || probe_last);
	scaler_dda u_dda(
		.clk(clk),
		.rst_n(rst_n),
		.start(dda_start),
		.adv(dda_adv),
		.hold(1'b0),
		.nxt_y(unused_nxt_y),
		.out_w(out_w),
		.out_h(out_h),
		.step_x(step_x),
		.step_y(step_y),
		.offs_x(offs_x),
		.offs_y(offs_y),
		.busy(d_busy),
		.o_valid(d_valid),
		.o_x(d_x),
		.o_y(d_y),
		.o_sof(d_sof),
		.o_eol(d_eol),
		.o_eof(d_eof)
	);
	reg p_valid;
	reg p_first;
	reg p_last;
	reg [2:0] p_flags;
	reg signed [31:0] p_x;
	reg signed [31:0] p_y;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			p_valid <= 1'b0;
			p_first <= 1'b0;
			p_last <= 1'b0;
			p_flags <= 1'sb0;
			p_x <= 1'sb0;
			p_y <= 1'sb0;
			pn <= 1'sb0;
			off_x <= 1'sb0;
			off_y <= 1'sb0;
		end
		else if (dda_start) begin
			p_valid <= 1'b0;
			pn <= 1'sb0;
			off_x <= pstart_x;
			off_y <= pstart_y;
		end
		else if (adv) begin
			p_valid <= d_valid && (gstate == 2'd3);
			if (d_valid && (gstate == 2'd3)) begin
				p_x <= d_x + off_x;
				p_y <= d_y + off_y;
				p_first <= pn == 4'd0;
				p_last <= probe_last;
				p_flags <= {d_eof, d_eol, d_sof};
				if (probe_last) begin
					pn <= 1'sb0;
					off_x <= pstart_x;
					off_y <= pstart_y;
				end
				else begin
					pn <= pn + 4'd1;
					off_x <= off_x + pstep_x;
					off_y <= off_y + pstep_y;
				end
			end
		end
	localparam signed [31:0] RND = 32'sd1 <<< ((16 - PHASE_BITS) - 1);
	reg signed [31:0] ua_x;
	reg signed [31:0] ua_y;
	reg signed [31:0] ub_x;
	reg signed [31:0] ub_y;
	function automatic signed [17:0] sv2v_cast_18_signed;
		input reg signed [17:0] inp;
		sv2v_cast_18_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		ua_x = (((p_x + 32'sh00008000) >>> lvl_a) - 32'sh00008000) + RND;
		ua_y = (((p_y + 32'sh00008000) >>> lvl_a) - 32'sh00008000) + RND;
		ub_x = (((p_x + 32'sh00008000) >>> lvl_b) - 32'sh00008000) + RND;
		ub_y = (((p_y + 32'sh00008000) >>> lvl_b) - 32'sh00008000) + RND;
		ra_x = sv2v_cast_18_signed(ua_x >>> 16);
		fa_x = ua_x[15-:PHASE_BITS];
		ra_y = sv2v_cast_18_signed(ua_y >>> 16);
		fa_y = ua_y[15-:PHASE_BITS];
		rb_x = sv2v_cast_18_signed(ub_x >>> 16);
		fb_x = ub_x[15-:PHASE_BITS];
		rb_y = sv2v_cast_18_signed(ub_y >>> 16);
		fb_y = ub_y[15-:PHASE_BITS];
	end
	localparam signed [31:0] NST = 8;
	localparam signed [31:0] HW = (COMP_W + PHASE_BITS) + 1;
	localparam signed [31:0] VW = (HW + PHASE_BITS) + 1;
	localparam signed [31:0] BW3 = COMP_W + 9;
	reg [7:0] v_q;
	reg [4:0] f_q [0:7];
	reg [PHASE_BITS - 1:0] fr_q [0:1][0:3];
	reg [PHASE_BITS:0] wx_q [0:1][0:1];
	reg [PHASE_BITS:0] wy_d [0:2][0:1][0:1];
	reg [(4 * PIX_W) - 1:0] wa_q;
	reg [(4 * PIX_W) - 1:0] wb_q;
	reg [HW - 1:0] p1_q [0:1][0:CHANNELS - 1][0:3];
	reg [HW - 1:0] r1_q [0:1][0:CHANNELS - 1][0:1];
	reg [VW - 1:0] p2_q [0:1][0:CHANNELS - 1][0:1];
	reg [COMP_W - 1:0] sab_q [0:1][0:CHANNELS - 1];
	reg [BW3 - 1:0] p3_q [0:1][0:CHANNELS - 1];
	reg m_eof;
	localparam signed [31:0] ACW = COMP_W + 5;
	reg [ACW - 1:0] acc_q [0:CHANNELS - 1];
	reg [ACW - 1:0] acc_c [0:CHANNELS - 1];
	reg [PIX_W - 1:0] avg_c;
	function automatic signed [BW3 - 1:0] sv2v_cast_7A770_signed;
		input reg signed [BW3 - 1:0] inp;
		sv2v_cast_7A770_signed = inp;
	endfunction
	function automatic [ACW - 1:0] sv2v_cast_11AF3;
		input reg [ACW - 1:0] inp;
		sv2v_cast_11AF3 = inp;
	endfunction
	function automatic signed [ACW - 1:0] sv2v_cast_11AF3_signed;
		input reg signed [ACW - 1:0] inp;
		sv2v_cast_11AF3_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_6
			reg signed [31:0] c;
			for (c = 0; c < CHANNELS; c = c + 1)
				begin : sv2v_autoblock_7
					reg [BW3 - 1:0] t;
					t = (p3_q[0][c] + p3_q[1][c]) + sv2v_cast_7A770_signed(128);
					acc_c[c] = (f_q[7][4] ? {ACW {1'sb0}} : acc_q[c]) + sv2v_cast_11AF3(t >> 8);
					avg_c[c * COMP_W+:COMP_W] = sv2v_cast_8F3CA((acc_c[c] + sv2v_cast_11AF3_signed((1 << aniso_log2_r) >> 1)) >> aniso_log2_r);
				end
		end
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			v_q <= 1'sb0;
			begin : sv2v_autoblock_8
				reg signed [31:0] k;
				for (k = 0; k < NST; k = k + 1)
					f_q[k] <= 1'sb0;
			end
			begin : sv2v_autoblock_9
				reg signed [31:0] c;
				for (c = 0; c < CHANNELS; c = c + 1)
					acc_q[c] <= 1'sb0;
			end
			m_axis_tvalid <= 1'b0;
			m_axis_tdata <= 1'sb0;
			m_axis_tuser <= 1'b0;
			m_axis_tlast <= 1'b0;
			m_eof <= 1'b0;
		end
		else if (dda_start)
			v_q <= 1'sb0;
		else if (adv) begin
			v_q[0] <= p_valid;
			f_q[0] <= {p_first, p_last, p_flags};
			begin : sv2v_autoblock_10
				reg signed [31:0] k;
				for (k = 1; k < NST; k = k + 1)
					begin
						v_q[k] <= v_q[k - 1];
						f_q[k] <= f_q[k - 1];
					end
			end
			if (v_q[7]) begin : sv2v_autoblock_11
				reg signed [31:0] c;
				for (c = 0; c < CHANNELS; c = c + 1)
					acc_q[c] <= acc_c[c];
			end
			m_axis_tvalid <= v_q[7] && f_q[7][3];
			m_axis_tdata <= avg_c;
			{m_eof, m_axis_tlast, m_axis_tuser} <= f_q[7][2:0];
		end
	function automatic signed [((PHASE_BITS + 0) >= 0 ? PHASE_BITS + 1 : 1 - (PHASE_BITS + 0)) - 1:0] sv2v_cast_6D767_signed;
		input reg signed [((PHASE_BITS + 0) >= 0 ? PHASE_BITS + 1 : 1 - (PHASE_BITS + 0)) - 1:0] inp;
		sv2v_cast_6D767_signed = inp;
	endfunction
	function automatic [((PHASE_BITS + 0) >= 0 ? PHASE_BITS + 1 : 1 - (PHASE_BITS + 0)) - 1:0] sv2v_cast_6D767;
		input reg [((PHASE_BITS + 0) >= 0 ? PHASE_BITS + 1 : 1 - (PHASE_BITS + 0)) - 1:0] inp;
		sv2v_cast_6D767 = inp;
	endfunction
	function automatic [HW - 1:0] sv2v_cast_1E4F8;
		input reg [HW - 1:0] inp;
		sv2v_cast_1E4F8 = inp;
	endfunction
	function automatic [VW - 1:0] sv2v_cast_57546;
		input reg [VW - 1:0] inp;
		sv2v_cast_57546 = inp;
	endfunction
	function automatic signed [VW - 1:0] sv2v_cast_57546_signed;
		input reg signed [VW - 1:0] inp;
		sv2v_cast_57546_signed = inp;
	endfunction
	function automatic [BW3 - 1:0] sv2v_cast_7A770;
		input reg [BW3 - 1:0] inp;
		sv2v_cast_7A770 = inp;
	endfunction
	always @(posedge clk) begin : sv2v_autoblock_12
		reg [(4 * PIX_W) - 1:0] ws;
		if (adv) begin
			fr_q[0][0] <= fa_x;
			fr_q[0][1] <= fa_y;
			fr_q[0][2] <= fb_x;
			fr_q[0][3] <= fb_y;
			begin : sv2v_autoblock_13
				reg signed [31:0] i;
				for (i = 0; i < 4; i = i + 1)
					fr_q[1][i] <= fr_q[0][i];
			end
			wa_q <= win[lvl_a];
			wb_q <= win[lvl_b];
			begin : sv2v_autoblock_14
				reg signed [31:0] l;
				for (l = 0; l < 2; l = l + 1)
					begin
						wx_q[l][0] <= sv2v_cast_6D767_signed(ONE) - sv2v_cast_6D767(fr_q[1][2 * l]);
						wx_q[l][1] <= sv2v_cast_6D767(fr_q[1][2 * l]);
						wy_d[0][l][0] <= sv2v_cast_6D767_signed(ONE) - sv2v_cast_6D767(fr_q[1][(2 * l) + 1]);
						wy_d[0][l][1] <= sv2v_cast_6D767(fr_q[1][(2 * l) + 1]);
						begin : sv2v_autoblock_15
							reg signed [31:0] d;
							for (d = 1; d < 3; d = d + 1)
								begin
									wy_d[d][l][0] <= wy_d[d - 1][l][0];
									wy_d[d][l][1] <= wy_d[d - 1][l][1];
								end
						end
					end
			end
			begin : sv2v_autoblock_16
				reg signed [31:0] c;
				for (c = 0; c < CHANNELS; c = c + 1)
					begin : sv2v_autoblock_17
						reg signed [31:0] l;
						for (l = 0; l < 2; l = l + 1)
							begin
								ws = (l == 0 ? wa_q : wb_q);
								begin : sv2v_autoblock_18
									reg signed [31:0] t;
									for (t = 0; t < 4; t = t + 1)
										p1_q[l][c][t] <= sv2v_cast_1E4F8(ws[(t * PIX_W) + (c * COMP_W)+:COMP_W]) * sv2v_cast_1E4F8(wx_q[l][t % 2]);
								end
								r1_q[l][c][0] <= p1_q[l][c][0] + p1_q[l][c][1];
								r1_q[l][c][1] <= p1_q[l][c][2] + p1_q[l][c][3];
								p2_q[l][c][0] <= sv2v_cast_57546(r1_q[l][c][0]) * sv2v_cast_57546(wy_d[2][l][0]);
								p2_q[l][c][1] <= sv2v_cast_57546(r1_q[l][c][1]) * sv2v_cast_57546(wy_d[2][l][1]);
								sab_q[l][c] <= sv2v_cast_8F3CA(((p2_q[l][c][0] + p2_q[l][c][1]) + sv2v_cast_57546_signed((ONE * ONE) / 2)) >> (2 * PHASE_BITS));
								p3_q[l][c] <= sv2v_cast_7A770(sab_q[l][c]) * (l == 0 ? sv2v_cast_7A770(9'd256 - lod_f) : sv2v_cast_7A770(lod_f));
							end
					end
			end
		end
	end
	assign gen_done = (m_axis_tvalid && m_axis_tready) && m_eof;
	initial _sv2v_0 = 0;
endmodule
module scaler_anisotropic (
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
	m_axis_tdata,
	m_axis_tvalid,
	m_axis_tready,
	m_axis_tuser,
	m_axis_tlast
);
	parameter signed [31:0] CHANNELS = 3;
	parameter signed [31:0] COMP_W = 8;
	parameter signed [31:0] MAX_W = 1920;
	parameter signed [31:0] MAX_H = 1080;
	parameter signed [31:0] ADDR_W = 14;
	parameter signed [31:0] LEVELS = 5;
	parameter signed [31:0] PHASE_BITS = 8;
	parameter signed [31:0] PINGPONG = 0;
	localparam signed [31:0] PIX_W = CHANNELS * COMP_W;
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
	output wire [PIX_W - 1:0] m_axis_tdata;
	output wire m_axis_tvalid;
	input wire m_axis_tready;
	output wire m_axis_tuser;
	output wire m_axis_tlast;
	scaler_mip #(
		.PINGPONG(PINGPONG),
		.CHANNELS(CHANNELS),
		.COMP_W(COMP_W),
		.MAX_W(MAX_W),
		.MAX_H(MAX_H),
		.ADDR_W(ADDR_W),
		.LEVELS(LEVELS),
		.ANISO_MAX_LOG2(4),
		.PHASE_BITS(PHASE_BITS),
		.IP_ID(32'h414e4953)
	) u_core(
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
		.s_axis_tdata(s_axis_tdata),
		.s_axis_tvalid(s_axis_tvalid),
		.s_axis_tready(s_axis_tready),
		.s_axis_tuser(s_axis_tuser),
		.s_axis_tlast(s_axis_tlast),
		.m_axis_tdata(m_axis_tdata),
		.m_axis_tvalid(m_axis_tvalid),
		.m_axis_tready(m_axis_tready),
		.m_axis_tuser(m_axis_tuser),
		.m_axis_tlast(m_axis_tlast)
	);
endmodule