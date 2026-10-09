// ***************
// Filename: csi2_rx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the csi2_rx_tb testbench (csi2_rx_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check    Counts an error and prints the message when the condition is
//              false
//     send     Packets are built with the helpers of receiver 0's lane driver
//              (B.*) and sent on the lanes of receiver g
//     set_phy
//     frame    One frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Packets are built with the helpers of receiver 0's lane driver (B.*)
  // and sent on the lanes of receiver g
  task automatic send(input int g);
    case (g)
      0: begin
        for (int i = 0; i < `B.csi_pkt.size(); i++) g_rx[0].drv.bbuf[i] = `B.csi_pkt[i];
        g_rx[0].drv.blen = `B.csi_pkt.size();
        g_rx[0].drv.send();
      end
      1: begin
        for (int i = 0; i < `B.csi_pkt.size(); i++) g_rx[1].drv.bbuf[i] = `B.csi_pkt[i];
        g_rx[1].drv.blen = `B.csi_pkt.size();
        g_rx[1].drv.send();
      end
      default: begin
        for (int i = 0; i < `B.csi_pkt.size(); i++) g_rx[2].drv.bbuf[i] = `B.csi_pkt[i];
        g_rx[2].drv.blen = `B.csi_pkt.size();
        g_rx[2].drv.send();
      end
    endcase
  endtask

  task automatic set_phy(input int g, input int skew, input int junk);
    case (g)
      0: begin
        g_rx[0].drv.max_skew = skew;
        g_rx[0].drv.max_junk = junk;
      end
      1: begin
        g_rx[1].drv.max_skew = skew;
        g_rx[1].drv.max_junk = junk;
      end
      default: begin
        g_rx[2].drv.max_skew = skew;
        g_rx[2].drv.max_junk = junk;
      end
    endcase
  endtask

  // One frame: FS, embedded data, lines (one on VC1), FE. Error injection by kind.
  task automatic frame(input int g, input int nlines, input int errkind);
    `B.csi_pay.delete(); // frame start
    `B.csi_packet(2'd0, 6'h00, 16'd1);
    send(g);
    for (int i = 0; i < 12; i++) `B.csi_pay.push_back(8'($urandom_range(255)));
    `B.csi_packet(2'd0, 6'h12, 16'(`B.csi_pay.size())); // embedded data: dropped
    send(g);
    for (int ln = 0; ln < nlines; ln++) begin
      int npx, e; // 4..52 pixels
      npx = 4 * (1 + $urandom_range(12));
      `B.csi_px.delete();
      for (int i = 0; i < npx; i++) `B.csi_px.push_back(10'($urandom_range(1023)));
      `B.csi_pack_raw10();
      `B.csi_packet(2'd0, 6'h2B, 16'(`B.csi_pay.size()));
      if (ln == 1 && errkind == 1) begin                                               // 1 header bit
        int k, b;
        k = $urandom_range(2);
        b = $urandom_range(7);
        `B.csi_pkt[k] = `B.csi_pkt[k] ^ (8'd1 << b);
      end
      if (ln == 1 && errkind == 2) begin
        `B.csi_pkt[0] = `B.csi_pkt[0] ^ 8'h01;
        `B.csi_pkt[1] = `B.csi_pkt[1] ^ 8'h08;
      end
      if (ln == 1 && errkind == 3) begin                                               // payload bit
        int k, b;
        k = 4 + $urandom_range(`B.csi_pay.size() - 1);
        b = $urandom_range(7);
        `B.csi_pkt[k] = `B.csi_pkt[k] ^ (8'd1 << b);
        `B.csi_pay[k - 4] = `B.csi_pkt[k];
      end
      if (!(ln == 1 && errkind == 2)) begin
        e = exp_wr[g] % MAXL;
        exp_wr[g]++;
        exp_len[g][e] = `B.csi_pay.size();
        exp_sof[g][e] = (ln == 0);
        for (int i = 0; i < `B.csi_pay.size(); i++) exp_data[g][e][i] = `B.csi_pay[i];
      end
      send(g);
      if (ln == 2) begin // VC1: dropped
        `B.csi_packet(2'd1, 6'h2B, 16'(`B.csi_pay.size()));
        send(g);
      end
    end
    `B.csi_pay.delete(); // frame end
    `B.csi_packet(2'd0, 6'h01, 16'd1);
    send(g);
  endtask
