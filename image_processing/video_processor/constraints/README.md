# constraints

Board timing and pin constraints (XDC / SDC / PDC) go here once a target
FPGA and board are chosen. They need, at minimum:

- the clocks: `pix_clk`, `tmds_ser_clk` (10x, same PLL), `lvds_ser_clk`
  (7x single link / 3.5x dual link, same PLL), `byte_clk` from the D-PHY RX
  and `tx_byte_clk`;
- asynchronous clock groups between `byte_clk`, `tx_byte_clk` and `pix_clk`
  (the crossings are `axis_async_bridge`, `async_fifo`, `pulse_sync` and
  `bit_sync`), and false paths into the `reset_sync` and serializer toggle
  synchronisers (`async_reg` attributes);
- pin locations and IO standards for the HDMI TMDS, LVDS and D-PHY lanes.
