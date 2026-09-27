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
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_lanczos/src/../../banked_framebuf/src/banked_framebuf.sv:71:31 - banked_framebuf.<unnamed_block>.<unnamed_block>\n msg: ", $time, "banked_framebuf: NBUF must be 1 or 2");
			$finish(1);
		end
		if ((RING > 0) && ((RING < B) || ((RING & (RING - 1)) != 0))) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_lanczos/src/../../banked_framebuf/src/banked_framebuf.sv:73:7 - banked_framebuf.<unnamed_block>.<unnamed_block>\n msg: ", $time, "banked_framebuf: RING must be a power of two >= %0d", B);
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
module scaler_polyphase (
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
	parameter signed [31:0] TAPS = 4;
	parameter signed [31:0] PHASE_BITS = 6;
	parameter signed [31:0] COEF_W = 16;
	parameter signed [31:0] COEF_FRAC = 14;
	parameter [31:0] IP_ID = 32'h504f4c59;
	parameter signed [31:0] PINGPONG = 0;
	parameter signed [31:0] LINE_BUF = 0;
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
	localparam signed [31:0] PHASES = 1 << PHASE_BITS;
	localparam signed [31:0] CTR = (TAPS - 1) / 2;
	function automatic signed [7:0] sv2v_cast_8_signed;
		input reg signed [7:0] inp;
		sv2v_cast_8_signed = inp;
	endfunction
	localparam [31:0] CAPS = {sv2v_cast_8_signed(PHASE_BITS), sv2v_cast_8_signed(COMP_W), sv2v_cast_8_signed(CHANNELS), sv2v_cast_8_signed(TAPS)};
	initial begin
		if (((TAPS < 2) || (TAPS > 16)) || ((TAPS % 2) != 0)) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_lanczos/src/../../scaler_polyphase/src/scaler_polyphase.sv:84:7 - scaler_polyphase.<unnamed_block>.<unnamed_block>\n msg: ", $time, "scaler_polyphase: TAPS must be even and in 2..16");
			$finish(1);
		end
		if ((PHASE_BITS < 1) || (PHASE_BITS > 6)) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_lanczos/src/../../scaler_polyphase/src/scaler_polyphase.sv:86:7 - scaler_polyphase.<unnamed_block>.<unnamed_block>\n msg: ", $time, "scaler_polyphase: PHASE_BITS must be 1..6");
			$finish(1);
		end
		if (ADDR_W < 14) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_lanczos/src/../../scaler_polyphase/src/scaler_polyphase.sv:88:7 - scaler_polyphase.<unnamed_block>.<unnamed_block>\n msg: ", $time, "scaler_polyphase: ADDR_W must be >= 14");
			$finish(1);
		end
	end
	reg [31:0] ext_rdata;
	function automatic signed [31:0] pow2ceil_i;
		input reg signed [31:0] v;
		reg signed [31:0] r;
		begin
			r = 1;
			while (r < v) r = r * 2;
			pow2ceil_i = r;
		end
	endfunction
	localparam signed [31:0] WIN_T = TAPS;
	localparam signed [31:0] NBUF = (PINGPONG ? 2 : 1);
	localparam signed [31:0] LB_ROWS = (LINE_BUF ? pow2ceil_i(((WIN_T + 2) < 4 ? 4 : WIN_T + 2)) : 0);
	initial if (PINGPONG && LINE_BUF) begin
		$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/scaler_lanczos/src/../../scaler_polyphase/src/scaler_polyphase.sv:107:5 - scaler_polyphase.<unnamed_block>\n msg: ", $time, "scaler_polyphase: PINGPONG and LINE_BUF are mutually exclusive");
		$finish(1);
	end
	wire fb_we;
	wire [15:0] fb_wx;
	wire [15:0] fb_wy;
	wire [PIX_W - 1:0] fb_wdata;
	wire gen_start;
	wire gen_done;
	wire fb_wbuf;
	wire gen_buf;
	wire lb_hold;
	wire signed [31:0] d_nxt_y;
	reg signed [31:0] a_y;
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
	wire d_valid;
	wire d_sof;
	wire d_eol;
	wire d_eof;
	wire d_busy;
	wire signed [31:0] d_x;
	wire signed [31:0] d_y;
	localparam signed [31:0] LT = $clog2(TAPS);
	localparam signed [31:0] AW1 = (((COMP_W + 1) + COEF_W) + LT) + 1;
	localparam signed [31:0] VW = (COMP_W + LT) + 3;
	localparam signed [31:0] AW2 = ((VW + COEF_W) + LT) + 1;
	localparam signed [31:0] PV = (COMP_W + 1) + COEF_W;
	localparam signed [31:0] PH = VW + COEF_W;
	localparam signed [31:0] NP = 1 << LT;
	localparam signed [31:0] LV = LT;
	localparam signed [31:0] NST = ((4 + LV) + 2) + LV;
	reg [NST - 1:0] v_q;
	scaler_ctrl #(
		.PIX_W(PIX_W),
		.ADDR_W(ADDR_W),
		.MAX_W(MAX_W),
		.MAX_H(MAX_H),
		.IP_ID(IP_ID),
		.CAPS(CAPS),
		.NBUF(NBUF),
		.LB_ROWS(LB_ROWS),
		.LB_TAPS(WIN_T),
		.LB_CTR((TAPS - 1) / 2),
		.LB_RND(1 << ((16 - PHASE_BITS) - 1))
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
		.lb_nxt_y(d_nxt_y),
		.lb_nxt_v(d_busy),
		.lb_o_y(d_y),
		.lb_o_v(d_valid),
		.lb_a_y(a_y),
		.lb_a_v(v_q[0]),
		.lb_hold(lb_hold),
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
	reg signed [COEF_W - 1:0] coef_h [0:PHASES - 1][0:TAPS - 1];
	reg signed [COEF_W - 1:0] coef_v [0:PHASES - 1][0:TAPS - 1];
	function automatic signed [COEF_W - 1:0] sv2v_cast_423D4_signed;
		input reg signed [COEF_W - 1:0] inp;
		sv2v_cast_423D4_signed = inp;
	endfunction
	initial begin : sv2v_autoblock_1
		reg signed [31:0] p;
		for (p = 0; p < PHASES; p = p + 1)
			begin : sv2v_autoblock_2
				reg signed [31:0] t;
				for (t = 0; t < TAPS; t = t + 1)
					begin
						coef_h[p][t] = (t == CTR ? sv2v_cast_423D4_signed(((PHASES - p) << COEF_FRAC) / PHASES) : (t == (CTR + 1) ? sv2v_cast_423D4_signed((p << COEF_FRAC) / PHASES) : {COEF_W {1'sb0}}));
						coef_v[p][t] = coef_h[p][t];
					end
			end
	end
	wire [5:0] w_ph = ext_waddr[11:6];
	wire [3:0] w_tap = ext_waddr[5:2];
	wire [5:0] r_ph = ext_raddr[11:6];
	wire [3:0] r_tap = ext_raddr[5:2];
	always @(posedge clk)
		if ((ext_wr && (w_ph < PHASES)) && (w_tap < TAPS)) begin
			if (ext_waddr[13:12] == 2'd1)
				coef_h[w_ph][w_tap] <= ext_wdata[COEF_W - 1:0];
			if (ext_waddr[13:12] == 2'd2)
				coef_v[w_ph][w_tap] <= ext_wdata[COEF_W - 1:0];
		end
	function automatic [31:0] sv2v_cast_32;
		input reg [31:0] inp;
		sv2v_cast_32 = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			ext_rdata <= 1'sb0;
		else if (ext_rd) begin
			ext_rdata <= 1'sb0;
			if (ext_raddr[13:0] == 14'h0040)
				ext_rdata <= {sv2v_cast_8_signed(COEF_FRAC), sv2v_cast_8_signed(COEF_W), sv2v_cast_8_signed(PHASE_BITS), sv2v_cast_8_signed(TAPS)};
			else if ((r_ph < PHASES) && (r_tap < TAPS)) begin
				if (ext_raddr[13:12] == 2'd1)
					ext_rdata <= sv2v_cast_32(coef_h[r_ph][r_tap]);
				if (ext_raddr[13:12] == 2'd2)
					ext_rdata <= sv2v_cast_32(coef_v[r_ph][r_tap]);
			end
		end
	wire adv = !m_axis_tvalid || m_axis_tready;
	scaler_dda u_dda(
		.clk(clk),
		.rst_n(rst_n),
		.start(gen_start),
		.adv(adv),
		.hold(lb_hold),
		.nxt_y(d_nxt_y),
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
	localparam signed [31:0] RND = 32'sd1 <<< ((16 - PHASE_BITS) - 1);
	wire signed [31:0] rx = d_x + RND;
	wire signed [31:0] ry = d_y + RND;
	function automatic signed [17:0] sv2v_cast_18_signed;
		input reg signed [17:0] inp;
		sv2v_cast_18_signed = inp;
	endfunction
	wire signed [17:0] x0 = sv2v_cast_18_signed(rx >>> 16) - sv2v_cast_18_signed(CTR);
	wire signed [17:0] y0 = sv2v_cast_18_signed(ry >>> 16) - sv2v_cast_18_signed(CTR);
	wire [PHASE_BITS - 1:0] px = rx[15-:PHASE_BITS];
	wire [PHASE_BITS - 1:0] py = ry[15-:PHASE_BITS];
	wire [((TAPS * TAPS) * PIX_W) - 1:0] win;
	banked_framebuf #(
		.PIX_W(PIX_W),
		.TAPS(TAPS),
		.MAX_W(MAX_W),
		.MAX_H(MAX_H),
		.NBUF(NBUF),
		.RING(LB_ROWS)
	) u_fb(
		.clk(clk),
		.wr_en(fb_we),
		.wr_x(fb_wx),
		.wr_y(fb_wy),
		.wr_data(fb_wdata),
		.wr_buf(fb_wbuf),
		.rd_adv(adv),
		.rd_buf(gen_buf),
		.rd_x0(x0),
		.rd_y0(y0),
		.img_w(in_w),
		.img_h(in_h),
		.rd_win(win)
	);
	reg [2:0] f_q [0:NST - 1];
	reg [PHASE_BITS - 1:0] px_q;
	reg [PHASE_BITS - 1:0] py_q;
	localparam signed [31:0] CHD = (2 + LV) + 1;
	reg signed [COEF_W - 1:0] ch_q [0:TAPS - 1];
	reg signed [COEF_W - 1:0] cv_q [0:TAPS - 1];
	reg signed [COEF_W - 1:0] cv_w [0:TAPS - 1];
	reg signed [COEF_W - 1:0] ch_d [0:CHD - 1][0:TAPS - 1];
	reg [((TAPS * TAPS) * PIX_W) - 1:0] win_q;
	reg signed [AW1 - 1:0] tv_q [0:LV + 0][0:CHANNELS - 1][0:TAPS - 1][0:NP - 1];
	reg signed [VW - 1:0] vs_q [0:CHANNELS - 1][0:TAPS - 1];
	reg signed [AW2 - 1:0] th_q [0:LV + 0][0:CHANNELS - 1][0:NP - 1];
	reg m_eof;
	reg signed [AW1 - 1:0] pv_c [0:CHANNELS - 1][0:TAPS - 1][0:NP - 1];
	function automatic signed [PV - 1:0] sv2v_cast_2D3D1_signed;
		input reg signed [PV - 1:0] inp;
		sv2v_cast_2D3D1_signed = inp;
	endfunction
	function automatic signed [AW1 - 1:0] sv2v_cast_29781_signed;
		input reg signed [AW1 - 1:0] inp;
		sv2v_cast_29781_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_3
			reg signed [31:0] c;
			for (c = 0; c < CHANNELS; c = c + 1)
				begin : sv2v_autoblock_4
					reg signed [31:0] k;
					for (k = 0; k < TAPS; k = k + 1)
						begin : sv2v_autoblock_5
							reg signed [31:0] j;
							for (j = 0; j < NP; j = j + 1)
								if (j < TAPS)
									pv_c[c][k][j] = sv2v_cast_29781_signed(sv2v_cast_2D3D1_signed($signed({1'b0, win_q[(((j * TAPS) + k) * PIX_W) + (c * COMP_W)+:COMP_W]})) * sv2v_cast_2D3D1_signed($signed(cv_w[j])));
								else
									pv_c[c][k][j] = 1'sb0;
						end
				end
		end
	end
	reg signed [VW - 1:0] vs_c [0:CHANNELS - 1][0:TAPS - 1];
	function automatic signed [VW - 1:0] sv2v_cast_57546_signed;
		input reg signed [VW - 1:0] inp;
		sv2v_cast_57546_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_6
			reg signed [31:0] c;
			for (c = 0; c < CHANNELS; c = c + 1)
				begin : sv2v_autoblock_7
					reg signed [31:0] k;
					for (k = 0; k < TAPS; k = k + 1)
						vs_c[c][k] = sv2v_cast_57546_signed(($signed(tv_q[LV][c][k][0]) + (sv2v_cast_29781_signed(1) <<< (COEF_FRAC - 1))) >>> COEF_FRAC);
				end
		end
	end
	reg signed [AW2 - 1:0] ph_c [0:CHANNELS - 1][0:NP - 1];
	function automatic signed [PH - 1:0] sv2v_cast_7FA8F_signed;
		input reg signed [PH - 1:0] inp;
		sv2v_cast_7FA8F_signed = inp;
	endfunction
	function automatic signed [AW2 - 1:0] sv2v_cast_CDAF2_signed;
		input reg signed [AW2 - 1:0] inp;
		sv2v_cast_CDAF2_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_8
			reg signed [31:0] c;
			for (c = 0; c < CHANNELS; c = c + 1)
				begin : sv2v_autoblock_9
					reg signed [31:0] k;
					for (k = 0; k < NP; k = k + 1)
						if (k < TAPS)
							ph_c[c][k] = sv2v_cast_CDAF2_signed(sv2v_cast_7FA8F_signed($signed(vs_q[c][k])) * sv2v_cast_7FA8F_signed($signed(ch_d[CHD - 1][k])));
						else
							ph_c[c][k] = 1'sb0;
				end
		end
	end
	localparam signed [AW2 - 1:0] MAXV = sv2v_cast_CDAF2_signed((1 << COMP_W) - 1);
	reg [PIX_W - 1:0] out_c;
	function automatic signed [COMP_W - 1:0] sv2v_cast_8F3CA_signed;
		input reg signed [COMP_W - 1:0] inp;
		sv2v_cast_8F3CA_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_10
			reg signed [31:0] c;
			for (c = 0; c < CHANNELS; c = c + 1)
				begin : sv2v_autoblock_11
					reg signed [AW2 - 1:0] acc;
					acc = ($signed(th_q[LV][c][0]) + (sv2v_cast_CDAF2_signed(1) <<< (COEF_FRAC - 1))) >>> COEF_FRAC;
					if (acc < 0)
						out_c[c * COMP_W+:COMP_W] = 1'sb0;
					else if (acc > MAXV)
						out_c[c * COMP_W+:COMP_W] = 1'sb1;
					else
						out_c[c * COMP_W+:COMP_W] = sv2v_cast_8F3CA_signed(acc);
				end
		end
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			v_q <= 1'sb0;
			begin : sv2v_autoblock_12
				reg signed [31:0] k;
				for (k = 0; k < NST; k = k + 1)
					f_q[k] <= 1'sb0;
			end
			m_axis_tvalid <= 1'b0;
			m_axis_tdata <= 1'sb0;
			m_axis_tuser <= 1'b0;
			m_axis_tlast <= 1'b0;
			m_eof <= 1'b0;
		end
		else if (gen_start)
			v_q <= 1'sb0;
		else if (adv) begin
			v_q[0] <= d_valid;
			f_q[0] <= {d_eof, d_eol, d_sof};
			begin : sv2v_autoblock_13
				reg signed [31:0] k;
				for (k = 1; k < NST; k = k + 1)
					begin
						v_q[k] <= v_q[k - 1];
						f_q[k] <= f_q[k - 1];
					end
			end
			m_axis_tvalid <= v_q[NST - 1];
			m_axis_tdata <= out_c;
			{m_eof, m_axis_tlast, m_axis_tuser} <= f_q[NST - 1];
		end
	always @(posedge clk)
		if (adv) begin
			px_q <= px;
			py_q <= py;
			begin : sv2v_autoblock_14
				reg signed [31:0] t;
				for (t = 0; t < TAPS; t = t + 1)
					begin
						ch_q[t] <= coef_h[px_q][t];
						cv_q[t] <= coef_v[py_q][t];
						cv_w[t] <= cv_q[t];
						ch_d[0][t] <= ch_q[t];
						begin : sv2v_autoblock_15
							reg signed [31:0] d;
							for (d = 1; d < CHD; d = d + 1)
								ch_d[d][t] <= ch_d[d - 1][t];
						end
					end
			end
			win_q <= win;
			begin : sv2v_autoblock_16
				reg signed [31:0] c;
				for (c = 0; c < CHANNELS; c = c + 1)
					begin
						begin : sv2v_autoblock_17
							reg signed [31:0] k;
							for (k = 0; k < TAPS; k = k + 1)
								begin
									begin : sv2v_autoblock_18
										reg signed [31:0] j;
										for (j = 0; j < NP; j = j + 1)
											tv_q[0][c][k][j] <= pv_c[c][k][j];
									end
									vs_q[c][k] <= vs_c[c][k];
								end
						end
						begin : sv2v_autoblock_19
							reg signed [31:0] k;
							for (k = 0; k < NP; k = k + 1)
								th_q[0][c][k] <= ph_c[c][k];
						end
					end
			end
		end
	genvar _gv_l_1;
	generate
		for (_gv_l_1 = 0; _gv_l_1 < LV; _gv_l_1 = _gv_l_1 + 1) begin : g_tree
			localparam l = _gv_l_1;
			genvar _gv_j_1;
			for (_gv_j_1 = 0; _gv_j_1 < (NP >> (l + 1)); _gv_j_1 = _gv_j_1 + 1) begin : g_node
				localparam j = _gv_j_1;
				always @(posedge clk)
					if (adv) begin : sv2v_autoblock_20
						reg signed [31:0] c;
						for (c = 0; c < CHANNELS; c = c + 1)
							begin
								begin : sv2v_autoblock_21
									reg signed [31:0] k;
									for (k = 0; k < TAPS; k = k + 1)
										tv_q[l + 1][c][k][j] <= $signed(tv_q[l][c][k][2 * j]) + $signed(tv_q[l][c][k][(2 * j) + 1]);
								end
								th_q[l + 1][c][j] <= $signed(th_q[l][c][2 * j]) + $signed(th_q[l][c][(2 * j) + 1]);
							end
					end
			end
		end
	endgenerate
	always @(posedge clk)
		if (adv)
			a_y <= d_y;
	assign gen_done = (m_axis_tvalid && m_axis_tready) && m_eof;
	initial _sv2v_0 = 0;
endmodule
module scaler_lanczos (
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
	parameter signed [31:0] PHASE_BITS = 6;
	parameter signed [31:0] COEF_W = 16;
	parameter signed [31:0] COEF_FRAC = 14;
	parameter signed [31:0] PINGPONG = 0;
	parameter signed [31:0] LINE_BUF = 0;
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
	scaler_polyphase #(
		.PINGPONG(PINGPONG),
		.LINE_BUF(LINE_BUF),
		.CHANNELS(CHANNELS),
		.COMP_W(COMP_W),
		.MAX_W(MAX_W),
		.MAX_H(MAX_H),
		.ADDR_W(ADDR_W),
		.TAPS(6),
		.PHASE_BITS(PHASE_BITS),
		.COEF_W(COEF_W),
		.COEF_FRAC(COEF_FRAC),
		.IP_ID(32'h4c414e43)
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