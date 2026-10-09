// ***************
// Filename: hdmi_tx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the hdmi_tx_tb testbench (hdmi_tx_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check   Counts an error and prints the message when the condition is
//             false
//     frames  Wait for nf complete frames at the sink and check each against
//             the source
//     start
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  // Wait for nf complete frames at the sink and check each against the source
  task automatic frames(input int nf);
    int f0; f0 = sink.frames;
    repeat (nf) begin
      int target; target = sink.frames + 1;
      while (sink.frames < target) @(posedge clk);
      // The frame just ended was produced while fnum had the value of its sof
      check(sink.lines == VA && sink.line_len == HA, $sformatf("geometry %0dx%0d", sink.line_len, sink.lines));
      begin
        int ef; ef = -1;
        // find the frame number that matches pixel (0,0)
        for (int f = fnum - 3; f <= fnum; f++) if (sink.frame[0][0] == pix(0, 0, f)) ef = f;
        check(ef >= 0, "frame number not found");
        if (ef >= 0) for (int yy = 0; yy < VA; yy++) for (int xx = 0; xx < HA; xx++)
          if (sink.frame[yy][xx] !== pix(xx, yy, ef)) begin
            check(0, $sformatf("pixel (%0d,%0d) = %h exp %h", xx, yy, sink.frame[yy][xx], pix(xx, yy, ef)));
            break;
          end
      end
    end
  endtask

  task automatic start(input bit hdmi, input bit p);
    en = 0; mode = hdmi; pol = p; sink_en = 0;
    repeat (5) @(posedge clk);
    sink.hdmi = hdmi; sink.vs_active = p;
    en = 1;
    repeat (3 * (HA + 86)) @(posedge clk);                       // let the pipeline fill
    sink_en = 1;
    begin                                                          // align to a frame boundary
      int f0; f0 = sink.frames;
      while (sink.frames == f0) @(posedge clk);
    end
    sink.frames = 0; sink.islands = 0; sink.avi_frames = 0;
  endtask
