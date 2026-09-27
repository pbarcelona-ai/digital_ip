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
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/banked_framebuf/src/./banked_framebuf.sv:71:31 - banked_framebuf.<unnamed_block>.<unnamed_block>\n msg: ", $time, "banked_framebuf: NBUF must be 1 or 2");
			$finish(1);
		end
		if ((RING > 0) && ((RING < B) || ((RING & (RING - 1)) != 0))) begin
			$display("Fatal [%0t] /Users/paulbarcelona/Library/CloudStorage/OneDrive-Personal/GitHub/digital_ip/image_processing/scaler_ips/banked_framebuf/src/./banked_framebuf.sv:73:7 - banked_framebuf.<unnamed_block>.<unnamed_block>\n msg: ", $time, "banked_framebuf: RING must be a power of two >= %0d", B);
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