// ***************
// Filename: nco_sine_rom.sv
// Author: Paul Barcelona
// Description: Quarter wave sine ROM with two independent registered read
//   ports (sine and cosine lookup). 256 entries of 15-bit unsigned magnitude
//   sampled at bin centers, so the table is exactly symmetric and the caller
//   only needs address mirroring and a sign flip. Contents are constants so
//   synthesis maps the table to LUT ROM or block RAM. Version 1.0.0. Helper
//   block of its IP; see the top level description for clock, reset, latency
//   and error behavior. Clock - the clock of the parent block, all signals
//   are synchronous to it. Reset - none, the registers are cleared by the
//   parent block's control flow. Latency - as documented in the parent block,
//   fixed and independent of data. Errors - none reported here, out-of-range
//   parameters stop elaboration or are handled by the parent block.
//   are synchronous to it. Reset - none, the registers are cleared by the
//   parent block's control flow. Latency - as documented in the parent block,
//   fixed and independent of data. Errors - none reported here, out-of-range
//   parameters stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module nco_sine_rom (
  input  logic        clk,
  input  logic        en,          // clock enable for both read ports
  input  logic [7:0]  addr_a,      // port A address (sine)
  input  logic [7:0]  addr_b,      // port B address (cosine)
  output logic [14:0] dout_a,
  output logic [14:0] dout_b
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  // sin table: round(32767 * sin((i + 0.5) * pi / 512))
  function automatic logic [14:0] rom(input logic [7:0] a);
    case (a)
      8'd0: rom = 15'd101;
      8'd1: rom = 15'd302;
      8'd2: rom = 15'd503;
      8'd3: rom = 15'd704;
      8'd4: rom = 15'd905;
      8'd5: rom = 15'd1106;
      8'd6: rom = 15'd1307;
      8'd7: rom = 15'd1507;
      8'd8: rom = 15'd1708;
      8'd9: rom = 15'd1909;
      8'd10: rom = 15'd2110;
      8'd11: rom = 15'd2310;
      8'd12: rom = 15'd2511;
      8'd13: rom = 15'd2711;
      8'd14: rom = 15'd2911;
      8'd15: rom = 15'd3112;
      8'd16: rom = 15'd3312;
      8'd17: rom = 15'd3512;
      8'd18: rom = 15'd3712;
      8'd19: rom = 15'd3911;
      8'd20: rom = 15'd4111;
      8'd21: rom = 15'd4310;
      8'd22: rom = 15'd4509;
      8'd23: rom = 15'd4708;
      8'd24: rom = 15'd4907;
      8'd25: rom = 15'd5106;
      8'd26: rom = 15'd5305;
      8'd27: rom = 15'd5503;
      8'd28: rom = 15'd5701;
      8'd29: rom = 15'd5899;
      8'd30: rom = 15'd6096;
      8'd31: rom = 15'd6294;
      8'd32: rom = 15'd6491;
      8'd33: rom = 15'd6688;
      8'd34: rom = 15'd6885;
      8'd35: rom = 15'd7081;
      8'd36: rom = 15'd7277;
      8'd37: rom = 15'd7473;
      8'd38: rom = 15'd7669;
      8'd39: rom = 15'd7864;
      8'd40: rom = 15'd8059;
      8'd41: rom = 15'd8254;
      8'd42: rom = 15'd8448;
      8'd43: rom = 15'd8642;
      8'd44: rom = 15'd8836;
      8'd45: rom = 15'd9030;
      8'd46: rom = 15'd9223;
      8'd47: rom = 15'd9416;
      8'd48: rom = 15'd9608;
      8'd49: rom = 15'd9800;
      8'd50: rom = 15'd9992;
      8'd51: rom = 15'd10183;
      8'd52: rom = 15'd10374;
      8'd53: rom = 15'd10564;
      8'd54: rom = 15'd10754;
      8'd55: rom = 15'd10944;
      8'd56: rom = 15'd11133;
      8'd57: rom = 15'd11322;
      8'd58: rom = 15'd11511;
      8'd59: rom = 15'd11699;
      8'd60: rom = 15'd11886;
      8'd61: rom = 15'd12074;
      8'd62: rom = 15'd12260;
      8'd63: rom = 15'd12446;
      8'd64: rom = 15'd12632;
      8'd65: rom = 15'd12817;
      8'd66: rom = 15'd13002;
      8'd67: rom = 15'd13187;
      8'd68: rom = 15'd13370;
      8'd69: rom = 15'd13554;
      8'd70: rom = 15'd13736;
      8'd71: rom = 15'd13919;
      8'd72: rom = 15'd14101;
      8'd73: rom = 15'd14282;
      8'd74: rom = 15'd14462;
      8'd75: rom = 15'd14643;
      8'd76: rom = 15'd14822;
      8'd77: rom = 15'd15001;
      8'd78: rom = 15'd15180;
      8'd79: rom = 15'd15358;
      8'd80: rom = 15'd15535;
      8'd81: rom = 15'd15712;
      8'd82: rom = 15'd15888;
      8'd83: rom = 15'd16063;
      8'd84: rom = 15'd16238;
      8'd85: rom = 15'd16413;
      8'd86: rom = 15'd16586;
      8'd87: rom = 15'd16759;
      8'd88: rom = 15'd16932;
      8'd89: rom = 15'd17104;
      8'd90: rom = 15'd17275;
      8'd91: rom = 15'd17445;
      8'd92: rom = 15'd17615;
      8'd93: rom = 15'd17784;
      8'd94: rom = 15'd17953;
      8'd95: rom = 15'd18121;
      8'd96: rom = 15'd18288;
      8'd97: rom = 15'd18454;
      8'd98: rom = 15'd18620;
      8'd99: rom = 15'd18785;
      8'd100: rom = 15'd18950;
      8'd101: rom = 15'd19113;
      8'd102: rom = 15'd19276;
      8'd103: rom = 15'd19438;
      8'd104: rom = 15'd19600;
      8'd105: rom = 15'd19761;
      8'd106: rom = 15'd19921;
      8'd107: rom = 15'd20080;
      8'd108: rom = 15'd20238;
      8'd109: rom = 15'd20396;
      8'd110: rom = 15'd20553;
      8'd111: rom = 15'd20709;
      8'd112: rom = 15'd20865;
      8'd113: rom = 15'd21019;
      8'd114: rom = 15'd21173;
      8'd115: rom = 15'd21326;
      8'd116: rom = 15'd21479;
      8'd117: rom = 15'd21630;
      8'd118: rom = 15'd21781;
      8'd119: rom = 15'd21930;
      8'd120: rom = 15'd22079;
      8'd121: rom = 15'd22227;
      8'd122: rom = 15'd22375;
      8'd123: rom = 15'd22521;
      8'd124: rom = 15'd22667;
      8'd125: rom = 15'd22812;
      8'd126: rom = 15'd22956;
      8'd127: rom = 15'd23099;
      8'd128: rom = 15'd23241;
      8'd129: rom = 15'd23382;
      8'd130: rom = 15'd23522;
      8'd131: rom = 15'd23662;
      8'd132: rom = 15'd23801;
      8'd133: rom = 15'd23938;
      8'd134: rom = 15'd24075;
      8'd135: rom = 15'd24211;
      8'd136: rom = 15'd24346;
      8'd137: rom = 15'd24480;
      8'd138: rom = 15'd24613;
      8'd139: rom = 15'd24746;
      8'd140: rom = 15'd24877;
      8'd141: rom = 15'd25007;
      8'd142: rom = 15'd25137;
      8'd143: rom = 15'd25265;
      8'd144: rom = 15'd25393;
      8'd145: rom = 15'd25519;
      8'd146: rom = 15'd25645;
      8'd147: rom = 15'd25770;
      8'd148: rom = 15'd25893;
      8'd149: rom = 15'd26016;
      8'd150: rom = 15'd26138;
      8'd151: rom = 15'd26259;
      8'd152: rom = 15'd26378;
      8'd153: rom = 15'd26497;
      8'd154: rom = 15'd26615;
      8'd155: rom = 15'd26732;
      8'd156: rom = 15'd26848;
      8'd157: rom = 15'd26962;
      8'd158: rom = 15'd27076;
      8'd159: rom = 15'd27189;
      8'd160: rom = 15'd27300;
      8'd161: rom = 15'd27411;
      8'd162: rom = 15'd27521;
      8'd163: rom = 15'd27629;
      8'd164: rom = 15'd27737;
      8'd165: rom = 15'd27843;
      8'd166: rom = 15'd27949;
      8'd167: rom = 15'd28053;
      8'd168: rom = 15'd28157;
      8'd169: rom = 15'd28259;
      8'd170: rom = 15'd28360;
      8'd171: rom = 15'd28460;
      8'd172: rom = 15'd28560;
      8'd173: rom = 15'd28658;
      8'd174: rom = 15'd28755;
      8'd175: rom = 15'd28850;
      8'd176: rom = 15'd28945;
      8'd177: rom = 15'd29039;
      8'd178: rom = 15'd29131;
      8'd179: rom = 15'd29223;
      8'd180: rom = 15'd29313;
      8'd181: rom = 15'd29403;
      8'd182: rom = 15'd29491;
      8'd183: rom = 15'd29578;
      8'd184: rom = 15'd29664;
      8'd185: rom = 15'd29749;
      8'd186: rom = 15'd29832;
      8'd187: rom = 15'd29915;
      8'd188: rom = 15'd29997;
      8'd189: rom = 15'd30077;
      8'd190: rom = 15'd30156;
      8'd191: rom = 15'd30234;
      8'd192: rom = 15'd30311;
      8'd193: rom = 15'd30387;
      8'd194: rom = 15'd30462;
      8'd195: rom = 15'd30535;
      8'd196: rom = 15'd30607;
      8'd197: rom = 15'd30679;
      8'd198: rom = 15'd30749;
      8'd199: rom = 15'd30818;
      8'd200: rom = 15'd30885;
      8'd201: rom = 15'd30952;
      8'd202: rom = 15'd31017;
      8'd203: rom = 15'd31082;
      8'd204: rom = 15'd31145;
      8'd205: rom = 15'd31206;
      8'd206: rom = 15'd31267;
      8'd207: rom = 15'd31327;
      8'd208: rom = 15'd31385;
      8'd209: rom = 15'd31442;
      8'd210: rom = 15'd31498;
      8'd211: rom = 15'd31553;
      8'd212: rom = 15'd31607;
      8'd213: rom = 15'd31659;
      8'd214: rom = 15'd31710;
      8'd215: rom = 15'd31760;
      8'd216: rom = 15'd31809;
      8'd217: rom = 15'd31857;
      8'd218: rom = 15'd31903;
      8'd219: rom = 15'd31949;
      8'd220: rom = 15'd31993;
      8'd221: rom = 15'd32036;
      8'd222: rom = 15'd32077;
      8'd223: rom = 15'd32118;
      8'd224: rom = 15'd32157;
      8'd225: rom = 15'd32195;
      8'd226: rom = 15'd32232;
      8'd227: rom = 15'd32267;
      8'd228: rom = 15'd32302;
      8'd229: rom = 15'd32335;
      8'd230: rom = 15'd32367;
      8'd231: rom = 15'd32397;
      8'd232: rom = 15'd32427;
      8'd233: rom = 15'd32455;
      8'd234: rom = 15'd32482;
      8'd235: rom = 15'd32508;
      8'd236: rom = 15'd32533;
      8'd237: rom = 15'd32556;
      8'd238: rom = 15'd32578;
      8'd239: rom = 15'd32599;
      8'd240: rom = 15'd32619;
      8'd241: rom = 15'd32637;
      8'd242: rom = 15'd32655;
      8'd243: rom = 15'd32671;
      8'd244: rom = 15'd32685;
      8'd245: rom = 15'd32699;
      8'd246: rom = 15'd32711;
      8'd247: rom = 15'd32722;
      8'd248: rom = 15'd32732;
      8'd249: rom = 15'd32741;
      8'd250: rom = 15'd32748;
      8'd251: rom = 15'd32755;
      8'd252: rom = 15'd32759;
      8'd253: rom = 15'd32763;
      8'd254: rom = 15'd32766;
      8'd255: rom = 15'd32767;
      default: rom = 15'd0;
    endcase
  endfunction

  // Registered read (synchronous ROM)
  always_ff @(posedge clk) begin
    if (en) begin
      dout_a <= rom(addr_a);
      dout_b <= rom(addr_b);
    end
  end
endmodule
