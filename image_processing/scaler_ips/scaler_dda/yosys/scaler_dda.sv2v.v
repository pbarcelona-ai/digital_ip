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