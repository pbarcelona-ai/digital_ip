// ***************
// Filename: ppm_io_pkg.sv
// Author: FPGA Cores 4 U
// Description: Pure-SystemVerilog binary PPM (P6) reader/writer used by
// the no-Python testbench, so it can load/save test images
// without any external tooling dependency.
// Date: September 26, 2026
// ***************
// =============================================================================
// ppm_io_pkg.sv
//
// Minimal binary-PPM (P6) reader/writer for the pure-Verilog testbench.
// Handles the common header forms (optional '#' comment lines, arbitrary
// whitespace between header tokens) produced by this testbench's own
// writer as well as by common external tools (ImageMagick, PIL, GIMP).
//
// Images are stored as three parallel dynamic byte arrays (r/g/b) plus a
// width/height pair, rather than a struct array, to keep indexing simple
// (idx = y*w + x) and avoid any packed-struct portability surprises.
// =============================================================================
package ppm_io_pkg;

  function automatic integer ppm_read_int(input integer fd);
    integer val, ch, back;
    begin
      ch = $fgetc(fd);
      while (ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "#") begin
        if (ch == "#") begin
          while (ch != "\n" && ch != -1) ch = $fgetc(fd);
        end
        ch = $fgetc(fd);
      end
      val = 0;
      while (ch >= "0" && ch <= "9") begin
        val = val * 10 + (ch - "0");
        ch = $fgetc(fd);
      end
      if (ch != -1) back = $ungetc(ch, fd);    // push back the delimiter
      ppm_read_int = val;
    end
  endfunction

  // Reads a P6 PPM file. success=1 if the file could be opened (caller
  // should fall back to generating a synthetic chart if success=0).
  task automatic ppm_read(
    input  string path,
    output int    w,
    output int    h,
    output int    success,
    output logic [7:0] img_r[],
    output logic [7:0] img_g[],
    output logic [7:0] img_b[]
  );
    integer fd, c, maxval, i;
    begin
      fd = $fopen(path, "rb");
      if (fd == 0) begin
        success = 0;
        w = 0;
        h = 0;
      end else begin
      c = $fgetc(fd); // 'P'
      c = $fgetc(fd); // '6'
      w      = ppm_read_int(fd);
      h      = ppm_read_int(fd);
      maxval = ppm_read_int(fd);
      c      = $fgetc(fd); // single whitespace terminating the header

      img_r = new[w * h];
      img_g = new[w * h];
      img_b = new[w * h];
      for (i = 0; i < w * h; i = i + 1) begin
        img_r[i] = $fgetc(fd);
        img_g[i] = $fgetc(fd);
        img_b[i] = $fgetc(fd);
      end
      $fclose(fd);
      success = 1;
      end
    end
  endtask

  task automatic ppm_write(
    input string path,
    input int    w,
    input int    h,
    input logic [7:0] img_r[],
    input logic [7:0] img_g[],
    input logic [7:0] img_b[]
  );
    integer fd, i;
    begin
      fd = $fopen(path, "wb");
      $fwrite(fd, "P6\n%0d %0d\n255\n", w, h);
      for (i = 0; i < w * h; i = i + 1)
        $fwrite(fd, "%c%c%c", img_r[i], img_g[i], img_b[i]);
      $fclose(fd);
    end
  endtask

endpackage
