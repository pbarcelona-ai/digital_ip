// ***************
// Filename: gif_io.sv
// Author: FPGA Cores 4 U
// Description: Testbench GIF reader / writer (animated GIF87a / GIF89a),
//   plain SystemVerilog file I/O ($fgetc / $fwrite), no DPI. The frames
//   (w x h, set at run time, at most MAXW x MAXH) are read and written with
//   px(k, x, y) / set_px(k, x, y, v) ({B, G, R}, R in [7:0], the video pixel
//   order of the testbench), their display times in delay_cs[] (1/100 s).
//   info(path, w, h, ok): the logical screen size of a GIF (header only).
//   read(path, tw, th, ok): decodes every image of the file (LZW, global and
//     local colour tables, interlaced images, transparency, disposal
//     methods 0-3) onto the logical screen and stores each composed frame
//     at tw x th (nearest-neighbour resampling when that differs from the
//     file's size, src_w x src_h). At most MAXF frames are kept.
//   alloc(w, h): an empty store of w x h frames (to fill and write; it
//     grows as frames are written, up to MAXF).
//   write(path, n): writes frames 0 .. n-1 with delay_cs[] as an animated
//     GIF89a that loops forever. The global colour table is built from the
//     frames: every colour when there are at most 256; else, with at most
//     64 coloured (non-grey) colours, those first and evenly spaced greys
//     in the rest (exact for a grey image with a few coloured symbols, near
//     otherwise); else (colour video) an adaptive palette: the symbol colours
//     (every component 0, 128 or 255: overlay boxes and texts) exactly, then
//     the most used colours (5-bit-per-component buckets, each its mean
//     colour), each pixel the nearest entry. coded(c) is the colour a pixel
//     of colour c is written as (the round trip of a written GIF). The image
//     data is LZW compressed (hash table dictionary, 12-bit codes, a clear
//     code when the table is full).
//   Called hierarchically from the testbench (gif.read(...)); tasks only
//   use module arrays (Icarus passes no arrays as arguments).
// Date: 2026-10-14
`timescale 1ns/1ps
module gif_io #(
  parameter int MAXW = 320,                      // largest stored frame
  parameter int MAXH = 240,
  parameter int MAXF = 64                        // frames kept
);
  bit [23:0] frame [];                           // frame k, line y, pixel x at (k * h + y) * w + x
  int delay_cs [MAXF];
  int w = 0, h = 0;                              // stored frame size
  int nframes = 0, src_w = 0, src_h = 0;

  function automatic bit [23:0] px(input int k, input int x, input int y);
    return frame[(k * h + y) * w + x];
  endfunction
  task automatic set_px(input int k, input int x, input int y, input bit [23:0] v);
    if ((k + 1) * w * h > frame.size()) grow(k);
    frame[(k * h + y) * w + x] = v;
  endtask
  // the store grows as frames are written (memory for the frames used, not MAXF of them)
  task automatic grow(input int k);
    int n;
    n = frame.size() / (w * h);
    if (n < 1) n = 1;
    while (n < k + 1) n = n * 2;
    if (n > MAXF) n = MAXF;
    frame = new[n * w * h](frame);
  endtask
  task automatic alloc(input int fw, input int fh);
    w = (fw < 1) ? 1 : (fw > MAXW) ? MAXW : fw;
    h = (fh < 1) ? 1 : (fh > MAXH) ? MAXH : fh;
    frame = new[w * h];
  endtask
  string comment = "";                           // written as a comment extension when not empty

  // ================================================================ reader
  byte unsigned fb [];                           // the whole file
  int fpos, flen;
  logic [23:0] gpal [256];
  logic [23:0] lpal [256];
  logic [23:0] canvas [];
  logic [23:0] saved [];
  byte unsigned lzw [];                          // image data (sub-blocks joined)
  int lzw_n;
  byte unsigned idx [];                          // decoded colour indices of one image
  int prefix [4096];
  byte unsigned suffix [4096];
  byte unsigned stk [4097];

  function automatic int rd8();
    if (fpos >= flen) return -1;
    fpos++;
    return int'(fb[fpos-1]);
  endfunction
  function automatic int rd16();
    int lo;
    lo = rd8();
    return lo | (rd8() << 8);
  endfunction

  task automatic skip_blocks();                  // data sub-blocks up to the terminator
    int n;
    n = rd8();
    while (n > 0) begin
      fpos += n;
      n = rd8();
    end
  endtask

  // LZW decode of lzw[0 .. lzw_n-1] (minimum code size mcs) into idx[0 .. npx-1]; returns indices made
  task automatic lzw_decode(input int mcs, input int npx, output int got);
    int clear, eoi, width, nxt, old, code, in_code, sp, bitpos;
    byte unsigned first;
    clear = 1 << mcs;
    eoi = clear + 1;
    width = mcs + 1;
    nxt = eoi + 1;
    old = -1;
    first = 0;
    got = 0;
    bitpos = 0;
    for (int i = 0; i < clear; i++) begin
      prefix[i] = -1;
      suffix[i] = 8'(i);
    end
    while (got < npx && bitpos + width <= lzw_n * 8) begin
      code = 0;
      for (int b = 0; b < width; b++) begin
        code |= ((lzw[(bitpos + b) >> 3] >> ((bitpos + b) & 7)) & 1) << b;
      end
      bitpos += width;
      if (code == clear) begin
        width = mcs + 1;
        nxt = eoi + 1;
        old = -1;
        continue;
      end
      if (code == eoi) break;
      if (old < 0) begin                         // first code after a clear: a single index
        if (code >= clear) break;                // corrupt stream
        idx[got] = 8'(code);
        got++;
        first = 8'(code);
        old = code;
        continue;
      end
      in_code = code;
      sp = 0;
      if (code >= nxt) begin                     // the code being defined: old string + its first index
        stk[sp] = first;
        sp++;
        code = old;
      end
      while (code >= clear && sp < 4096) begin
        stk[sp] = suffix[code];
        sp++;
        code = prefix[code];
      end
      first = 8'(code);
      stk[sp] = first;
      sp++;
      while (sp > 0 && got < npx) begin
        sp--;
        idx[got] = stk[sp];
        got++;
      end
      if (nxt < 4096) begin
        prefix[nxt] = old;
        suffix[nxt] = first;
        nxt++;
        if (nxt == (1 << width) && width < 12) width++;
      end
      old = in_code;
    end
  endtask

  // logical screen size of a GIF (bytes 6-9)
  task automatic info(input string path, output int fw, output int fh, output bit ok);
    int fd, b [10];
    ok = 0;
    fw = 0;
    fh = 0;
    fd = $fopen(path, "rb");
    if (fd == 0) return;
    for (int i = 0; i < 10; i++) b[i] = $fgetc(fd);
    $fclose(fd);
    if (b[0] != "G" || b[1] != "I" || b[2] != "F") return;
    fw = b[6] | (b[7] << 8);
    fh = b[8] | (b[9] << 8);
    ok = fw > 0 && fh > 0;
  endtask

  task automatic read(input string path, input int tw, input int th, output bit ok);
    int fd, c, pk, gct_n, bg, dispose, transp, delay, n;
    logic [23:0] bgc;
    ok = 0;
    nframes = 0;
    fd = $fopen(path, "rb");
    if (fd == 0) return;
    flen = 0;
    fb = new[1 << 16];
    c = $fgetc(fd);
    while (c != -1) begin
      if (flen == fb.size()) fb = new[fb.size() * 2](fb);
      fb[flen] = 8'(c);
      flen++;
      c = $fgetc(fd);
    end
    $fclose(fd);
    fpos = 0;
    if (flen < 13 || fb[0] != "G" || fb[1] != "I" || fb[2] != "F") begin
      $display("ERROR: %s: not a GIF file", path);
      return;
    end
    fpos = 6;
    src_w = rd16();
    src_h = rd16();
    pk = rd8();
    bg = rd8();
    void'(rd8());                                // aspect ratio
    gct_n = (pk & 8'h80) ? (2 << (pk & 7)) : 0;
    for (int i = 0; i < 256; i++) gpal[i] = '0;
    for (int i = 0; i < gct_n; i++) begin
      logic [7:0] r, g, b;
      r = 8'(rd8());
      g = 8'(rd8());
      b = 8'(rd8());
      gpal[i] = {b, g, r};
    end
    bgc = gct_n ? gpal[bg] : '0;
    alloc(tw > 0 ? tw : src_w, th > 0 ? th : src_h);
    canvas = new[src_w * src_h];
    saved = new[src_w * src_h];
    foreach (canvas[i]) canvas[i] = bgc;
    dispose = 0;
    transp = -1;
    delay = 0;
    while (fpos < flen && nframes < MAXF) begin
      c = rd8();
      if (c == 8'h3B || c < 0) break;            // trailer
      if (c == 8'h21) begin                      // extension
        c = rd8();
        if (c == 8'hF9) begin                    // graphic control: disposal, delay, transparency
          void'(rd8());
          pk = rd8();
          delay = rd16();
          n = rd8();
          dispose = (pk >> 2) & 7;
          transp = (pk & 1) ? n : -1;
          skip_blocks();
        end else skip_blocks();                  // application, comment, plain text
      end else if (c == 8'h2C) begin             // image
        int il, it, iw, ih, lct_n, interlace, mcs, got, row, pass_row, pass;
        il = rd16();
        it = rd16();
        iw = rd16();
        ih = rd16();
        pk = rd8();
        lct_n = (pk & 8'h80) ? (2 << (pk & 7)) : 0;
        interlace = (pk >> 6) & 1;
        for (int i = 0; i < lct_n; i++) begin
          logic [7:0] r, g, b;
          r = 8'(rd8());
          g = 8'(rd8());
          b = 8'(rd8());
          lpal[i] = {b, g, r};
        end
        mcs = rd8();
        lzw = new[flen - fpos];
        lzw_n = 0;
        n = rd8();
        while (n > 0) begin
          for (int i = 0; i < n; i++) begin
            lzw[lzw_n] = 8'(rd8());
            lzw_n++;
          end
          n = rd8();
        end
        idx = new[iw * ih];
        if (mcs < 2 || mcs > 8) begin
          $display("ERROR: %s: image %0d: bad LZW code size %0d", path, nframes, mcs);
          return;
        end
        lzw_decode(mcs, iw * ih, got);
        if (got < iw * ih) $display("  %s: image %0d: %0d of %0d pixels decoded", path, nframes, got, iw * ih);
        if (dispose == 3) foreach (canvas[i]) saved[i] = canvas[i];
        // draw: interlaced rows come in passes (every 8th from 0, every 8th from 4, every 4th from
        // 2, every 2nd from 1)
        pass = 0;
        pass_row = 0;
        for (int r = 0; r < ih; r++) begin
          if (!interlace) row = r;
          else begin
            while (pass_row >= ih) begin
              pass++;
              pass_row = (pass == 1) ? 4 : (pass == 2) ? 2 : 1;
            end
            row = pass_row;
            pass_row += (pass < 2) ? 8 : (pass == 2) ? 4 : 2;
          end
          for (int x = 0; x < iw; x++) begin
            int k, cx, cy;
            k = idx[r * iw + x];
            cx = il + x;
            cy = it + row;
            if (r * iw + x < got && k != transp && cx < src_w && cy < src_h)
              canvas[cy * src_w + cx] = lct_n ? lpal[k] : gpal[k];
          end
        end
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
          set_px(nframes, x, y, canvas[(y * src_h / h) * src_w + x * src_w / w]);
        delay_cs[nframes] = delay;
        nframes++;
        // disposal of this image before the next one
        if (dispose == 2) begin
          for (int y = it; y < it + ih && y < src_h; y++) for (int x = il; x < il + iw && x < src_w; x++)
            canvas[y * src_w + x] = bgc;
        end else if (dispose == 3) foreach (canvas[i]) canvas[i] = saved[i];
        dispose = 0;
        transp = -1;
        delay = 0;
      end else begin
        $display("ERROR: %s: unknown block 0x%02h at byte %0d", path, c, fpos - 1);
        return;
      end
    end
    if (src_w != w || src_h != h) $display("  %s: %0d x %0d resampled to %0d x %0d", path, src_w, src_h, w, h);
    ok = nframes > 0;
  endtask

  // ================================================================ writer
  logic [23:0] pal [256];
  int npal;
  bit cube = 0;                                  // adaptive palette (colour video): bucket lookup lut[]
  int lut [32768];                               // 5:5:5 bucket -> nearest palette index (-1: not yet)
  int hist [32768];                              // bucket counts and colour sums (palette build)
  longint hs_r [32768], hs_g [32768], hs_b [32768];
  int hkey [8192];                               // colour -> palette index (open addressing)
  int hval [8192];
  int dkey [8192];                               // LZW dictionary: prefix code << 8 | index -> code
  int dval [8192];
  byte unsigned ob [];                           // compressed bytes of one image
  int ob_n, acc, nacc;

  function automatic int hslot(input int key);
    return ((key * 40503) ^ (key >> 7)) & 8191;
  endfunction
  function automatic int col_find(input logic [23:0] c);   // palette index or -1
    int hs;
    hs = hslot(int'(c));
    while (hkey[hs] != -1) begin
      if (hkey[hs] == int'(c)) return hval[hs];
      hs = (hs + 1) & 8191;
    end
    return -1;
  endfunction
  task automatic col_add(input logic [23:0] c, input int v);
    int hs;
    hs = hslot(int'(c));
    while (hkey[hs] != -1 && hkey[hs] != int'(c)) hs = (hs + 1) & 8191;
    hkey[hs] = int'(c);
    hval[hs] = v;
  endtask
  function automatic bit sym_col(input logic [23:0] c);   // overlay symbol / text colour: components 0, 128, 255
    for (int j = 0; j < 3; j++) if (c[8*j +: 8] != 0 && c[8*j +: 8] != 128 && c[8*j +: 8] != 255) return 0;
    return 1;
  endfunction
  function automatic bit is_grey(input logic [23:0] c);
    return c[7:0] == c[15:8] && c[15:8] == c[23:16];
  endfunction

  // palette index of a colour: exact, else the nearest entry (sum of absolute differences)
  function automatic int col_index(input logic [23:0] c);
    int k, best, bd, d;
    if (cube) begin                                // symbol colours exact, the rest by bucket
      k = col_find(c);
      if (k >= 0) return k;
      k = bucket(c);
      if (lut[k] < 0) lut[k] = nearest(c);
      return lut[k];
    end
    k = col_find(c);
    if (k >= 0) return k;
    return nearest(c);
  endfunction
  function automatic int bucket(input logic [23:0] c);
    return int'(c[7:3]) | (int'(c[15:11]) << 5) | (int'(c[23:19]) << 10);
  endfunction
  // the colour pixel c is written as
  function automatic logic [23:0] coded(input logic [23:0] c);
    return pal[col_index(c)];
  endfunction
  function automatic int nearest(input logic [23:0] c);
    int best, bd, d;
    best = 0;
    bd = 1 << 30;
    for (int i = 0; i < npal; i++) begin
      d = 0;
      for (int j = 0; j < 3; j++) begin
        int a, b;
        a = c[8*j +: 8];
        b = pal[i][8*j +: 8];
        d += (a > b) ? a - b : b - a;
      end
      if (d < bd) begin
        bd = d;
        best = i;
      end
    end
    return best;
  endfunction

  task automatic build_palette(input int n);
    int ncol, ng, uniq;
    for (int i = 0; i < 8192; i++) hkey[i] = -1;
    cube = 0;
    uniq = 0;                                    // every distinct colour, while there are <= 256
    for (int i = 0; i < n * w * h && uniq <= 256; i++)
      if (col_find(frame[i]) < 0) begin
        if (uniq < 256) pal[uniq] = frame[i];
        col_add(frame[i], uniq);
        uniq++;
      end
    if (uniq <= 256) begin
      npal = uniq;
      return;
    end
    // too many: the coloured ones (up to 64), then evenly spaced greys
    for (int i = 0; i < 8192; i++) hkey[i] = -1;
    ncol = 0;
    cube = 0;
    for (int i = 0; i < n * w * h && !cube; i++)
      if (!is_grey(frame[i]) && col_find(frame[i]) < 0) begin
        if (ncol == 64) cube = 1;                  // colour video: cube + greys
        else begin
          pal[ncol] = frame[i];
          col_add(frame[i], ncol);
          ncol++;
        end
      end
    if (cube) begin                                // adaptive: symbol colours, then the most used buckets
      int nk;
      for (int i = 0; i < 8192; i++) hkey[i] = -1;
      for (int i = 0; i < 32768; i++) begin
        hist[i] = 0;
        hs_r[i] = 0;
        hs_g[i] = 0;
        hs_b[i] = 0;
        lut[i] = -1;
      end
      nk = 0;
      for (int i = 0; i < n * w * h; i++) begin
        logic [23:0] c;
        int b;
        c = frame[i];
        if (nk < 24 && sym_col(c) && col_find(c) < 0) begin
          pal[nk] = c;
          col_add(c, nk);
          nk++;
        end
        b = bucket(c);
        hist[b]++;
        hs_r[b] += c[7:0];
        hs_g[b] += c[15:8];
        hs_b[b] += c[23:16];
      end
      npal = nk;
      while (npal < 256) begin                     // the most used bucket left, as its mean colour
        int bi, bc;
        bi = -1;
        bc = 0;
        for (int i = 0; i < 32768; i++) if (hist[i] > bc) begin
          bc = hist[i];
          bi = i;
        end
        if (bi < 0) break;
        pal[npal] = {8'(hs_b[bi] / bc), 8'(hs_g[bi] / bc), 8'(hs_r[bi] / bc)};
        hist[bi] = 0;
        npal++;
      end
      for (int i = npal; i < 256; i++) pal[i] = '0;
      npal = (npal < 1) ? 1 : npal;
      return;
    end
    ng = 256 - ncol;
    for (int i = 0; i < ng; i++) begin
      logic [7:0] g;
      g = 8'((i * 255 + (ng - 1) / 2) / (ng - 1));
      pal[ncol + i] = {g, g, g};
      if (col_find({g, g, g}) < 0) col_add({g, g, g}, ncol + i);
    end
    npal = 256;
  endtask

  task automatic emit(input int code, input int width);
    acc |= code << nacc;
    nacc += width;
    while (nacc >= 8) begin
      ob[ob_n] = 8'(acc);
      ob_n++;
      acc >>= 8;
      nacc -= 8;
    end
  endtask

  // LZW compression of frame f (8-bit indices) into ob[0 .. ob_n-1]
  task automatic lzw_encode(input int f);
    int clear, eoi, width, nxt, cur, k, key, hs, found;
    clear = 256;
    eoi = 257;
    ob = new[w * h * 2 + 16];
    ob_n = 0;
    acc = 0;
    nacc = 0;
    width = 9;
    nxt = eoi + 1;
    for (int i = 0; i < 8192; i++) dkey[i] = -1;
    emit(clear, width);
    cur = col_index(frame[f * w * h]);
    for (int p = 1; p < w * h; p++) begin
      k = col_index(frame[f * w * h + p]);
      key = (cur << 8) | k;
      hs = hslot(key);
      found = -1;
      while (dkey[hs] != -1) begin
        if (dkey[hs] == key) begin
          found = dval[hs];
          break;
        end
        hs = (hs + 1) & 8191;
      end
      if (found >= 0) cur = found;
      else begin
        emit(cur, width);
        if (nxt < 4096) begin
          dkey[hs] = key;
          dval[hs] = nxt;
          nxt++;
          if (nxt - 1 == (1 << width) && width < 12) width++;
        end else begin                           // dictionary full: start again
          emit(clear, width);
          for (int i = 0; i < 8192; i++) dkey[i] = -1;
          nxt = eoi + 1;
          width = 9;
        end
        cur = k;
      end
    end
    emit(cur, width);
    emit(eoi, width);
    if (nacc > 0) begin
      ob[ob_n] = 8'(acc);
      ob_n++;
    end
  endtask

  task automatic wr16(input int fd, input int v);
    $fwrite(fd, "%c%c", 8'(v), 8'(v >> 8));
  endtask

  task automatic write(input string path, input int n, output bit ok);
    int fd;
    ok = 0;
    if (n < 1) return;
    fd = $fopen(path, "wb");
    if (fd == 0) begin
      $display("ERROR: cannot write %s (does its directory exist?)", path);
      return;
    end
    build_palette(n);
    $fwrite(fd, "GIF89a");
    wr16(fd, w);
    wr16(fd, h);
    $fwrite(fd, "%c%c%c", 8'hF7, 8'h00, 8'h00);  // 256-entry global colour table, 8 bits per primary
    for (int i = 0; i < 256; i++)
      if (i < npal) $fwrite(fd, "%c%c%c", pal[i][7:0], pal[i][15:8], pal[i][23:16]);
      else $fwrite(fd, "%c%c%c", 8'h00, 8'h00, 8'h00);
    $fwrite(fd, "%c%c%c", 8'h21, 8'hFF, 8'h0B);  // NETSCAPE2.0: loop forever
    $fwrite(fd, "NETSCAPE2.0");
    $fwrite(fd, "%c%c%c%c%c", 8'h03, 8'h01, 8'h00, 8'h00, 8'h00);
    if (comment.len() > 0 && comment.len() < 256) begin
      int cl;
      cl = comment.len();
      $fwrite(fd, "%c%c%c", 8'h21, 8'hFE, 8'(cl));
      $fwrite(fd, "%s", comment);
      $fwrite(fd, "%c", 8'h00);
    end
    for (int f = 0; f < n; f++) begin
      $fwrite(fd, "%c%c%c%c", 8'h21, 8'hF9, 8'h04, 8'h04);   // graphic control: keep, delay
      wr16(fd, delay_cs[f]);
      $fwrite(fd, "%c%c", 8'h00, 8'h00);
      $fwrite(fd, "%c", 8'h2C);                  // image: whole screen, no local table
      wr16(fd, 0);
      wr16(fd, 0);
      wr16(fd, w);
      wr16(fd, h);
      $fwrite(fd, "%c%c", 8'h00, 8'h08);         // pk, LZW minimum code size 8
      lzw_encode(f);
      for (int i = 0; i < ob_n; i += 255) begin
        int len;
        len = (ob_n - i > 255) ? 255 : ob_n - i;
        $fwrite(fd, "%c", 8'(len));
        for (int j = 0; j < len; j++) $fwrite(fd, "%c", ob[i + j]);
      end
      $fwrite(fd, "%c", 8'h00);
    end
    $fwrite(fd, "%c", 8'h3B);
    $fclose(fd);
    ok = 1;
  endtask
endmodule
