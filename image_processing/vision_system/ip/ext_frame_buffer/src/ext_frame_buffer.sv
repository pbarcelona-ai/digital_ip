// ***************
// Filename: ext_frame_buffer.sv
// Description: SDR SDRAM-backed frame buffer with queued pixel writes and
//              serialized four-address reads.
// ***************
module ext_frame_buffer #(
  parameter int PIX_W = barrel_pkg::PIX_W,
  parameter int ADDR_W = barrel_pkg::ADDR_W,
  parameter int SDRAM_DQ_W = 64,
  parameter int SDRAM_A_W = 13,
  parameter int COL_W = 10,
  parameter int FIFO_DEPTH = 32,
  parameter int FIFO_AW = $clog2(FIFO_DEPTH),
  parameter int INIT_WAIT_CYCLES = 20000,
  parameter int T_RP_CYCLES = 2,
  parameter int T_RCD_CYCLES = 2,
  parameter int T_RAS_CYCLES = 5,
  parameter int T_RFC_CYCLES = 7,
  parameter int T_MRD_CYCLES = 2,
  parameter int T_WR_CYCLES = 2,
  parameter int CAS_LATENCY = 2,
  parameter int REFRESH_INTERVAL_CYCLES = 780
) (
  input  logic clk,
  input  logic rst_n,

  input  logic wr_en,
  output logic wr_ready,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [PIX_W-1:0] wr_data,
  output logic wr_idle,

  input  logic rd_en,
  output logic rd_ready,
  input  logic [ADDR_W-1:0] rd_addr0,
  input  logic [ADDR_W-1:0] rd_addr1,
  input  logic [ADDR_W-1:0] rd_addr2,
  input  logic [ADDR_W-1:0] rd_addr3,
  output logic rd_valid,
  output logic [PIX_W-1:0] rd_data0,
  output logic [PIX_W-1:0] rd_data1,
  output logic [PIX_W-1:0] rd_data2,
  output logic [PIX_W-1:0] rd_data3,

  output wire sdram_clk,
  output logic sdram_cke,
  output logic sdram_cs_n,
  output logic sdram_ras_n,
  output logic sdram_cas_n,
  output logic sdram_we_n,
  output logic [SDRAM_A_W-1:0] sdram_a,
  output logic [1:0] sdram_ba,
  output logic [SDRAM_DQ_W/8-1:0] sdram_dqm,
  inout  wire [SDRAM_DQ_W-1:0] sdram_dq
);

  localparam int PTR_W = (FIFO_AW > 0) ? FIFO_AW : 1;
  localparam logic [SDRAM_A_W-1:0] MODE_REG = (CAS_LATENCY << 4) | 10'h200;

  typedef enum logic [4:0] {
    ST_INIT_WAIT, ST_INIT_PRE, ST_INIT_RP, ST_INIT_REF1, ST_INIT_RFC1,
    ST_INIT_REF2, ST_INIT_RFC2, ST_INIT_MODE, ST_INIT_MRD, ST_IDLE,
    ST_PRE, ST_RP, ST_ACT, ST_RCD, ST_READ, ST_CAS, ST_WRITE,
    ST_REFRESH, ST_RFC
  } state_t;
  state_t state;

  logic [ADDR_W-1:0] wr_fifo_addr [0:FIFO_DEPTH-1];
  logic [PIX_W-1:0] wr_fifo_data [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0] wr_rd_ptr, wr_wr_ptr;
  logic [PTR_W:0] wr_count;

  logic [ADDR_W-1:0] read_addr [0:3];
  logic [1:0] read_index;
  logic read_active;
  logic initialized;
  logic open_row_valid;
  logic [SDRAM_A_W-1:0] open_row;
  logic refresh_due;
  logic [31:0] refresh_count;
  logic [31:0] row_age;
  logic [31:0] write_age;
  logic [31:0] wait_count;
  logic refresh_after_precharge;
  logic [SDRAM_DQ_W-1:0] dq_out;
  logic dq_oe;
  wire [SDRAM_DQ_W-1:0] dq_in = sdram_dq;
  logic [ADDR_W-1:0] current_addr;
  logic [SDRAM_A_W-1:0] current_row;
  logic [SDRAM_A_W-1:0] current_col;
  logic write_pop;
  logic write_push;

  assign sdram_clk = clk;
  assign sdram_dq = dq_oe ? dq_out : {SDRAM_DQ_W{1'bz}};
  assign wr_ready = initialized && !refresh_due && (wr_count < FIFO_DEPTH);
  assign write_push = wr_en && wr_ready;
  assign write_pop = (state == ST_WRITE);
  assign wr_idle = initialized && (wr_count == 0) && !write_pop && (write_age == 0);
  assign rd_ready = initialized && !read_active && (wr_count == 0);

  always @* begin
    if (read_active) current_addr = read_addr[read_index];
    else             current_addr = wr_fifo_addr[wr_rd_ptr];
    current_col = '0;
    current_col[COL_W-1:0] = current_addr[COL_W-1:0];
    current_row = current_addr >> COL_W;
  end

  always_comb begin
    sdram_cke = (state != ST_INIT_WAIT);
    sdram_cs_n = 1'b0;
    sdram_ras_n = 1'b1;
    sdram_cas_n = 1'b1;
    sdram_we_n = 1'b1;
    sdram_a = '0;
    sdram_ba = 2'b00;
    sdram_dqm = '0;
    dq_oe = 1'b0;
    dq_out = '0;

    case (state)
      ST_INIT_PRE, ST_PRE: begin
        sdram_ras_n = 1'b0;
        sdram_we_n = 1'b0;
        sdram_a[10] = 1'b1;
      end
      ST_INIT_REF1, ST_INIT_REF2, ST_REFRESH: begin
        sdram_ras_n = 1'b0;
        sdram_cas_n = 1'b0;
      end
      ST_INIT_MODE: begin
        sdram_ras_n = 1'b0;
        sdram_cas_n = 1'b0;
        sdram_we_n = 1'b0;
        sdram_a = MODE_REG;
      end
      ST_ACT: begin
        sdram_ras_n = 1'b0;
        sdram_a = current_row;
      end
      ST_READ: begin
        sdram_cas_n = 1'b0;
        sdram_a = current_col;
      end
      ST_WRITE: begin
        sdram_cas_n = 1'b0;
        sdram_we_n = 1'b0;
        sdram_a = current_col;
        dq_oe = 1'b1;
        dq_out[PIX_W-1:0] = wr_fifo_data[wr_rd_ptr];
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_INIT_WAIT;
      wait_count <= INIT_WAIT_CYCLES;
      initialized <= 1'b0;
      open_row_valid <= 1'b0;
      open_row <= '0;
      refresh_due <= 1'b0;
      refresh_count <= '0;
      row_age <= '0;
      write_age <= '0;
      refresh_after_precharge <= 1'b0;
      wr_rd_ptr <= '0;
      wr_wr_ptr <= '0;
      wr_count <= '0;
      read_index <= '0;
      read_active <= 1'b0;
      rd_valid <= 1'b0;
      rd_data0 <= '0;
      rd_data1 <= '0;
      rd_data2 <= '0;
      rd_data3 <= '0;
    end else begin
      rd_valid <= 1'b0;

      if (write_age != 0) write_age <= write_age - 1'b1;
      if (open_row_valid && (row_age < T_RAS_CYCLES))
        row_age <= row_age + 1'b1;
      if (initialized && !refresh_due) begin
        if (refresh_count + 1 >= REFRESH_INTERVAL_CYCLES) refresh_due <= 1'b1;
        else refresh_count <= refresh_count + 1'b1;
      end

      if (write_push) begin
        wr_fifo_addr[wr_wr_ptr] <= wr_addr;
        wr_fifo_data[wr_wr_ptr] <= wr_data;
        wr_wr_ptr <= wr_wr_ptr + 1'b1;
      end
      if (write_pop) wr_rd_ptr <= wr_rd_ptr + 1'b1;
      case ({write_push, write_pop})
        2'b10: wr_count <= wr_count + 1'b1;
        2'b01: wr_count <= wr_count - 1'b1;
        default: ;
      endcase

      if (rd_en && rd_ready) begin
        read_addr[0] <= rd_addr0;
        read_addr[1] <= rd_addr1;
        read_addr[2] <= rd_addr2;
        read_addr[3] <= rd_addr3;
        read_index <= 0;
        read_active <= 1'b1;
      end

      case (state)
        ST_INIT_WAIT: begin
          if (wait_count <= 1) state <= ST_INIT_PRE;
          else wait_count <= wait_count - 1'b1;
        end
        ST_INIT_PRE: begin
          open_row_valid <= 1'b0;
          wait_count <= T_RP_CYCLES;
          state <= ST_INIT_RP;
        end
        ST_INIT_RP: begin
          if (wait_count <= 1) state <= ST_INIT_REF1;
          else wait_count <= wait_count - 1'b1;
        end
        ST_INIT_REF1: begin
          wait_count <= T_RFC_CYCLES;
          state <= ST_INIT_RFC1;
        end
        ST_INIT_RFC1: begin
          if (wait_count <= 1) state <= ST_INIT_REF2;
          else wait_count <= wait_count - 1'b1;
        end
        ST_INIT_REF2: begin
          wait_count <= T_RFC_CYCLES;
          state <= ST_INIT_RFC2;
        end
        ST_INIT_RFC2: begin
          if (wait_count <= 1) state <= ST_INIT_MODE;
          else wait_count <= wait_count - 1'b1;
        end
        ST_INIT_MODE: begin
          wait_count <= T_MRD_CYCLES;
          state <= ST_INIT_MRD;
        end
        ST_INIT_MRD: begin
          if (wait_count <= 1) begin
            initialized <= 1'b1;
            refresh_count <= '0;
            state <= ST_IDLE;
          end else wait_count <= wait_count - 1'b1;
        end
        ST_IDLE: begin
          if (refresh_due && (write_age == 0)) begin
            if (open_row_valid) begin
              if (row_age >= T_RAS_CYCLES) begin
                refresh_after_precharge <= 1'b1;
                state <= ST_PRE;
              end
            end else state <= ST_REFRESH;
          end else if (read_active || (wr_count != 0)) begin
            if (open_row_valid && (open_row != current_row)) begin
              if ((write_age == 0) && (row_age >= T_RAS_CYCLES)) begin
                refresh_after_precharge <= 1'b0;
                state <= ST_PRE;
              end
            end else if (open_row_valid) begin
              if (read_active) begin
                if (write_age == 0) state <= ST_READ;
              end else state <= ST_WRITE;
            end else state <= ST_ACT;
          end
        end
        ST_PRE: begin
          open_row_valid <= 1'b0;
          row_age <= '0;
          wait_count <= T_RP_CYCLES;
          state <= ST_RP;
        end
        ST_RP: begin
          if (wait_count <= 1) begin
            if (refresh_after_precharge) state <= ST_REFRESH;
            else state <= ST_ACT;
          end else wait_count <= wait_count - 1'b1;
        end
        ST_ACT: begin
          open_row <= current_row;
          open_row_valid <= 1'b1;
          row_age <= '0;
          wait_count <= T_RCD_CYCLES;
          state <= ST_RCD;
        end
        ST_RCD: begin
          if (wait_count <= 1) begin
            if (read_active) state <= ST_READ;
            else state <= ST_WRITE;
          end else wait_count <= wait_count - 1'b1;
        end
        ST_READ: begin
          wait_count <= CAS_LATENCY + 1;
          state <= ST_CAS;
        end
        ST_CAS: begin
          if (wait_count <= 1) begin
            case (read_index)
              2'd0: rd_data0 <= dq_in[PIX_W-1:0];
              2'd1: rd_data1 <= dq_in[PIX_W-1:0];
              2'd2: rd_data2 <= dq_in[PIX_W-1:0];
              2'd3: rd_data3 <= dq_in[PIX_W-1:0];
            endcase
            if (read_index == 3) begin
              rd_valid <= 1'b1;
              read_active <= 1'b0;
              state <= ST_IDLE;
            end else begin
              read_index <= read_index + 1'b1;
              state <= ST_IDLE;
            end
          end else wait_count <= wait_count - 1'b1;
        end
        ST_WRITE: begin
          write_age <= T_WR_CYCLES;
          state <= ST_IDLE;
        end
        ST_REFRESH: begin
          open_row_valid <= 1'b0;
          refresh_count <= '0;
          refresh_due <= 1'b0;
          wait_count <= T_RFC_CYCLES;
          state <= ST_RFC;
        end
        ST_RFC: begin
          if (wait_count <= 1) state <= ST_IDLE;
          else wait_count <= wait_count - 1'b1;
        end
        default: state <= ST_INIT_WAIT;
      endcase
    end
  end

endmodule