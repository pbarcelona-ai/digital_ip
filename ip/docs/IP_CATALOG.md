# IP catalog

Generated from `scripts/ips.csv`, RTL headers, and scaler module READMEs.

| IP | Category | Top module | Testbench |
|---|---|---|---|
| [reset_ctrl](../cdc/reset_ctrl/docs/index.html) | cdc | `ip_reset_sync_top` | [`reset_ctrl_tb.sv`](../cdc/reset_ctrl/tb/reset_ctrl_tb.sv) |
| [baud_nco](../timing/baud_nco/docs/index.html) | timing | `baud_nco_top` | [`baud_nco_tb.sv`](../timing/baud_nco/tb/baud_nco_tb.sv) |
| [uart](../peripherals/uart/docs/index.html) | peripherals | `uart_top` | [`uart_tb.sv`](../peripherals/uart/tb/uart_tb.sv) |
| [i2c_master](../peripherals/i2c_master/docs/index.html) | peripherals | `i2c_top` | [`i2c_master_tb.sv`](../peripherals/i2c_master/tb/i2c_master_tb.sv) |
| [spi_master](../peripherals/spi_master/docs/index.html) | peripherals | `spi_top` | [`spi_master_tb.sv`](../peripherals/spi_master/tb/spi_master_tb.sv) |
| [gpio](../peripherals/gpio/docs/index.html) | peripherals | `gpio_top` | [`gpio_tb.sv`](../peripherals/gpio/tb/gpio_tb.sv) |
| [intc](../peripherals/intc/docs/index.html) | peripherals | `intc_top` | [`intc_tb.sv`](../peripherals/intc/tb/intc_tb.sv) |
| [pwm](../timing/pwm/docs/index.html) | timing | `pwm_top` | [`pwm_tb.sv`](../timing/pwm/tb/pwm_tb.sv) |
| [quadrature_decoder](../peripherals/quadrature_decoder/docs/index.html) | peripherals | `quad_dec_top` | [`quadrature_decoder_tb.sv`](../peripherals/quadrature_decoder/tb/quadrature_decoder_tb.sv) |
| [watchdog](../timing/watchdog/docs/index.html) | timing | `watchdog_top` | [`watchdog_tb.sv`](../timing/watchdog/tb/watchdog_tb.sv) |
| [edge_event_capture](../peripherals/edge_event_capture/docs/index.html) | peripherals | `edge_event_capture_top` | [`edge_event_capture_tb.sv`](../peripherals/edge_event_capture/tb/edge_event_capture_tb.sv) |
| [async_fifo](../fifo/async_fifo/docs/index.html) | fifo | `async_fifo` | [`async_fifo_tb.sv`](../fifo/async_fifo/tb/async_fifo_tb.sv) |
| [axis_async_bridge](../cdc/axis_async_bridge/docs/index.html) | cdc | `axis_async_bridge` | [`axis_async_bridge_tb.sv`](../cdc/axis_async_bridge/tb/axis_async_bridge_tb.sv) |
| [axi4_lite_cdc](../cdc/axi4_lite_cdc/docs/index.html) | cdc | `axi4_lite_cdc` | [`axi4_lite_cdc_tb.sv`](../cdc/axi4_lite_cdc/tb/axi4_lite_cdc_tb.sv) |
| [dma_engine](../bus/dma_engine/docs/index.html) | bus | `dma_engine` | [`dma_engine_tb.sv`](../bus/dma_engine/tb/dma_engine_tb.sv) |
| [axis_dma](../bus/axis_dma/docs/index.html) | bus | `axis_dma` | [`axis_dma_tb.sv`](../bus/axis_dma/tb/axis_dma_tb.sv) |
| [bit_sync](../cdc/bit_sync/docs/index.html) | cdc | `bit_sync` | [`bit_sync_tb.sv`](../cdc/bit_sync/tb/bit_sync_tb.sv) |
| [toggle_sync](../cdc/toggle_sync/docs/index.html) | cdc | `toggle_sync` | [`toggle_sync_tb.sv`](../cdc/toggle_sync/tb/toggle_sync_tb.sv) |
| [pulse_sync](../cdc/pulse_sync/docs/index.html) | cdc | `pulse_sync` | [`pulse_sync_tb.sv`](../cdc/pulse_sync/tb/pulse_sync_tb.sv) |
| [reset_sync](../cdc/reset_sync/docs/index.html) | cdc | `reset_sync` | [`reset_sync_tb.sv`](../cdc/reset_sync/tb/reset_sync_tb.sv) |
| [edge_detect](../common/edge_detect/docs/index.html) | common | `edge_detect` | [`edge_detect_tb.sv`](../common/edge_detect/tb/edge_detect_tb.sv) |
| [clock_enable](../timing/clock_enable/docs/index.html) | timing | `clock_enable` | [`clock_enable_tb.sv`](../timing/clock_enable/tb/clock_enable_tb.sv) |
| [counter](../timing/counter/docs/index.html) | timing | `counter` | [`counter_tb.sv`](../timing/counter/tb/counter_tb.sv) |
| [timeout_timer](../timing/timeout_timer/docs/index.html) | timing | `timeout_timer` | [`timeout_timer_tb.sv`](../timing/timeout_timer/tb/timeout_timer_tb.sv) |
| [priority_encoder](../common/priority_encoder/docs/index.html) | common | `priority_encoder` | [`priority_encoder_tb.sv`](../common/priority_encoder/tb/priority_encoder_tb.sv) |
| [onehot_decoder](../common/onehot_decoder/docs/index.html) | common | `onehot_decoder` | [`onehot_decoder_tb.sv`](../common/onehot_decoder/tb/onehot_decoder_tb.sv) |
| [single_port_ram](../memory/single_port_ram/docs/index.html) | memory | `single_port_ram` | [`single_port_ram_tb.sv`](../memory/single_port_ram/tb/single_port_ram_tb.sv) |
| [simple_dual_port_ram](../memory/simple_dual_port_ram/docs/index.html) | memory | `simple_dual_port_ram` | [`simple_dual_port_ram_tb.sv`](../memory/simple_dual_port_ram/tb/simple_dual_port_ram_tb.sv) |
| [true_dual_port_ram](../memory/true_dual_port_ram/docs/index.html) | memory | `true_dual_port_ram` | [`true_dual_port_ram_tb.sv`](../memory/true_dual_port_ram/tb/true_dual_port_ram_tb.sv) |
| [rom](../memory/rom/docs/index.html) | memory | `rom` | [`rom_tb.sv`](../memory/rom/tb/rom_tb.sv) |
| [register_file](../memory/register_file/docs/index.html) | memory | `register_file` | [`register_file_tb.sv`](../memory/register_file/tb/register_file_tb.sv) |
| [sync_fifo](../fifo/sync_fifo/docs/index.html) | fifo | `sync_fifo` | [`sync_fifo_tb.sv`](../fifo/sync_fifo/tb/sync_fifo_tb.sv) |
| [fallthrough_fifo](../fifo/fallthrough_fifo/docs/index.html) | fifo | `fallthrough_fifo` | [`fallthrough_fifo_tb.sv`](../fifo/fallthrough_fifo/tb/fallthrough_fifo_tb.sv) |
| [packet_fifo](../fifo/packet_fifo/docs/index.html) | fifo | `packet_fifo` | [`packet_fifo_tb.sv`](../fifo/packet_fifo/tb/packet_fifo_tb.sv) |
| [memory_arbiter](../memory/memory_arbiter/docs/index.html) | memory | `memory_arbiter` | [`memory_arbiter_tb.sv`](../memory/memory_arbiter/tb/memory_arbiter_tb.sv) |
| [nco](../timing/nco/docs/index.html) | timing | `nco` | [`nco_tb.sv`](../timing/nco/tb/nco_tb.sv) |
| [baud_generator](../timing/baud_generator/docs/index.html) | timing | `baud_generator` | [`baud_generator_tb.sv`](../timing/baud_generator/tb/baud_generator_tb.sv) |
| [pulse_generator](../timing/pulse_generator/docs/index.html) | timing | `pulse_generator` | [`pulse_generator_tb.sv`](../timing/pulse_generator/tb/pulse_generator_tb.sv) |
| [frequency_counter](../timing/frequency_counter/docs/index.html) | timing | `frequency_counter` | [`frequency_counter_tb.sv`](../timing/frequency_counter/tb/frequency_counter_tb.sv) |
| [timestamp_counter](../timing/timestamp_counter/docs/index.html) | timing | `timestamp_counter` | [`timestamp_counter_tb.sv`](../timing/timestamp_counter/tb/timestamp_counter_tb.sv) |
| [rate_limiter](../timing/rate_limiter/docs/index.html) | timing | `rate_limiter` | [`rate_limiter_tb.sv`](../timing/rate_limiter/tb/rate_limiter_tb.sv) |
| [interval_timer](../timing/interval_timer/docs/index.html) | timing | `interval_timer` | [`interval_timer_tb.sv`](../timing/interval_timer/tb/interval_timer_tb.sv) |
| [axi4_lite_slave](../bus/axi4_lite_slave/docs/index.html) | bus | `axi4_lite_slave` | [`axi4_lite_slave_tb.sv`](../bus/axi4_lite_slave/tb/axi4_lite_slave_tb.sv) |
| [axi4_lite_regs](../bus/axi4_lite_regs/docs/index.html) | bus | `axi4_lite_regs` | [`axi4_lite_regs_tb.sv`](../bus/axi4_lite_regs/tb/axi4_lite_regs_tb.sv) |
| [axi4_lite_decoder](../bus/axi4_lite_decoder/docs/index.html) | bus | `axi4_lite_decoder` | [`axi4_lite_decoder_tb.sv`](../bus/axi4_lite_decoder/tb/axi4_lite_decoder_tb.sv) |
| [axi4_lite_mux](../bus/axi4_lite_mux/docs/index.html) | bus | `axi4_lite_mux` | [`axi4_lite_mux_tb.sv`](../bus/axi4_lite_mux/tb/axi4_lite_mux_tb.sv) |
| [axi_stream_fifo](../bus/axi_stream_fifo/docs/index.html) | bus | `axi_stream_fifo` | [`axi_stream_fifo_tb.sv`](../bus/axi_stream_fifo/tb/axi_stream_fifo_tb.sv) |
| [axi_stream_width_converter](../bus/axi_stream_width_converter/docs/index.html) | bus | `axi_stream_width_converter` | [`axi_stream_width_converter_tb.sv`](../bus/axi_stream_width_converter/tb/axi_stream_width_converter_tb.sv) |
| [axi_stream_arbiter](../bus/axi_stream_arbiter/docs/index.html) | bus | `axi_stream_arbiter` | [`axi_stream_arbiter_tb.sv`](../bus/axi_stream_arbiter/tb/axi_stream_arbiter_tb.sv) |
| [parity_gen](../integrity/parity_gen/docs/index.html) | integrity | `parity_gen` | [`parity_gen_tb.sv`](../integrity/parity_gen/tb/parity_gen_tb.sv) |
| [parity_check](../integrity/parity_check/docs/index.html) | integrity | `parity_check` | [`parity_check_tb.sv`](../integrity/parity_check/tb/parity_check_tb.sv) |
| [crc8](../integrity/crc8/docs/index.html) | integrity | `crc8` | [`crc8_tb.sv`](../integrity/crc8/tb/crc8_tb.sv) |
| [crc16](../integrity/crc16/docs/index.html) | integrity | `crc16` | [`crc16_tb.sv`](../integrity/crc16/tb/crc16_tb.sv) |
| [crc32](../integrity/crc32/docs/index.html) | integrity | `crc32` | [`crc32_tb.sv`](../integrity/crc32/tb/crc32_tb.sv) |
| [checksum](../integrity/checksum/docs/index.html) | integrity | `checksum` | [`checksum_tb.sv`](../integrity/checksum/tb/checksum_tb.sv) |
| [lfsr](../integrity/lfsr/docs/index.html) | integrity | `lfsr` | [`lfsr_tb.sv`](../integrity/lfsr/tb/lfsr_tb.sv) |
| [error_status](../integrity/error_status/docs/index.html) | integrity | `error_status` | [`error_status_tb.sv`](../integrity/error_status/tb/error_status_tb.sv) |
| [spi_slave](../peripherals/spi_slave/docs/index.html) | peripherals | `spi_slave` | [`spi_slave_tb.sv`](../peripherals/spi_slave/tb/spi_slave_tb.sv) |
| [clock_domain_bridge](../cdc/clock_domain_bridge/docs/index.html) | cdc | `clock_domain_bridge` | [`clock_domain_bridge_tb.sv`](../cdc/clock_domain_bridge/tb/clock_domain_bridge_tb.sv) |
| [uart_tx](../peripherals/uart_tx/docs/index.html) | peripherals | `uart_tx` | [`uart_tx_tb.sv`](../peripherals/uart_tx/tb/uart_tx_tb.sv) |
| [uart_rx](../peripherals/uart_rx/docs/index.html) | peripherals | `uart_rx` | [`uart_rx_tb.sv`](../peripherals/uart_rx/tb/uart_rx_tb.sv) |
| [cordic](../common/cordic/docs/index.html) | common | `cordic` | [`cordic_tb.sv`](../common/cordic/tb/cordic_tb.sv) |
| [dds](../common/dds/docs/index.html) | common | `dds` | [`dds_tb.sv`](../common/dds/tb/dds_tb.sv) |
| [fir](../common/fir/docs/index.html) | common | `fir` | [`fir_tb.sv`](../common/fir/tb/fir_tb.sv) |
| [cic](../common/cic/docs/index.html) | common | `cic` | [`cic_tb.sv`](../common/cic/tb/cic_tb.sv) |
| [ecc_memory_ctrl](../integrity/ecc_memory_ctrl/docs/index.html) | integrity | `ecc_memory_ctrl` | [`ecc_memory_ctrl_tb.sv`](../integrity/ecc_memory_ctrl/tb/ecc_memory_ctrl_tb.sv) |
| [packet_parser](../bus/packet_parser/docs/index.html) | bus | `packet_parser` | [`packet_parser_tb.sv`](../bus/packet_parser/tb/packet_parser_tb.sv) |
| [packet_formatter](../bus/packet_formatter/docs/index.html) | bus | `packet_formatter` | [`packet_formatter_tb.sv`](../bus/packet_formatter/tb/packet_formatter_tb.sv) |
| [i2s](../peripherals/i2s/docs/index.html) | peripherals | `i2s` | [`i2s_tb.sv`](../peripherals/i2s/tb/i2s_tb.sv) |
| [eth_mac_if](../peripherals/eth_mac_if/docs/index.html) | peripherals | `eth_mac_if` | [`eth_mac_if_tb.sv`](../peripherals/eth_mac_if/tb/eth_mac_if_tb.sv) |
| [spi_flash_ctrl](../peripherals/spi_flash_ctrl/docs/index.html) | peripherals | `spi_flash_ctrl` | [`spi_flash_ctrl_tb.sv`](../peripherals/spi_flash_ctrl/tb/spi_flash_ctrl_tb.sv) |
| [sdio_host](../peripherals/sdio_host/docs/index.html) | peripherals | `sdio_host` | [`sdio_host_tb.sv`](../peripherals/sdio_host/tb/sdio_host_tb.sv) |
| [demo_regs](../bus/demo_regs/docs/index.html) | bus | `demo_regs` | [`demo_regs_tb.sv`](../bus/demo_regs/tb/demo_regs_tb.sv) |
| [pcie_tl_ep](../peripherals/pcie_tl_ep/docs/index.html) | peripherals | `pcie_tl_ep_top` | [`pcie_tl_ep_tb.sv`](../peripherals/pcie_tl_ep/tb/pcie_tl_ep_tb.sv) |
| [usb_fs_sie](../peripherals/usb_fs_sie/docs/index.html) | peripherals | `usb_fs_sie_top` | [`usb_fs_sie_tb.sv`](../peripherals/usb_fs_sie/tb/usb_fs_sie_tb.sv) |
| [axi_checkers](../scalers/axi_checkers/docs/index.html) | scalers | `axis_checker` | [`axi_checkers_tb.sv`](../scalers/axi_checkers/tb/axi_checkers_tb.sv) |
| [axil_regbus](../scalers/axil_regbus/docs/index.html) | scalers | `axil_regbus` | [`axil_regbus_tb.sv`](../scalers/axil_regbus/tb/axil_regbus_tb.sv) |
| [axil_split](../scalers/axil_split/docs/index.html) | scalers | `axil_split` | [`axil_split_tb.sv`](../scalers/axil_split/tb/axil_split_tb.sv) |
| [banked_framebuf](../scalers/banked_framebuf/docs/index.html) | scalers | `banked_framebuf` | [`banked_framebuf_tb.sv`](../scalers/banked_framebuf/tb/banked_framebuf_tb.sv) |
| [scaler_anisotropic](../scalers/scaler_anisotropic/docs/index.html) | scalers | `scaler_anisotropic` | [`scaler_anisotropic_tb.sv`](../scalers/scaler_anisotropic/tb/scaler_anisotropic_tb.sv) |
| [scaler_bicubic](../scalers/scaler_bicubic/docs/index.html) | scalers | `scaler_bicubic` | [`scaler_bicubic_tb.sv`](../scalers/scaler_bicubic/tb/scaler_bicubic_tb.sv) |
| [scaler_bilinear](../scalers/scaler_bilinear/docs/index.html) | scalers | `scaler_bilinear` | [`scaler_bilinear_tb.sv`](../scalers/scaler_bilinear/tb/scaler_bilinear_tb.sv) |
| [scaler_ctrl](../scalers/scaler_ctrl/docs/index.html) | scalers | `scaler_ctrl` | [`scaler_ctrl_tb.sv`](../scalers/scaler_ctrl/tb/scaler_ctrl_tb.sv) |
| [scaler_dda](../scalers/scaler_dda/docs/index.html) | scalers | `scaler_dda` | [`scaler_dda_tb.sv`](../scalers/scaler_dda/tb/scaler_dda_tb.sv) |
| [scaler_edge_directed](../scalers/scaler_edge_directed/docs/index.html) | scalers | `scaler_edge_directed` | [`scaler_edge_directed_tb.sv`](../scalers/scaler_edge_directed/tb/scaler_edge_directed_tb.sv) |
| [scaler_lanczos](../scalers/scaler_lanczos/docs/index.html) | scalers | `scaler_lanczos` | [`scaler_lanczos_tb.sv`](../scalers/scaler_lanczos/tb/scaler_lanczos_tb.sv) |
| [scaler_mip](../scalers/scaler_mip/docs/index.html) | scalers | `scaler_mip` | [`scaler_mip_tb.sv`](../scalers/scaler_mip/tb/scaler_mip_tb.sv) |
| [scaler_nearest](../scalers/scaler_nearest/docs/index.html) | scalers | `scaler_nearest` | [`scaler_nearest_tb.sv`](../scalers/scaler_nearest/tb/scaler_nearest_tb.sv) |
| [scaler_polyphase](../scalers/scaler_polyphase/docs/index.html) | scalers | `scaler_polyphase` | [`scaler_polyphase_tb.sv`](../scalers/scaler_polyphase/tb/scaler_polyphase_tb.sv) |
| [scaler_trilinear](../scalers/scaler_trilinear/docs/index.html) | scalers | `scaler_trilinear` | [`scaler_trilinear_tb.sv`](../scalers/scaler_trilinear/tb/scaler_trilinear_tb.sv) |
| [sharpen_cas](../scalers/sharpen_cas/docs/index.html) | scalers | `sharpen_cas` | [`sharpen_cas_tb.sv`](../scalers/sharpen_cas/tb/sharpen_cas_tb.sv) |
| [spatial_upscaler](../scalers/spatial_upscaler/docs/index.html) | scalers | `spatial_upscaler` | [`spatial_upscaler_tb.sv`](../scalers/spatial_upscaler/tb/spatial_upscaler_tb.sv) |
| [mac](../math/mac/docs/index.html) | math | `mac` | [`mac_tb.sv`](../math/mac/tb/mac_tb.sv) |

## reset_ctrl

**Ip Reset Sync Top** · category `cdc` · top `ip_reset_sync_top`

Top level of the reset synchronizer IP. Synchronizes an asynchronous external reset for the AXI-Lite bus and for NUM_OUT replicated user resets (fan-out control). A software reset bit, hold- time register, reset event counter and status are exposed through an AXI-Lite register file. Register map - 0x00 CTRL[0]=soft reset (self clearing), 0x04 HOLD cycles, 0x08 STATUS[0]=active [1]=event seen (W1C), 0x0C event count. Version 1.0.0. Clock - aclk, the external reset arst_i is asynchronous and is synchronized with STAGES flops. Reset - the reset asserts asynchronously and releases synchronously; outputs are held for HOLD_DEFAULT clocks or the programmed hold. Latency - release is STAGES+1 clocks after arst_i deasserts plus the hold. Errors - illegal parameters stop elaboration; out of range AXI- Lite accesses return SLVERR.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/rst_sync.sv`, `src/ip_reset_sync_top.sv`

[HTML module page](../cdc/reset_ctrl/docs/index.html)

## baud_nco

**Baud Nco Top** · category `timing` · top `baud_nco_top`

Baud rate generator and NCO IP. Phase accumulator NCO gives a baud tick strobe, square wave and, on an AXI-Stream master, 16 bit sine and cosine samples (tdata = {cos, sin}). AXI-Lite map - 0x00 CTRL[0]=en [1]=stream_en [2]=phase reset pulse, 0x04 FCW, 0x08 PHASE_OFF[15:0], 0x0C GAIN[14:0], 0x10 STATUS, 0x14 TICK_COUNT (write clears). f_out = f_clk * FCW / 2^PHASE_W. Default FCW is computed for BAUD*OSR at CLK_HZ. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/nco_sine_rom.sv`, `src/nco_core.sv`, `src/baud_nco_top.sv`

[HTML module page](../timing/baud_nco/docs/index.html)

## uart

**Uart Top** · category `peripherals` · top `uart_top`

UART IP top level. Full duplex UART with a fractional baud generator, transmit and receive FIFOs (block RAM for deep FIFOs) and AXI-Stream data ports: s_axis carries bytes to transmit, m_axis carries received bytes. Control and status through AXI-Lite. Map - 0x00 CTRL [0]tx_en [1]rx_en [2]par_en [3]par_odd [4]stop2 [5]loopback [7:6]bits(0=8,1=7,2=6,3=5); 0x04 FCW; 0x08 STATUS [0]tx_busy [1]rx_busy [2]rx_avail [8]frame_err [9]parity_err [10]overrun (W1C) [30:16]rx level; 0x0C error frame count. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../shared/src/fifo/ip_axis_fifo.sv`, `src/uart_baud.sv`, `src/uart_tx.sv`, `src/uart_rx.sv`, `src/uart_top.sv`

[HTML module page](../peripherals/uart/docs/index.html)

## i2c_master

**I2C Top** · category `peripherals` · top `i2c_top`

I2C master IP top level. AXI-Lite registers start and describe a transaction; write data is taken from an AXI-Stream slave port and read data is returned on an AXI-Stream master port (tlast marks the last byte). Open-drain pins use i/o/t style signals. Map - 0x00 CTRL [0]en [1]start(pulse) [2]read [3]no_stop; 0x04 ADDR[6:0]; 0x08 LEN; 0x0C DIV (phase clocks-1, f_scl = f_clk/(4*(DIV+1))); 0x10 STATUS [0]busy [1]done [2]nack [3]arb_lost, [3:1] are write-1-to- clear. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../shared/src/fifo/ip_axis_fifo.sv`, `src/i2c_bit_ctrl.sv`, `src/i2c_master_fsm.sv`, `src/i2c_top.sv`

[HTML module page](../peripherals/i2c_master/docs/index.html)

## spi_master

**Spi Top** · category `peripherals` · top `spi_top`

SPI master IP top level. AXI-Stream slave carries words to transmit (tlast ends a chip select burst), AXI-Stream master returns the words captured from MISO. AXI-Lite map - 0x00 CTRL [0]en [1]cpol [2]cpha [3]lsb_first [15:8]cs_select; 0x04 DIV (SCLK half period = DIV+1 clocks); 0x08 WORD_LEN bits per word (1..DATA_W); 0x0C STATUS [0]busy [1]rx_overrun (W1C) [31:16]rx fifo level. Any clock frequency, default 1 MHz SCLK at 100 MHz. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../shared/src/fifo/ip_axis_fifo.sv`, `src/spi_engine.sv`, `src/spi_top.sv`

[HTML module page](../peripherals/spi_master/docs/index.html)

## gpio

**Gpio Top** · category `peripherals` · top `gpio_top`

General purpose I/O IP with WIDTH pins. Per-pin direction, output register with atomic SET/CLEAR/TOGGLE registers, two flop input synchronizers, per-pin rising/falling edge interrupts with enable masks and write-1-to-clear status, and an interrupt output. Tri-state style pins (gpio_t=1 means input). Map - 0x00 OUT, 0x04 DIR(1=output), 0x08 IN (read only), 0x0C SET, 0x10 CLEAR, 0x14 TOGGLE, 0x18 INT_EN, 0x1C RISE_EN, 0x20 FALL_EN, 0x24 INT_STATUS (W1C). Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI- Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/gpio_top.sv`

[HTML module page](../peripherals/gpio/docs/index.html)

## intc

**Intc Top** · category `peripherals` · top `intc_top`

Interrupt controller IP with NUM_IRQ sources. Each source has enable, edge or level type, polarity, and software set. Edge sources latch into a pending register cleared by write-1-to-clear, level sources follow the input. A lowest-index-wins priority encoder reports the active vector (pipelined) and the irq output. Map - 0x00 ENABLE, 0x04 EDGE_TYPE, 0x08 ACTIVE_LOW, 0x0C PENDING (W1C for edge bits), 0x10 SOFT_SET (write), 0x14 VECTOR [4:0]=id [31]=valid, 0x18 MASKED_PENDING. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/intc_top.sv`

[HTML module page](../peripherals/intc/docs/index.html)

## pwm

**Pwm Top** · category `timing` · top `pwm_top`

Multi-channel PWM IP. Programmable prescaler and period, edge or center aligned counting, per-channel double-buffered duty (updated at the period boundary), optional complementary outputs with programmable dead time and per-channel output inversion. Map - 0x00 CTRL [0]en [1]center [2]complementary, 0x04 PERIOD (counter top), 0x08 PRESCALE (clk divide-1), 0x0C DEADTIME clocks, 0x10 INVERT mask, 0x14+4*n DUTY[n]. Output pipeline is registered for timing. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/pwm_top.sv`

[HTML module page](../timing/pwm/docs/index.html)

## quadrature_decoder

**Quad Dec Top** · category `peripherals` · top `quad_dec_top`

Quadrature encoder decoder IP. A/B/index inputs pass two flop synchronizers and a programmable stability filter, then a x4 decoder updates a 32 bit signed position counter, direction flag and illegal transition (error) counter. Index pulse latches and optionally clears the position. A window timer measures counts per window (velocity) and emits each sample on an AXI-Stream master. Map - 0x00 CTRL [0]en [1]clear pos (pulse) [2]index clears pos [3]swap A/B [15:8]filter clocks, 0x04 POSITION, 0x08 VELOCITY, 0x0C WINDOW clocks, 0x10 STATUS [0]dir [1]error [2]index seen (W1C), 0x14 ERR_COUNT, 0x18 INDEX_POS. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/quad_dec_top.sv`

[HTML module page](../peripherals/quadrature_decoder/docs/index.html)

## watchdog

**Watchdog Top** · category `timing` · top `watchdog_top`

Watchdog timer IP. Prescaled up-counter with programmable timeout and pre-timeout interrupt, optional window mode (kicks before WINDOW_OPEN are violations), key-protected kick register, write-once lock bit that prevents disabling, and a stretched system reset output. Map - 0x00 CTRL [0]en [1]window_en [2]lock, 0x04 TIMEOUT ticks, 0x08 PRESCALE (clk divide-1), 0x0C PRETIMEOUT ticks, 0x10 WINDOW_OPEN ticks, 0x14 KICK (write 0x5AFEC0DE), 0x18 STATUS [0]pretimeout [1]expired [2]early kick [3]bad key (W1C), 0x1C COUNT. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI- Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/watchdog_top.sv`

[HTML module page](../timing/watchdog/docs/index.html)

## edge_event_capture

**Edge Event Capture Top** · category `peripherals` · top `edge_event_capture_top`

Multi-channel edge detector IP. Each of WIDTH inputs goes through a synchronizer chain, an optional debounce filter (input must be stable for DEBOUNCE clocks), and rise/fall detection with enable masks. Events set write-1-to-clear pending flags, increment an event counter, drive direct pulse outputs and are timestamped into an AXI- Stream event record {timestamp, fall flags, rise flags} through a FIFO (drop counter on overflow). Map - 0x00 CTRL [0]en, 0x04 RISE_EN, 0x08 FALL_EN, 0x0C DEBOUNCE clocks, 0x10 RISE_PEND (W1C), 0x14 FALL_PEND (W1C), 0x18 EVENT_COUNT, 0x1C TIMESTAMP, 0x20 DROP_COUNT, 0x24 IRQ_EN. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../shared/src/fifo/ip_axis_fifo.sv`, `src/edge_event_capture_top.sv`

[HTML module page](../peripherals/edge_event_capture/docs/index.html)

## async_fifo

**Async Fifo** · category `fifo` · top `async_fifo`

Dual clock (asynchronous) FIFO. Gray coded read and write pointers cross domains through two flop synchronizers, full is generated in the write domain and empty in the read domain. Storage is a dual clock RAM (block RAM capable) with a registered read and a first-word-fall- through output register. DEPTH must be a power of two >= 4. Assert both resets together. Version 1.0.0. Clocks - wclk and rclk are unrelated (Gray-coded pointers, two-flop synchronizers), each with its own synchronous active low reset (reset both together). Latency - a written word is visible on the read side 3 to 5 read clocks later; full/empty flags are conservative, never optimistic. Timing - constrain the pointer crossings with set_max_delay -datapath_only (or false path with skew control); the memory read path is registered. Errors - writing when full or reading when empty is ignored (and asserted in simulation); illegal parameters stop elaboration. Clock - the clock of the parent block, all signals are synchronous to it. Reset - synchronous, driven by the parent block. block.

Sources: `src/async_fifo.sv`

[HTML module page](../fifo/async_fifo/docs/index.html)

## axis_async_bridge

**Axis Async Bridge** · category `cdc` · top `axis_async_bridge`

AXI-Stream asynchronous clock domain bridge. Carries tdata, tkeep, tlast and tuser from the slave clock domain to the master clock domain through a gray pointer dual clock FIFO. Each side has an independent active-low reset that is synchronized locally (async assert, sync release). Optional depth for rate matching. Both resets should be asserted together. Version 1.0.0. Clocks - s_clk and m_clk unrelated, built on async_fifo with the same crossing rules and latency (3 to 5 destination clocks). Reset - synchronous active low per domain. Timing - see async_fifo. Errors - none at run time (full FIFO deasserts s_tready, nothing is dropped); illegal parameters stop elaboration. Clock - the clock of the parent block, all signals are synchronous to it. Latency - as documented in the parent block, fixed and independent of data. as documented in the parent block, fixed and independent of data.

Sources: `../../fifo/async_fifo/src/async_fifo.sv`, `src/axis_async_bridge.sv`

[HTML module page](../cdc/axis_async_bridge/docs/index.html)

## axi4_lite_cdc

**Axi4 Lite Cdc** · category `cdc` · top `axi4_lite_cdc`

AXI4-Lite clock domain bridge. An AXI-Lite slave in the source clock domain is connected to an AXI-Lite master in the destination domain using a toggle request / toggle acknowledge handshake with two flop synchronizers. One transaction is outstanding at a time; address, data and response buses are held stable while the handshake crosses, so no per-bit synchronization is needed. Works for any clock ratio. Version 1.0.0. Clocks - s_clk (slave side) and m_clk (master side) unrelated, each channel crosses with a toggle handshake and two-flop synchronizers. Reset - synchronous active low per domain, reset both together. Latency - roughly 6 to 10 clocks of the slower domain per transaction; one transaction outstanding at a time. Timing - address/data registers cross under a max-delay constraint of one destination period. Errors - the master side response (including SLVERR) is passed back unchanged; illegal parameters stop elaboration. Clock - the clock of the parent block, all signals are synchronous to it. signals are synchronous to it.

Sources: `src/cdc_sync_bit.sv`, `src/axi4_lite_cdc.sv`

[HTML module page](../cdc/axi4_lite_cdc/docs/index.html)

## dma_engine

**Dma Engine** · category `bus` · top `dma_engine`

Memory to memory DMA engine. Copies LEN bytes from SRC to DST over one AXI4 master port using burst read and write engines decoupled by a stream FIFO (bursts limited to MAX_BURST beats and never crossing 4 KB). Programmed over AXI-Lite - 0x00 CTRL [0]start (pulse) [1]irq_en, 0x04 SRC, 0x08 DST, 0x0C LEN (bytes, multiple of 4), 0x10 STATUS [0]busy [8]done (W1C) [9]error (W1C). irq_o follows done when enabled. Addresses must be 4 byte aligned. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI- Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error. The AXI4 master follows the AXI4 rules of 4 KB burst boundaries; a bus error response stops the transfer and is reported in STATUS.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../shared/src/fifo/ip_axis_fifo.sv`, `../../shared/src/bus/dma_common/dma_rd_engine.sv`, `../../shared/src/bus/dma_common/dma_wr_engine.sv`, `src/dma_engine.sv`

[HTML module page](../bus/dma_engine/docs/index.html)

## axis_dma

**Axis Dma** · category `bus` · top `axis_dma`

AXI-Stream DMA with two independent channels sharing one AXI4 master port. MM2S reads LEN bytes from memory and emits them on an AXI-Stream master (tlast on the last word). S2MM accepts an AXI- Stream slave and writes LEN bytes to memory. Both use burst engines limited to MAX_BURST beats and 4 KB boundaries, with FIFOs on the stream sides. AXI-Lite map - 0x00 CTRL [0]mm2s_start [1]s2mm_start (pulses) [2]irq_en, 0x04 MM2S_ADDR, 0x08 MM2S_LEN, 0x0C S2MM_ADDR, 0x10 S2MM_LEN, 0x14 STATUS [0]mm2s_busy [1]s2mm_busy [8]mm2s_done [9]s2mm_done [10]mm2s_err [11]s2mm_err, done and error bits are W1C. Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks (ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop elaboration with an $error. The AXI4 master follows the AXI4 rules of 4 KB burst boundaries; a bus error response stops the transfer and is reported in STATUS.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../shared/src/fifo/ip_axis_fifo.sv`, `../../shared/src/bus/dma_common/dma_rd_engine.sv`, `../../shared/src/bus/dma_common/dma_wr_engine.sv`, `src/axis_dma.sv`

[HTML module page](../bus/axis_dma/docs/index.html)

## bit_sync

**Bit Sync** · category `cdc` · top `bit_sync`

Multi-flop synchronizer for a single-bit asynchronous signal entering the clk domain. Version 1.0.0. Clock domain - all state runs on clk, d_i may be fully asynchronous but must be glitch free and held for at least one clk period (use pulse_sync for pulses). Reset - synchronous, active low; flops load RESET_VAL. Latency - STAGES clock cycles. Timing - the flops carry async_reg so tools keep them together; no logic between stages. Errors - STAGES < 2 is rejected at elaboration.

Sources: `src/bit_sync.sv`

[HTML module page](../cdc/bit_sync/docs/index.html)

## toggle_sync

**Toggle Sync** · category `cdc` · top `toggle_sync`

Event transfer between clock domains using a toggle level. Version 1.0.0. Every one-clock event_i pulse in the source domain flips a toggle flop; the destination synchronizes the toggle and emits event_o for each change. No handshake, so events must be spaced at least STAGES+2 destination clocks apart (source clock period permitting) or they are lost; use pulse_sync when spacing cannot be guaranteed. Clocks - src_clk and dst_clk are unrelated. Reset - synchronous per domain, active low. Latency - STAGES+1 dst clocks. Errors - none reported; STAGES<2 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it. synchronous to it.

Sources: `../../cdc/bit_sync/src/bit_sync.sv`, `src/toggle_sync.sv`

[HTML module page](../cdc/toggle_sync/docs/index.html)

## pulse_sync

**Pulse Sync** · category `cdc` · top `pulse_sync`

Pulse transfer between clock domains with full handshake. Version 1.0.0. A toggle crosses to the destination and an acknowledge toggle crosses back, so a new pulse is accepted only when the previous one has completed (busy_o low). Pulses arriving while busy are dropped and flagged on drop_o (one src clock) so nothing is lost silently. Clocks - src_clk and dst_clk unrelated. Reset - synchronous per domain, active low. Latency - about STAGES+2 dst clocks to pulse_o; busy clears after ~2*STAGES+3 clocks of the slower domain. Errors - drop_o on overrun; STAGES<2 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it. all signals are synchronous to it.

Sources: `../../cdc/bit_sync/src/bit_sync.sv`, `src/pulse_sync.sv`

[HTML module page](../cdc/pulse_sync/docs/index.html)

## reset_sync

**Reset Sync** · category `cdc` · top `reset_sync`

Reset synchronizer. Version 1.0.0. Brings an asynchronous reset into the clk domain. ASYNC_ASSERT=1 (default) asserts the output immediately and releases it synchronously after STAGES clocks; ASYNC_ASSERT=0 samples the input with the clock so both edges are synchronous. Polarity of the input and output is selectable. Clock - clk; arst_i may be asynchronous. Reset state - output asserted. Latency - release takes STAGES clocks (assert is immediate for async type). Timing - the flops are marked async_reg. Errors - STAGES<2 rejected at elaboration.

Sources: `src/reset_sync.sv`

[HTML module page](../cdc/reset_sync/docs/index.html)

## edge_detect

**Edge Detect** · category `common` · top `edge_detect`

Edge detector for WIDTH signals. Version 1.0.0. EDGE selects rising (0), falling (1) or both (2). Optional two-flop input synchronizer (SYNC_INPUT=1) for asynchronous inputs. Clock - clk; input must be synchronous unless SYNC_INPUT=1. Reset - synchronous active low, previous-value register resets to RESET_LEVEL so no false edge appears after reset. Latency - pulse_o is registered: 1 clock after the input changes (3 with SYNC_INPUT). Output - one clock wide pulse. Errors - invalid EDGE or WIDTH rejected at elaboration.

Sources: `src/edge_detect.sv`

[HTML module page](../common/edge_detect/docs/index.html)

## clock_enable

**Clock Enable** · category `timing` · top `clock_enable`

Programmable clock-enable generator. Version 1.0.0. Produces a one-clock ce_o pulse every DIV clocks (DIV = div_i, values 0 and 1 give a pulse every clock). The divide ratio may change at any time and takes effect at the next pulse. Clock - clk. Reset - synchronous active low; counter cleared, ce_o low. Latency - ce_o is registered; first pulse DIV clocks after en_i rises. Timing - one counter compare per clock, DIV_W bit wide. Errors - DIV_W < 1 rejected at elaboration. Does not divide the clock itself; use ce_o as an enable on clk.

Sources: `src/clock_enable.sv`

[HTML module page](../timing/clock_enable/docs/index.html)

## counter

**Counter** · category `timing` · top `counter`

Generic programmable up/down counter. Version 1.0.0. DIRECTION 0 counts up from 0 to top_i then wraps to 0, 1 counts down from top_i to 0 then reloads top_i, 2 selects up or down at run time through dir_i (up wraps top->0, down wraps 0->top). Synchronous load has priority over counting. wrap_o is a registered one-clock pulse on every wrap. Clock - clk; en_i is a clock enable. Reset - synchronous active low, count = 0. Latency - count_o updates one clock after en_i; wrap_o in the same clock as the wrapped count. Errors - WIDTH < 1 or invalid DIRECTION rejected at elaboration; load_val_i above top_i is clamped to top_i.

Sources: `src/counter.sv`

[HTML module page](../timing/counter/docs/index.html)

## timeout_timer

**Timeout Timer** · category `timing` · top `timeout_timer`

Inactivity timeout timer. Version 1.0.0. Counts clocks since the last activity_i pulse; when the count reaches timeout_i, expired_o goes high (level, registered) and timeout_pulse_o pulses once. Any activity clears the count and expired_o. timeout_i = 0 disables the timer. Clock - clk (use ce_i to count slower ticks). Reset - synchronous active low, not expired. Latency - expired_o rises timeout_i + 1 clocks after the last activity. Errors - WIDTH < 1 rejected at elaboration; the counter saturates at timeout_i so it never wraps.

Sources: `src/timeout_timer.sv`

[HTML module page](../timing/timeout_timer/docs/index.html)

## priority_encoder

**Priority Encoder** · category `common` · top `priority_encoder`

Priority encoder. Version 1.0.0. Encodes the highest- priority asserted request: LSB_HIGH=1 gives bit 0 the highest priority, LSB_HIGH=0 gives the MSB. Outputs the index, a one-hot vector and a valid flag. REGISTERED=1 adds one output register stage (latency 1, synchronous reset to invalid); otherwise the module is purely combinational (latency 0) and clk/rst_n are unused. Timing - log2(WIDTH) LUT levels; register the output for wide vectors at 100 MHz. Errors - WIDTH < 2 rejected at elaboration; idx_o is 0 when valid_o is low. Clock - the clock of the parent block, all signals are synchronous to it. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. driven by the parent block. Latency - as documented in the parent block, fixed and independent of data.

Sources: `src/priority_encoder.sv`

[HTML module page](../common/priority_encoder/docs/index.html)

## onehot_decoder

**Onehot Decoder** · category `common` · top `onehot_decoder`

Binary to one-hot decoder with enable. Version 1.0.0. Bit sel_i of onehot_o is set when en_i is high. A select value >= WIDTH sets err_o and produces an all-zero output. REGISTERED=1 adds one output register stage (latency 1, synchronous reset to zero); otherwise the block is combinational (latency 0). Errors - out-of- range select flagged on err_o; WIDTH < 2 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. parent block, all signals are synchronous to it. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data.

Sources: `src/onehot_decoder.sv`

[HTML module page](../common/onehot_decoder/docs/index.html)

## single_port_ram

**Single Port Ram** · category `memory` · top `single_port_ram`

Generic synchronous single-port RAM. Version 1.0.0. One clock, one address, optional byte write enables (BYTE_EN). Read behaviour on a write to the same address is selectable - MODE 0 READ_FIRST (old data), 1 WRITE_FIRST (new data), 2 NO_CHANGE (output holds). Inferred as block RAM by Yosys and Vivado. Clock - clk. Reset - none on the array; the output register resets synchronously (active low) to zero, memory content is undefined until written unless INIT_ZERO=1. Latency - read data valid one clock after the address. Errors - DEPTH<2, WIDTH<1, or invalid MODE rejected at elaboration; BYTE_EN requires WIDTH multiple of 8.

Sources: `src/single_port_ram.sv`

[HTML module page](../memory/single_port_ram/docs/index.html)

## simple_dual_port_ram

**Simple Dual Port Ram** · category `memory` · top `simple_dual_port_ram`

Simple dual-port RAM with an independent write port and read port. Version 1.0.0. CLOCKING 0 uses wclk for both ports; a separate rclk is used when ASYNC=1 (unrelated clocks, read-during- write of the same address returns old or new data, undefined which). Optional byte enables. Inferred as block RAM. Reset - the read output register resets synchronously (active low, rclk domain). Latency - read data one rclk after raddr with re_i. Errors - DEPTH<2, WIDTH<1 or BYTE_EN with WIDTH not multiple of 8 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it. parent block, all signals are synchronous to it.

Sources: `src/simple_dual_port_ram.sv`

[HTML module page](../memory/simple_dual_port_ram/docs/index.html)

## true_dual_port_ram

**True Dual Port Ram** · category `memory` · top `true_dual_port_ram`

True dual-port RAM. Version 1.0.0. Two fully independent ports A and B, each with its own clock, enable, write enable, address, data in and registered data out (read-first). Simultaneous writes to the same address from both ports are undefined - the wr_conflict_o flag (simulation-only assertion plus registered detect when both ports share one clock) reports it. Inferred as block RAM in a single-clock configuration. Reset - output registers reset synchronously to zero per port. Latency - 1 clock per port. Errors - DEPTH<2 or WIDTH<1 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it. synchronous to it.

Sources: `src/true_dual_port_ram.sv`

[HTML module page](../memory/true_dual_port_ram/docs/index.html)

## rom

**Rom** · category `memory` · top `rom`

Parameterized synchronous ROM. Version 1.0.0. Contents come from INIT_FILE (hex text read with $readmemh, one word per line) or, when INIT_FILE is empty, from a deterministic built-in pattern (word index XOR 32'hA5A5_5A5A truncated to WIDTH) so the module is testable without files. Clock - clk. Reset - output register resets synchronously (active low) to zero. Latency - data valid one clock after addr_i with en_i. Errors - out-of-range addresses cannot occur (DEPTH need not be a power of two - addresses >= DEPTH return zero and raise oob_o); DEPTH<2 rejected at elaboration. Inferred as block RAM or LUT ROM.

Sources: `src/rom.sv`

[HTML module page](../memory/rom/docs/index.html)

## register_file

**Register File** · category `memory` · top `register_file`

Multi-register file. Version 1.0.0. NREG registers of WIDTH bits with one write port and NRD combinational read ports (asynchronous read, so no read latency - LUT-RAM friendly). ZERO_REG0=1 hard-wires register 0 to zero. Write-through bypass (BYPASS=1) returns write data on a read of the register being written in the same clock. Clock - clk. Reset - synchronous active low, all registers cleared. Errors - NREG<2 rejected at elaboration; writes to register 0 with ZERO_REG0 are ignored. Latency - as documented in the parent block, fixed and independent of data. data.

Sources: `src/register_file.sv`

[HTML module page](../memory/register_file/docs/index.html)

## sync_fifo

**Sync Fifo** · category `fifo` · top `sync_fifo`

Synchronous FIFO with registered read (standard mode). Version 1.0.0. Write with wr_en_i, read with rd_en_i; read data is valid the clock after rd_en_i (rd_valid_o marks it). Full/empty flags, level, programmable almost-full and almost-empty thresholds, sticky overflow/underflow error flags (cleared by clr_err_i). Overflowing writes and underflowing reads are ignored so state is never corrupted. Clock - single clk. Reset - synchronous active low, FIFO empty, flags cleared. Latency - write to empty deassert 1 clock; read 1 clock. Storage - inferred RAM (block RAM for large depths). Errors - DEPTH must be a power of two >= 4 (rejected at elaboration).

Sources: `src/sync_fifo.sv`

[HTML module page](../fifo/sync_fifo/docs/index.html)

## fallthrough_fifo

**Fallthrough Fifo** · category `fifo` · top `fallthrough_fifo`

First-word-fall-through FIFO with valid/ready handshakes. Version 1.0.0. The oldest word is presented on m_data_o as soon as the FIFO is not empty (m_valid_o), with no read latency; m_ready_i pops it. Storage is a register-array with asynchronous read (distributed RAM style), intended for shallow FIFOs (DEPTH <= 64); use ip_axis_fifo for deep block-RAM FIFOs. Clock - clk. Reset - synchronous active low, empty. Latency - 1 clock from a write into an empty FIFO to m_valid_o. Overflow - s_ready_o is low when full, so a compliant source never overflows. Errors - DEPTH must be a power of two >= 2 (rejected at elaboration).

Sources: `src/fallthrough_fifo.sv`

[HTML module page](../fifo/fallthrough_fifo/docs/index.html)

## packet_fifo

**Packet Fifo** · category `fifo` · top `packet_fifo`

Packet-preserving FIFO (store and forward). Version 1.0.0. Words are written with s_last_i marking the final word of a packet. A packet becomes visible on the master side only when its last word has been stored, so downstream logic never sees a partial packet. If the FIFO fills in the middle of a packet the whole packet is discarded (the write pointer is rolled back at the packet end) and drop_o pulses; s_ready_o stays high in that case so the source is never blocked mid-packet. A packet larger than the FIFO is therefore always dropped. Optional DROP_ON_BAD: s_bad_i on the last word drops the packet (e.g. CRC error). Clock - clk. Reset - synchronous active low. Latency - a packet appears 2 clocks after its last word; words stream 1 per clock afterwards. Storage - block RAM. Errors - drop_o (pulse), pkt_count_o; DEPTH must be a power of two >= 4.

Sources: `src/packet_fifo.sv`

[HTML module page](../fifo/packet_fifo/docs/index.html)

## memory_arbiter

**Memory Arbiter** · category `memory` · top `memory_arbiter`

Arbiter between CLIENTS memory clients and one memory port. Version 1.0.0. Each client presents req/we/addr/wdata with a ready handshake (a request is accepted when c_req and c_ready are both high). PRIORITY 0 is round-robin (fair, last granted client has lowest priority next), 1 is fixed priority with client 0 highest. Read responses come back in order from the memory (m_rvalid_i/m_rdata_i, any fixed or variable latency) and are routed to the client that issued the read using an internal order FIFO of MAX_OUT entries; new reads are stalled when it is full. Writes need no response. Clock - clk. Reset - synchronous active low. Latency - grant is combinational (0 clocks from request to m_req when m_ready_i); read data is passed through with 0 added latency. Timing - address and data muxes are CLIENTS wide, register client outputs for large CLIENTS at 100 MHz. Errors - a memory response with no outstanding read raises err_o (sticky, cleared by clr_err_i).

Sources: `src/memory_arbiter.sv`

[HTML module page](../memory/memory_arbiter/docs/index.html)

## nco

**Nco** · category `timing` · top `nco`

Numerically controlled oscillator (phase accumulator). Version 1.0.0. phase_o advances by tuning_i each ce_i clock, so f_out = tuning_i * f_clk / 2^PHASE_W. Optional phase offset (phase_off_i) is added to the output phase only. carry_o pulses each time the accumulator overflows (a square-wave/tick source with frequency f_out) and msb_o is the accumulator MSB (50 percent duty square wave). Clock - clk with clock enable ce_i. Reset - synchronous active low, phase = 0. sync_load_i loads phase_load_i. Latency - phase_o and carry_o are registered, 1 clock after ce_i. Timing - one PHASE_W bit adder per clock; for PHASE_W > 32 add pipeline stages in the caller. Errors - PHASE_W < 2 rejected at elaboration; tuning_i >= 2^(PHASE_W-1) exceeds Nyquist and is flagged on nyquist_o.

Sources: `src/nco.sv`

[HTML module page](../timing/nco/docs/index.html)

## baud_generator

**Baud Generator** · category `timing` · top `baud_generator`

Programmable serial baud-rate tick generator. Version 1.0.0. A fractional (NCO) divider produces tick_os_o at BAUD*OVERSAMPLE ticks per second and tick_baud_o once every OVERSAMPLE oversample ticks, with no cumulative error (average frequency exact to 2^-ACC_W of the clock). The nominal increment is computed at elaboration from CLK_HZ, BAUD and OVERSAMPLE; set use_reg_i=1 to override it at run time with inc_i (inc = round(BAUD*OVERSAMPLE*2^ACC_W/CLK_HZ)). Works at any clock frequency as long as BAUD*OVERSAMPLE <= CLK_HZ/2. Clock - clk. Reset - synchronous active low. sync_i restarts the bit phase (used by receivers on the start edge). Latency - ticks are registered, one clock after the accumulator overflows. Jitter - at most one clk period on each tick. Errors - unreachable rates (increment 0 or >= 2^(ACC_W-1)) rejected at elaboration.

Sources: `src/baud_generator.sv`

[HTML module page](../timing/baud_generator/docs/index.html)

## pulse_generator

**Pulse Generator** · category `timing` · top `pulse_generator`

Periodic or one-shot pulse generator. Version 1.0.0. In continuous mode a pulse of width_i clocks is produced every period_i clocks; in one-shot mode (oneshot_i=1) each trigger_i pulse produces one pulse of width_i clocks (retriggers ignored while active). Period, width and polarity may be changed on the fly; new values apply from the next period start. width_i is clamped to period_i in continuous mode. Clock - clk. Reset - synchronous active low, output idle (inverted when INVERT). Latency - pulse_o starts 1 clock after the period start or trigger. Errors - period_i = 0 disables output; width_i = 0 gives no pulse; WIDTH < 2 rejected at elaboration.

Sources: `src/pulse_generator.sv`

[HTML module page](../timing/pulse_generator/docs/index.html)

## frequency_counter

**Frequency Counter** · category `timing` · top `frequency_counter`

Input frequency counter. Version 1.0.0. Counts rising edges of the (asynchronous) signal sig_i during a gate window of gate_clks_i system clocks and reports the edge count in count_o with a one-clock valid_o pulse after every window; frequency = count * f_clk / gate_clks. The input passes a 2-flop synchronizer, so signals up to f_clk/4 are counted correctly (higher rates alias); over_o flags a count that saturated. Clock - clk. Reset - synchronous active low. Latency - one gate window plus 4 clocks. Resolution - +/-1 count per window; a longer gate improves resolution. Errors - gate_clks_i = 0 disables measuring; saturation flagged on over_o (sticky per result).

Sources: `../../cdc/bit_sync/src/bit_sync.sv`, `src/frequency_counter.sv`

[HTML module page](../timing/frequency_counter/docs/index.html)

## timestamp_counter

**Timestamp Counter** · category `timing` · top `timestamp_counter`

Free-running system timestamp counter. Version 1.0.0. WIDTH-bit counter incrementing on every tick_i (tie to 1 for clk resolution, or use clock_enable for microseconds). clear_i zeroes it and load_i loads a value. capture_i latches the count into capture_o (one clock later, with cap_valid_o) so software can read a coherent snapshot of a wide value; TS_CAPTURE_EDGE adds a synchronized event input for external timestamping. Clock - clk. Reset - synchronous active low, count 0. Latency - capture_o valid 1 clock after capture_i. Rollover - wraps silently; wrap_o pulses on overflow. Errors - WIDTH < 2 rejected at elaboration.

Sources: `src/timestamp_counter.sv`

[HTML module page](../timing/timestamp_counter/docs/index.html)

## rate_limiter

**Rate Limiter** · category `timing` · top `rate_limiter`

Token-bucket rate limiter for valid/ready streams or events. Version 1.0.0. One token is added every refill_period_i clocks up to a bucket size of burst_i; each transferred word (s_valid_i & s_ready_o) consumes one token. When the bucket is empty s_ready_o is low, so the average rate is 1/refill_period_i words per clock with bursts up to burst_i. Data passes combinationally between s_* and m_* (no added latency, no storage). refill_period_i = 0 disables limiting. Clock - clk. Reset - synchronous active low, bucket full. Errors - none; a downstream stall (m_ready_i low) does not consume tokens. TOKEN_W < 2 rejected at elaboration. Latency - as documented in the parent block, fixed and independent of data. independent of data.

Sources: `src/rate_limiter.sv`

[HTML module page](../timing/rate_limiter/docs/index.html)

## interval_timer

**Interval Timer** · category `timing` · top `interval_timer`

Programmable interval timer. Version 1.0.0. Counts prescaled ticks and raises a one-clock irq_o / tick_o every interval_i ticks. AUTO_RELOAD mode repeats forever; one-shot mode (auto_i=0) stops after the first event. Prescaler divides clk by prescale_i+1. start_i starts (or restarts) the timer, stop_i halts it, and remaining_o shows the ticks left. The interval and prescaler may be rewritten while running and take effect at the next reload. Clock - clk. Reset - synchronous active low, stopped. Latency - first event interval*(prescale+1) clocks after start_i. Errors - interval_i = 0 is invalid: start is refused and err_o pulses.

Sources: `src/interval_timer.sv`

[HTML module page](../timing/interval_timer/docs/index.html)

## axi4_lite_slave

**Axi4 Lite Slave** · category `bus` · top `axi4_lite_slave`

Generic AXI4-Lite slave front end. Version 1.0.0. Converts AXI4-Lite transactions into a simple register-access interface for user logic: a write strobe (wr_en_o with addr, data, byte strobes) and a read request (rd_en_o with addr) completed by the user through rd_valid_i/rd_data_i (or immediately when READ_WAIT=0, data taken combinationally from rd_data_i in the cycle after rd_en_o). Write address and data channels are accepted independently and combined. The user may flag an error on either access (wr_err_i, valid two clocks after wr_en_o starts, i.e. the clock after it ends; rd_err_i with the read data) which returns SLVERR; an access to an address >= ADDR_LIMIT_W-mapped range returns DECERR. Clock - aclk only. Reset - synchronous aresetn (active low), all channels idle. Latency - write: 2 clocks from both AW and W accepted to bvalid; read: 2 clocks (+ user latency). One transaction outstanding per direction. Errors - SLVERR/DECERR as above; ADDR_W < 2 rejected at elaboration.

Sources: `src/axi4_lite_slave.sv`

[HTML module page](../bus/axi4_lite_slave/docs/index.html)

## axi4_lite_regs

**Axi4 Lite Regs** · category `bus` · top `axi4_lite_regs`

AXI4-Lite register bank with per-register access types. Version 1.0.0. NREG 32-bit registers, each RW (0, software read/write with byte strobes), RO (1, reads hw_i, writes rejected with SLVERR), W1C (2, status register - hardware sets bits through hw_set_i, software clears bits by writing 1) or W1S (3, software sets bits by writing 1, hardware clears through hw_set_i). ACCESS holds 2 bits per register. RESET_VALS holds reset values. reg_o exposes RW/W1C/W1S state, wr_pulse_o pulses for one clock on any write to register n. Built on axi4_lite_slave (same handshake rules and latency). Clock - aclk. Reset - synchronous aresetn, registers take RESET_VALS. Latency - write 4 clocks, read 4 clocks. Errors - SLVERR on write to RO, DECERR beyond NREG words; NREG < 1 rejected at elaboration.

Sources: `../../bus/axi4_lite_slave/src/axi4_lite_slave.sv`, `src/axi4_lite_regs.sv`

[HTML module page](../bus/axi4_lite_regs/docs/index.html)

## axi4_lite_decoder

**Axi4 Lite Decoder** · category `bus` · top `axi4_lite_decoder`

AXI4-Lite address decoder. Version 1.0.0. Purely combinational decode of an address into a one-hot slave select over NSLAVE regions. Region i matches when (addr & MASK[i]) == BASE[i] (MASK selects the compared address bits, so a 4 KB region at 0x1000 uses BASE=0x1000 and MASK=0xFFFFF000). When more than one region matches the lowest index wins and multi_o is raised (a configuration error the parameter check also reports for constant overlaps). No match sets miss_o (unmapped access, the caller returns DECERR). Clock - none (combinational, 0 latency). Reset - none. Timing - one masked compare per region. Errors - overlapping regions rejected at elaboration; NSLAVE < 1 rejected. Latency - 0 clocks (combinational).

Sources: `src/axi4_lite_decoder.sv`

[HTML module page](../bus/axi4_lite_decoder/docs/index.html)

## axi4_lite_mux

**Axi4 Lite Mux** · category `bus` · top `axi4_lite_mux`

AXI4-Lite 1-to-N interconnect (address decoded mux). Version 1.0.0. One AXI-Lite slave port is routed to NSLAVE master ports selected by axi4_lite_decoder (BASE/MASK regions). Addresses are passed through unchanged. One write and one read may be outstanding at a time (reads and writes are independent). Accesses that hit no region are answered directly with DECERR (bresp/rresp = 2'b11, read data 0) and never reach a slave. Master-port signals are packed vectors (slave i uses slice i). Clock - aclk. Reset - synchronous aresetn, idle. Latency - 1 clock for write/read address acceptance plus 1 clock for the response beat on top of the slave latency. Timing - decoder output is registered before use. Errors - DECERR for unmapped addresses; an ill-formed region map is rejected by the decoder at elaboration.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `../../bus/axi4_lite_decoder/src/axi4_lite_decoder.sv`, `src/axi4_lite_mux.sv`

[HTML module page](../bus/axi4_lite_mux/docs/index.html)

## axi_stream_fifo

**Axi Stream Fifo** · category `bus` · top `axi_stream_fifo`

AXI-Stream FIFO. Version 1.0.0. Buffers a full AXI-Stream (tdata, tkeep, tlast, tuser) in a block-RAM FIFO of DEPTH beats with standard valid/ready handshakes and a fill level. Built on ip_axis_fifo (two-register output pipeline for timing). Clock - aclk. Reset - synchronous aresetn, empty. Latency - 3 clocks from an input beat to the output when empty. Throughput - one beat per clock. Backpressure - s_axis_tready low when full; no data is ever dropped. Errors - DEPTH must be a power of two >= 4 (rejected at elaboration); USER_W >= 1.

Sources: `../../shared/src/fifo/ip_axis_fifo.sv`, `src/axi_stream_fifo.sv`

[HTML module page](../bus/axi_stream_fifo/docs/index.html)

## axi_stream_width_converter

**Axi Stream Width Converter** · category `bus` · top `axi_stream_width_converter`

AXI-Stream data width converter. Version 1.0.0. Converts between IN_BYTES and OUT_BYTES wide streams; one width must be an integer multiple of the other (or equal, giving a register slice). Little-endian byte order - byte 0 of the wide word is the first byte on the narrow side. tkeep and tlast are honoured. Downsizing splits each input beat into OUT_BYTES chunks, skipping trailing all-zero-keep chunks and setting tlast on the last valid chunk of a packet. Upsizing packs beats into one output word, flushing early on tlast (tkeep marks the valid bytes). tuser is carried on the tlast beat only. Clock - aclk. Reset - synchronous aresetn, idle. Throughput - full rate on the narrow side. Latency - 1 clock (downsize/equal) or IN/OUT ratio clocks (upsize). Errors - unsupported ratios rejected at elaboration; tkeep patterns must be contiguous from byte 0 (a gap raises keep_err_o for one clock and the beat is passed as given).

Sources: `src/axi_stream_width_converter.sv`

[HTML module page](../bus/axi_stream_width_converter/docs/index.html)

## axi_stream_arbiter

**Axi Stream Arbiter** · category `bus` · top `axi_stream_arbiter`

AXI-Stream arbiter (N inputs to one output). Version 1.0.0. Packet-granular arbitration - once an input wins, it keeps the output until its tlast beat has been transferred, so packets from different inputs are never interleaved. PRIORITY 0 is round-robin (the input after the last winner is preferred), 1 is fixed priority with input 0 highest. Signals are packed vectors (input i uses slice i). The output is a registered slice (one extra register stage, full throughput). Clock - aclk. Reset - synchronous aresetn, idle, no owner. Latency - 2 clocks from arbitration to first output beat; back-to-back packets from different inputs add 1 idle clock. Errors - a packet longer than TIMEOUT beats without tlast releases the grant (locked_out inputs are not starved) and raises hog_o; TIMEOUT=0 disables. NIN<2 rejected at elaboration.

Sources: `src/axi_stream_arbiter.sv`

[HTML module page](../bus/axi_stream_arbiter/docs/index.html)

## parity_gen

**Parity Gen** · category `integrity` · top `parity_gen`

Parity generator. Version 1.0.0. parity_o is the XOR reduction of data_i (even parity - data plus parity bit contain an even number of ones) or its inverse for ODD=1. REGISTERED=1 adds one output register (latency 1, synchronous active-low reset to the parity of an all-zero word); otherwise the module is combinational with 0 latency and clk/rst_n unused. Clock - clk when registered. Timing - log2(WIDTH) XOR levels; register wide words at 100 MHz. Errors - WIDTH < 1 rejected at elaboration. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. as documented in the parent block, fixed and independent of data.

Sources: `src/parity_gen.sv`

[HTML module page](../integrity/parity_gen/docs/index.html)

## parity_check

**Parity Check** · category `integrity` · top `parity_check`

Parity checker. Version 1.0.0. err_o goes high for a word whose received parity bit does not match (even parity, or odd with ODD=1); sticky_o remembers any error until clr_i, and err_count_o counts errors (saturating). Words are qualified by valid_i. Clock - clk. Reset - synchronous active low, no errors. Latency - err_o, sticky_o and the counter are registered, 1 clock after valid_i. Detection - all odd numbers of bit flips (including the parity bit); even numbers of flips are not detected. Errors - WIDTH < 1 rejected at elaboration.

Sources: `src/parity_check.sv`

[HTML module page](../integrity/parity_check/docs/index.html)

## crc8

**Crc8** · category `integrity` · top `crc8`

CRC-8 (polynomial 0x07, init 0, no reflection). Version 1.0.0. Thin wrapper around crc_core with the standard CRC8 parameters as defaults (POLY, INIT, reflection and final XOR are overridable for other 8-bit CRCs). Bytes are consumed little-endian, DATA_W bits per clock, keep_i marks valid bytes of a partial last word. Clock - clk. Reset - synchronous active low, register = INIT. Latency - crc_o updates 1 clock after valid_i. Check value - CRC of the ASCII string 123456789 is 0xF4. Errors - invalid widths rejected at elaboration by crc_core.

Sources: `../../shared/src/integrity/crc_core/crc_core.sv`, `src/crc8.sv`

[HTML module page](../integrity/crc8/docs/index.html)

## crc16

**Crc16** · category `integrity` · top `crc16`

CRC-16/CCITT-FALSE (polynomial 0x1021, init 0xFFFF, no reflection). Version 1.0.0. Thin wrapper around crc_core with the standard CRC16 parameters as defaults (POLY, INIT, reflection and final XOR are overridable for other 16-bit CRCs). Bytes are consumed little-endian, DATA_W bits per clock, keep_i marks valid bytes of a partial last word. Clock - clk. Reset - synchronous active low, register = INIT. Latency - crc_o updates 1 clock after valid_i. Check value - CRC of the ASCII string 123456789 is 0x29B1. Errors - invalid widths rejected at elaboration by crc_core.

Sources: `../../shared/src/integrity/crc_core/crc_core.sv`, `src/crc16.sv`

[HTML module page](../integrity/crc16/docs/index.html)

## crc32

**Crc32** · category `integrity` · top `crc32`

CRC-32 IEEE 802.3 (polynomial 0x04C11DB7, reflected, init and final XOR 0xFFFFFFFF). Version 1.0.0. Thin wrapper around crc_core with the standard CRC32 parameters as defaults (POLY, INIT, reflection and final XOR are overridable for other 32-bit CRCs). Bytes are consumed little-endian, DATA_W bits per clock, keep_i marks valid bytes of a partial last word. Clock - clk. Reset - synchronous active low, register = INIT. Latency - crc_o updates 1 clock after valid_i. Check value - CRC of the ASCII string 123456789 is 0xCBF43926. Errors - invalid widths rejected at elaboration by crc_core.

Sources: `../../shared/src/integrity/crc_core/crc_core.sv`, `src/crc32.sv`

[HTML module page](../integrity/crc32/docs/index.html)

## checksum

**Checksum** · category `integrity` · top `checksum`

Configurable byte-stream checksum. Version 1.0.0. MODE 0 is an 8-bit two's-complement sum (the sum of all bytes plus the checksum is 0 mod 256), MODE 1 is the RFC 1071 Internet checksum (16-bit one's complement sum of big-endian byte pairs, inverted; an odd final byte is padded with zero), MODE 2 is Fletcher-16 (two running sums modulo 255). One byte is consumed per clock when valid_i is high; init_i clears the state. checksum_o always reflects the bytes consumed so far (a pending odd Internet byte is padded on the fly), so no flush is needed. ok_o is high when the stream seen so far includes its own checksum and the total verifies (Internet result 0xFFFF sum / SUM8 zero / Fletcher-16 both sums zero). Clock - clk. Reset - synchronous active low, empty state. Latency - checksum_o valid 1 clock after the last byte. Errors - MODE outside 0..2 rejected at elaboration.

Sources: `src/checksum.sv`

[HTML module page](../integrity/checksum/docs/index.html)

## lfsr

**Lfsr** · category `integrity` · top `lfsr`

Linear-feedback shift register / PRBS generator. Version 1.0.0. Fibonacci LFSR of WIDTH bits with feedback taps TAPS (bit i of TAPS set means state bit i is XORed into the feedback). Defaults implement PRBS7 (x^7+x^6+1, TAPS=0x60, period 127). STEPS shifts are computed per enabled clock (parallel PRBS, STEPS bits per clock, bit_o[STEPS-1:0] with bit 0 the oldest). load_i loads seed_i; an all- zero seed (the lock-up state) is replaced by SEED and flagged on lockup_o. Clock - clk. Reset - synchronous active low, state = SEED. Latency - state_o updates 1 clock after en_i. Errors - WIDTH < 2, STEPS < 1, TAPS = 0 or SEED = 0 rejected at elaboration.

Sources: `src/lfsr.sv`

[HTML module page](../integrity/lfsr/docs/index.html)

## error_status

**Error Status** · category `integrity` · top `error_status`

Sticky hardware error/status register. Version 1.0.0. NERR error inputs (level or pulse) set sticky bits in status_o. Software clears bits with clr_mask_i (write-1-to-clear style, one clock, a simultaneous new error wins) or all with clr_all_i. irq_mask_i gates irq_o = |(status_o & irq_mask_i), which is a level until cleared. first_idx_o holds the lowest index that fired in the earliest error clock since the last clear (first_valid_o marks it), useful for root- cause logging, and count_o counts total error clocks (saturating). Clock - clk. Reset - synchronous active low, all clear. Latency - status_o is registered, 1 clock after err_i; irq_o adds combinational AND-OR. Errors - NERR < 1 rejected at elaboration.

Sources: `src/error_status.sv`

[HTML module page](../integrity/error_status/docs/index.html)

## spi_slave

**Spi Slave** · category `peripherals` · top `spi_slave`

SPI slave (all four modes, 1..32 bit words, MSB or LSB first). Version 1.0.0. sclk, cs_n and mosi are asynchronous inputs, each passed through a 2-flop synchronizer and edge-detected in the system clock domain, so no SPI signal is used as a clock. Requirement - sclk period at least 6 system clocks (f_sclk <= f_clk/6, e.g. 16 MHz sclk at 100 MHz) and cs_n low at least 4 system clocks before the first sclk edge. Transmit - the word offered on tx_data_i (tx_valid_i high) is loaded when cs_n falls and after every completed word, tx_ready_o pulses when it is taken; if none is offered zeros are sent and underrun_o pulses. Receive - rx_valid_o pulses for one clock with rx_data_o after every full word. Frame errors - cs_n rising in the middle of a word discards it and pulses frame_err_o. miso_oe_o is high while cs_n is low (connect to a tri-state buffer at the top level; no vendor primitive here). Reset - synchronous active low, idle. Latency - rx_valid_o about 3 system clocks after the sampling sclk edge. Errors - WORD_BITS outside 1..32 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it. synchronous to it.

Sources: `../../cdc/bit_sync/src/bit_sync.sv`, `src/spi_slave.sv`

[HTML module page](../peripherals/spi_slave/docs/index.html)

## clock_domain_bridge

**Clock Domain Bridge** · category `cdc` · top `clock_domain_bridge`

Generic clock-domain bridge for multi-bit words using a four- phase toggle handshake. Version 1.0.0. A word accepted on the source valid/ready interface is held in a source register while a request toggle crosses to the destination (bit_sync); the destination copies the word into its own output register (data is stable, so the multi-bit capture is safe), presents it on the destination valid/ready interface and, when it is taken, returns an acknowledge toggle. The source is ready again only after the acknowledge has been synchronized back, so at most one word is in flight and words are never lost, duplicated or reordered. Clocks - s_clk and m_clk unrelated, any ratio. Reset - synchronous per domain, active low; reset both domains together (or hold the slower one longer). Latency - about 2*STAGES+3 clocks of the slower domain per word. Throughput - one word per round trip (low), use async_fifo for streaming. Timing - the data register to destination register path is a false path or a max-delay constraint of one destination period; no combinational logic on it. Errors - STAGES < 2 or DATA_W < 1 rejected at elaboration. Clock - the clock of the parent block, all signals are synchronous to it.

Sources: `../../cdc/bit_sync/src/bit_sync.sv`, `src/clock_domain_bridge.sv`

[HTML module page](../cdc/clock_domain_bridge/docs/index.html)

## uart_tx

**Uart Tx** · category `peripherals` · top `uart_tx`

UART transmitter. Pulls bytes from an AXI-Stream style interface and shifts them out LSB first with a start bit, 5 to 8 data bits, optional even or odd parity and one or two stop bits. Bit timing comes from a 16x tick so each bit lasts 16 ticks. The tx line is registered to avoid glitches. Version 1.0.0. Helper block of its IP; see the top level description for clock, reset, latency and error behavior. Clock - the clock of the parent block, all signals are synchronous to it. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. Errors - none reported here, out-of-range parameters stop elaboration or are handled by the parent block. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. Errors - none reported here, out-of-range parameters stop elaboration or are handled by the parent block.

Sources: `../../peripherals/uart/src/uart_tx.sv`, `../../timing/baud_generator/src/baud_generator.sv`

[HTML module page](../peripherals/uart_tx/docs/index.html)

## uart_rx

**Uart Rx** · category `peripherals` · top `uart_rx`

UART receiver. Two flop synchronizer, start bit qualification at mid bit, then sampling every 16 ticks in the middle of each bit. Supports 5 to 8 data bits, optional parity and stop bit check. Produces a one clock word strobe with parity and framing error flags. Break and noise on the start bit are rejected. Version 1.0.0. Helper block of its IP; see the top level description for clock, reset, latency and error behavior. Clock - the clock of the parent block, all signals are synchronous to it. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. Errors - none reported here, out-of-range parameters stop elaboration or are handled by the parent block. synchronous to it. Reset - synchronous, driven by the parent block. Latency - as documented in the parent block, fixed and independent of data. Errors - none reported here, out-of-range parameters stop elaboration or are handled by the parent block.

Sources: `../../peripherals/uart/src/uart_rx.sv`, `../../timing/baud_generator/src/baud_generator.sv`

[HTML module page](../peripherals/uart_rx/docs/index.html)

## cordic

**Cordic** · category `common` · top `cordic`

Pipelined CORDIC. Version 1.0.0. MODE 0 (rotation) rotates the vector (x_i, y_i) by the angle z_i, giving x*cos-y*sin and x*sin+y*cos (with x_i=A, y_i=0 it is a sine/cosine generator of amplitude A); MODE 1 (vectoring) returns the magnitude sqrt(x^2+y^2) in mag_o and the angle atan2(y,x) in z_o. Angles are unsigned turns - z is ZW bits and 2^ZW equals 2*pi, so the phase word of an NCO connects directly. Full-circle range is handled by a quadrant pre- rotation, the CORDIC gain (1.6468) is compensated by a constant multiplier, and WIDTH+2 guard bits are used internally. One result per clock (fully pipelined), ITER micro-rotations. Clock - clk with valid_i/valid_o. Reset - synchronous active low clears the valid pipeline (data registers are unreset, valid_o=0 masks them). Latency - ITER+2 clocks. Accuracy - about 2 LSB in rotation mode and 2 LSB plus 2^-ITER rad in vectoring mode; inputs must satisfy |(x,y)| <= 2^(WIDTH-1)-1 (rotation) so results fit; magnitude output has WIDTH+1 bits. Errors - out-of-range parameters rejected at elaboration.

Sources: `src/cordic.sv`

[HTML module page](../common/cordic/docs/index.html)

## dds

**Dds** · category `common` · top `dds`

Direct digital synthesizer (sine/cosine generator). Version 1.0.0. A PHASE_W bit phase accumulator (nco) steps by tuning_i on every enabled clock (f_out = tuning * f_clk / 2^PHASE_W, so 1 MHz at 100 MHz needs tuning = 2^32/100) and its top ZW bits drive a cordic in rotation mode that turns the phase into signed sin_o and cos_o of amplitude 2^(OUT_W-1)-1 - no lookup table, so the resolution parameters are freely configurable. phase_off_i adds a phase offset (phase modulation) and sync_load_i loads the accumulator. Clock - clk, one sample per enabled clock. Reset - synchronous active low, phase 0, valid_o low. Latency - ITER+3 clocks from en_i to valid output. Accuracy - about 4 LSB plus the phase truncation error of 2^-ZW turns; spurious-free range grows with ZW. Tuning above half the sample rate aliases (nyquist_o flags it). Errors - parameter ranges are checked by the nco and cordic instances at elaboration.

Sources: `../../common/cordic/src/cordic.sv`, `../../timing/nco/src/nco.sv`, `src/dds.sv`

[HTML module page](../common/dds/docs/index.html)

## fir

**Fir** · category `common` · top `fir`

Streaming FIR filter (transposed form, run-time loadable coefficients). Version 1.0.0. TAPS coefficients of COEF_W bits (signed, load with coef_we_i / coef_idx_i / coef_i at any time; a coefficient change applies from the next sample) process one input sample per valid_i with a fully parallel multiplier array (maps to DSP blocks). The accumulator is DATA_W+COEF_W+log2(TAPS) bits wide so it never overflows; the output is rounded (add half LSB), shifted right by OUT_SHIFT and saturated to OUT_W bits (sat_o pulses when clipping). A coefficient set with sum equal to 2^OUT_SHIFT has unity DC gain. Clock - clk. Reset - synchronous active low clears the delay line, all coefficients and valid_o. Latency - 1 clock from valid_i to valid_o. Throughput - one sample per clock, no back-pressure (valid_i may be gated freely; the filter only advances on valid_i). Errors - TAPS < 2, widths < 2 or OUT_SHIFT beyond the accumulator rejected at elaboration.

Sources: `src/fir.sv`

[HTML module page](../common/fir/docs/index.html)

## cic

**Cic** · category `common` · top `cic`

CIC decimation filter (cascaded integrator-comb). Version 1.0.0. N integrators run at the input rate with wrap-around arithmetic, the stream is decimated by r_i (1..RMAX, run-time programmable, latched at the start of each output period) and N combs (differential delay 1) run at the output rate. Register width is DATA_W + N*ceil(log2(RMAX)) so the wrap-around cannot corrupt the result. DC gain is r^N; the output is the arithmetic right shift of the comb result by shift_i (use N*log2(r) for power-of-two ratios to get unity gain), rounded and saturated to OUT_W bits (sat_o flags clipping). Clock - clk, one input per valid_i. Reset - synchronous active low clears all integrators and combs. Latency - the output appears with the clock after the r_i-th input of a period (1 clock). Droop - CIC passband droop is not compensated (follow with a fir). Errors - N or RMAX out of range rejected at elaboration; r_i outside 1..RMAX is clamped and flagged on r_err_o.

Sources: `src/cic.sv`

[HTML module page](../common/cic/docs/index.html)

## ecc_memory_ctrl

**Ecc Memory Ctrl** · category `integrity` · top `ecc_memory_ctrl`

ECC-protected memory controller. Version 1.0.0. A DEPTH x DATA_W word memory (inferred RAM, stored as SECDED codewords) behind a simple request interface. Writes store the encoded word; reads fetch the codeword, correct any single-bit error, flag double-bit errors (sec_o / ded_o with rvalid_o) and count them (saturating counters, err_addr_o keeps the address of the last error). With SCRUB=1 a corrected read writes the repaired codeword back, which stalls new requests for one clock (ready_o low) and halves read throughput, so a soft error is not allowed to accumulate into an uncorrectable one. inject_i (test aid) is XORed into the codeword of the next write to create memory errors on demand - tie to zero in a product. Clock - clk. Reset - synchronous active low clears counters and pipeline, memory contents are undefined until written (reads of never-written words may report errors). Latency - read data 2 clocks after the accepted request (rdata_o / flags with rvalid_o), write takes effect the next clock. Throughput - one request per clock (SCRUB=0). Errors - ded_o (uncorrectable, data_o unreliable), sec_o (corrected), counters; DEPTH<2 rejected at elaboration.

Sources: `src/ecc_secded.sv`, `src/ecc_memory_ctrl.sv`

[HTML module page](../integrity/ecc_memory_ctrl/docs/index.html)

## packet_parser

**Packet Parser** · category `bus` · top `packet_parser`

AXI-Stream packet parser and filter. Version 1.0.0. Captures the first HDR_BYTES of every packet (HDR_BYTES must be a multiple of the stream width so headers are beat aligned) into hdr_o and pulses hdr_valid_o when the header is complete, then either strips the header (STRIP=1) or forwards it (STRIP=0) and forwards the payload. A run-time filter compares the header with cfg_value_i under cfg_mask_i; with drop_nomatch_i set, packets that do not match are consumed and their payload is discarded (drop_o pulses at the last beat), so only accepted packets reach the master port. With STRIP=0 the header beats are forwarded before the match is known and only the payload is filtered. Every packet also reports its byte length (tkeep aware) on len_o / len_valid_o, and packets that end before the header is complete are flagged with runt_o and produce no output. Clock - aclk. Reset - synchronous aresetn, idle, outputs low. Latency - 0 clocks (combinational valid/ready pass-through of accepted payload beats); hdr_o and flags are registered, 1 clock after the header's last beat. Errors - runt_o, drop_o; HDR_BYTES not a multiple of DATA_W/8 rejected at elaboration.

Sources: `src/packet_parser.sv`

[HTML module page](../bus/packet_parser/docs/index.html)

## packet_formatter

**Packet Formatter** · category `bus` · top `packet_formatter`

AXI-Stream packet formatter. Version 1.0.0. Builds outgoing packets from a payload stream - a header of HDR_BYTES (sampled from hdr_i when the first payload beat arrives, must be a multiple of the stream width) is prepended, zero pad beats are appended until the packet has at least MIN_BEATS beats, and an optional trailer beat (trailer_i, sampled with the header) can be appended. tlast is moved to the final inserted beat. Padding or a trailer requires the payload length to be a multiple of the stream width (full tkeep on the last payload beat); otherwise align_err_o pulses and the packet is sent without tail. It is the inverse of packet_parser with STRIP=1. Clock - aclk. Reset - synchronous aresetn, idle. Latency - 1 clock to start a packet (header sampling), then one beat per clock; header beats stall the payload input. Errors - align_err_o; misaligned HDR_BYTES rejected at elaboration.

Sources: `../../bus/packet_parser/src/packet_parser.sv`, `src/packet_formatter.sv`

[HTML module page](../bus/packet_formatter/docs/index.html)

## i2s

**I2S** · category `peripherals` · top `i2s`

I2S master transmitter and receiver (Philips I2S format). Version 1.0.0. Generates BCLK and LRCK from the system clock (half period bclk_half_i system clocks, so BCLK = f_clk / (2*bclk_half)) with LRCK low for the left slot and high for the right slot, data changing on BCLK falling edges with the MSB one BCLK after the LRCK edge, and samples sd_i on BCLK rising edges. Word width WORD_W (2..32 bits) equals the slot width, one frame is 2*WORD_W BCLKs (for a 48 kHz frame at 100 MHz choose WORD_W=32 and bclk_half=... BCLK 3.072 MHz needs bclk_half of about 16). Transmit takes a left/right sample pair with tx_valid_i/tx_ready_o (tx_ready_o pulses when the pair is latched at the frame boundary; if none is offered zeros are sent and underrun_o pulses). Receive delivers each completed frame as rx_left_o/rx_right_o with a one-clock rx_valid_o (the first partial frame after enabling is discarded). sd_i must be synchronous to the BCLK this block drives (device delay under half a BCLK). Clock - clk. Reset - synchronous active low, BCLK/LRCK/SD low, idle. Latency - a sample offered before a frame boundary is on the wire from the next frame; receive result 1 clock after the last bit. Errors - bclk_half_i = 0 is treated as 1; WORD_W outside 2..32 rejected at elaboration.

Sources: `src/i2s.sv`

[HTML module page](../peripherals/i2s/docs/index.html)

## eth_mac_if

**Eth Mac If** · category `peripherals` · top `eth_mac_if`

Ethernet MAC interface (GMII, 8 bit, single clock). Version 1.0.0. Transmit - takes an AXI-Stream frame (destination MAC onward, no preamble or FCS) and drives GMII with 7 preamble bytes and the start-of-frame delimiter, the frame data, zero padding up to MIN_FRAME bytes before the FCS (60 by default), the CRC-32 frame check sequence (low byte first) and a 12 byte inter-frame gap. The source must deliver the frame without gaps (put a packet_fifo in front): a gap aborts the frame with gmii_tx_er and underrun_o. Receive - finds the start-of-frame delimiter, removes the FCS, streams the frame to an AXI-Stream master (tlast on the last data byte, tuser high on that beat when the frame is bad - FCS mismatch, gmii_rx_er, or shorter than 64 bytes including FCS) and pulses crc_err_o / short_o / rx_err_o. The receiver cannot stall the wire: a byte presented while m_axis_tready is low is lost and overflow_o pulses. Use with 125 MHz GMII (or a 100 MHz clock at 100 Mbit/s with tx/rx clock enables outside this block); no MDIO, no flow control. Clock - clk shared by transmit and receive. Reset - synchronous aresetn, idle, gmii_tx_en low. Latency - transmit: 8 preamble clocks plus 1; receive: 6 bytes (FCS removal plus output register). Errors - underrun_o, overflow_o, crc_err_o, short_o, rx_err_o as described.

Sources: `../../shared/src/integrity/crc_core/crc_core.sv`, `../../integrity/crc32/src/crc32.sv`, `src/eth_mac_if.sv`

[HTML module page](../peripherals/eth_mac_if/docs/index.html)

## spi_flash_ctrl

**Spi Flash Ctrl** · category `peripherals` · top `spi_flash_ctrl`

SPI NOR flash controller (single-bit SPI mode 0, 3-byte addressing, e.g. W25Qxx / S25FL / MX25). Version 1.0.0. AXI4-Lite registers issue generic commands - write CMD (0x00) with opcode[7:0], addr_en[8], dummy bytes[15:12], read_data[16], write_data[17] after setting ADDR (0x04, 24 bit) and LEN (0x08, data bytes 0..65535); the controller then drives cs_n, sends opcode, address and dummy bytes and moves LEN data bytes: bytes read from the flash leave on the AXI- Stream master port (m_axis) and bytes to write are taken from the AXI- Stream slave port (s_axis), each waiting for the stream handshake with sclk stopped between bytes (so the flash never sees a gap it cannot handle, and no byte is lost). Any flash command is expressible: 9F read ID, 03/0B read, 06 write enable, 02 page program, 20/D8/C7 erase, 05 read status (poll STATUS-of-flash yourself by issuing 05 with LEN=1). Registers - 0x00 CMD (write starts, reads back last), 0x04 ADDR, 0x08 LEN, 0x0C CLKDIV (sclk half period in clocks, min 3, reset 4, so 12.5 MHz at 100 MHz), 0x10 STATUS (bit0 busy, bit1 done sticky, bit2 cmd_err sticky; write 1 to clear bits 1 and 2), 0x14 IRQ_EN (bit0), 0x18 IP_VERSION. A CMD written while busy is ignored and sets cmd_err. irq_o = done & IRQ_EN. Clock - aclk; miso is asynchronous and double-registered, which is why the half period is at least 3 clocks. Reset - synchronous aresetn, cs_n high, sclk low. Timing - cs_n is asserted one half period before the first sclk edge, held one half period after the last, and kept high for two half periods between commands. Latency - command starts 2 clocks after the CMD write; data throughput is 8 bit times per byte plus stream wait. The flash write- in-progress state is the flash's own business: poll it with command 05. Errors - cmd_err (command while busy); a stalled stream simply pauses the transfer.

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/spi_flash_ctrl.sv`

[HTML module page](../peripherals/spi_flash_ctrl/docs/index.html)

## sdio_host

**Sdio Host** · category `peripherals` · top `sdio_host`

SD / SDIO host controller (single-block transfers, 1-bit or 4-bit data bus, SD mode). Version 1.0.0. AXI4-Lite registers issue one command at a time - 0x00 CMD (write starts it): index[5:0], response[7:6] (0 none, 1 short 48 bit, 2 long 136 bit), data direction[9:8] (0 none, 1 read block, 2 write block), no_crc_check[10] (for R3/R7-style responses without valid CRC7); 0x04 ARG; 0x08..0x14 RESP0..RESP3 (short response argument in RESP0, long response 127..0 in RESP3..RESP0); 0x18 STATUS (bit0 busy, bit1 cmd_done, bit2 dat_done, bit3 cmd_timeout, bit4 cmd_crc_err, bit5 dat_crc_err, bit6 dat_timeout, bit7 buf_err; write 1 to clear bits 1-7); 0x1C CTRL (half_period[15:0] in system clocks, minimum 1, bus4[16], clk_en[17]); 0x20 BLKSIZE (bytes, 1..BUF_BYTES); 0x24 TIMEOUT (SD clocks for data/busy timeout); 0x28 IRQ_EN (bit n enables STATUS bit n+1 for irq_o); 0x2C IP_VERSION. Data - a block buffer of BUF_BYTES bytes decouples the free-running SD clock from AXI-Stream: for a write, fill the buffer through s_axis (BLKSIZE bytes, only accepted while idle) and then issue the write command; a read block is verified (CRC16 per data line) and only then streamed out on m_axis (tlast on the final byte), a block with a CRC error is discarded. The command engine appends CRC7, checks the CRC7 of short responses, waits up to 80 SD clocks for a response, and for writes handles the CRC status token and the busy signal. SD signals - sd_clk_o (half period = CTRL.half_period system clocks), cmd_o/cmd_oe_o/cmd_i and dat_o/dat_oe_o/dat_i[3:0] are separate outputs and inputs (connect to tri-state buffers at the top level, external pull-ups on CMD/DAT); outputs change on the falling edge of sd_clk_o, inputs are double-registered and sampled on rising edges. Clock - aclk; SD clock runs only while CTRL.clk_en=1 and must be running for a command to progress (initialisation at 400 kHz needs a half period of 125 at 100 MHz). Not supported - multi-block transfers, SPI mode, UHS-I / 1.8 V, DMA. Reset - synchronous aresetn, sd_clk low, all lines released. Latency - about 2*half_period system clocks per SD clock; a 512 byte block takes about 1100 SD clocks in 4-bit mode and 4200 in 1-bit mode. Errors - cmd_timeout, cmd_crc_err, dat_crc_err (also for a bad end bit or write CRC status), dat_timeout, buf_err (bad BLKSIZE, write without a full buffer, or a command while busy).

Sources: `../../shared/src/common/ip_axil_regs.sv`, `src/sdio_host.sv`

[HTML module page](../peripherals/sdio_host/docs/index.html)

## demo_regs

**Demo Regs** · category `bus` · top `demo_regs`

Generated AXI4-Lite register block 'demo_regs' with 6 registers (regmap_gen.py, do not edit by hand; regenerate from the JSON description). Version 1.0.0. Built on axi4_lite_regs, so the timing is the same. Clock - aclk. Reset - synchronous aresetn, registers take their documented reset values. Latency - write 4 clocks, read 4 clocks. Errors - writes to RO registers answer SLVERR, addresses beyond the last register answer DECERR. Access types - RW read/write with byte strobes, RO read only, W1C hardware sets and software clears by writing 1, W1S software sets and hardware clears.

Sources: `../../bus/axi4_lite_slave/src/axi4_lite_slave.sv`, `../../bus/axi4_lite_regs/src/axi4_lite_regs.sv`, `src/demo_regs.sv`

[HTML module page](../bus/demo_regs/docs/index.html)

## pcie_tl_ep

**Pcie Tl Ep Top** · category `peripherals` · top `pcie_tl_ep_top`

PCIe transaction layer endpoint IP top level. 64 bit AXI- Stream TLP ports (rx from and tx to a PCIe link core such as a hard block), Type 0 config space, BAR0 with block RAM and a stream window, plus AXI-Stream user ports - s_axis words are DMA written to host memory as Memory Write TLPs, m_axis carries payload written to the BAR0 stream window. AXI-Lite map - 0x00 CTRL[0]=dma_en; 0x04/0x08 DMA_ADDR lo/hi; 0x0C DMA_LEN_DW; 0x10 STATUS [0]mem_en [1]bus_master [2]dma_busy; 0x14 CPL_ID; 0x18 BAR0; 0x1C RX_TLP; 0x20 MWR; 0x24 MRD; 0x28 CFG; 0x2C UR; 0x30 DMA_TLP counters. PHY, LTSSM and data link layer are not included. Version 1.0.0. Scope - transaction layer only (no PHY, data link layer, LTSSM, credit or flow-control logic; a link core must supply the TLP stream). Clock - aclk (250 MHz class for a Gen2 x4 link core, 100 MHz used in simulation), everything synchronous. Reset - synchronous aresetn, DMA idle, counters cleared, BAR RAM contents undefined. Latency - a memory read is answered with a completion about 5 clocks after the request TLP ends; a memory write reaches the RAM 2 clocks after the last beat. Errors - unsupported requests are answered with an Unsupported Request completion and counted (UR counter); illegal parameters stop elaboration.

Sources: `src/pcie_axis_to_dw.sv`, `src/pcie_dw_to_axis.sv`, `src/pcie_axis_fifo.sv`, `src/pcie_axil_regs.sv`, `src/pcie_tl_target.sv`, `src/pcie_tl_dma.sv`, `src/pcie_tl_ep_top.sv`

[HTML module page](../peripherals/pcie_tl_ep/docs/index.html)

## usb_fs_sie

**Usb Fs Sie Top** · category `peripherals` · top `usb_fs_sie_top`

USB 1.1 full-speed serial interface engine IP. Bit-level D+/D- interface (NRZI, bit stuffing, SYNC, EOP, CRC5/CRC16, PID check, bus reset detect) with AXI-Stream packet ports. m_axis delivers each received packet as PID (low nibble), payload bytes (CRC16 removed), tlast on the last byte and tuser=1 for packets with errors. s_axis takes packets to send - byte 0 is the PID nibble, then payload; a complete packet must be written before it is transmitted. No enumeration, endpoint or protocol layer is included. AXI-Lite map - 0x00 CTRL [0]enable [1]D+ pull-up; 0x04 STATUS [0]bus_reset(W1C) [1]rx_overflow(W1C) [2]tx_busy [3]rx_active [9:8]line D+/D-; 0x08 RX_GOOD; 0x0C RX_BAD; 0x10 TX_PKTS; 0x14 BIT_PERIOD (8.8 clocks). Version 1.0.0. Scope - serial interface engine only (no enumeration, endpoints or protocol stack). Clock - aclk, verified in simulation at 48, 60 and 100 MHz only (BIT_PERIOD is an 8.8 fixed point clocks-per-bit value; other frequencies are untested). Reset - synchronous aresetn, D+/D- released, pull-up off, FIFOs empty. Latency - a packet is sent a few bit times after it is complete in the transmit FIFO, and a received packet appears on m_axis after the EOP and CRC check. Errors - tuser on bad packets (CRC, PID check, stuff error), RX_BAD counter, rx_overflow flag, bus_reset flag; illegal parameters stop elaboration.

Sources: `src/usb_fs_rx.sv`, `src/usb_fs_tx.sv`, `src/usb_axis_fifo.sv`, `src/usb_axil_regs.sv`, `src/usb_fs_sie_top.sv`

[HTML module page](../peripherals/usb_fs_sie/docs/index.html)

## axi_checkers

**axi_checkers** · category `scalers` · top `axis_checker`

Passive protocol checkers with functional coverage. axis_checker covers AXI4-Stream handshake rules (no valid retraction, stable payload under stall, no X) and video framing (tuser on the first beat, tlast at the end of each line, complete frames). axil_checker covers the AXI4-Lite master and slave rules on all five channels, response ordering and OKAY responses. Each rule is implemented twice: as procedural checks that run on every simulator including Icarus, and as SVA properties compiled with +define+SVA_ON. Coverage counters (orderings, stalls, stall-length buckets, back-to-back transfers, frames) are printed by report(). The testbench drives legal traffic (zero errors expected) and then violates every rule on purpose (each must be detected).

Sources: `src/axil_checker.sv`, `src/axis_checker.sv`

[HTML module page](../scalers/axi_checkers/docs/index.html)

## axil_regbus

**axil_regbus** · category `scalers` · top `axil_regbus`

AXI4-Lite slave that converts AXI transactions into a one-cycle register bus (reg_wr / reg_rd, 1-cycle read latency).

Sources: `src/axil_regbus.sv`

[HTML module page](../scalers/axil_regbus/docs/index.html)

## axil_split

**axil_split** · category `scalers` · top `axil_split`

AXI4-Lite 1-to-2 address decoder: routes each transaction to slave port 0 or 1 by address bit SEL_BIT (default: the top address bit) and forwards the full address. One write and one read can be in flight; AW and W may arrive in any order. Used by spatial_upscaler to put two IPs behind one control port. The testbench puts a register file behind each port and checks every access, with protocol checkers on the master link and both slave links.

Sources: `src/axil_split.sv`

[HTML module page](../scalers/axil_split/docs/index.html)

## banked_framebuf

**banked_framebuf** · category `scalers` · top `banked_framebuf`

Frame store split over B×B RAM banks (B = next power of 2 ≥ TAPS) that returns any clamped TAPS×TAPS window every clock, with 2-cycle stall-able latency. NBUF=2 holds two independent frames (wr_buf/rd_buf) for ping-pong operation. RING>0 turns it into a line buffer of RING rows (row *y* in slot *y* mod RING; RING a power of two ≥ B, so a row's bank never changes); coordinates stay logical and are still clamped to the image.

Sources: `src/banked_framebuf.sv`

[HTML module page](../scalers/banked_framebuf/docs/index.html)

## scaler_anisotropic

**scaler_anisotropic** · category `scalers` · top `scaler_anisotropic`

Anisotropic scaler: scaler_mip with up to 16 probes per pixel.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/../../scaler_mip/src/scaler_mip.sv`, `src/scaler_anisotropic.sv`

[HTML module page](../scalers/scaler_anisotropic/docs/index.html)

## scaler_bicubic

**scaler_bicubic** · category `scalers` · top `scaler_bicubic`

Bicubic (4×4) scaler: scaler_polyphase with TAPS=4. Program any Mitchell-Netravali (B,C) kernel.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/../../scaler_polyphase/src/scaler_polyphase.sv`, `src/scaler_bicubic.sv`

[HTML module page](../scalers/scaler_bicubic/docs/index.html)

## scaler_bilinear

**scaler_bilinear** · category `scalers` · top `scaler_bilinear`

Bilinear scaler, 8-bit phase, weights computed in hardware.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/scaler_bilinear.sv`

[HTML module page](../scalers/scaler_bilinear/docs/index.html)

## scaler_ctrl

**scaler_ctrl** · category `scalers` · top `scaler_ctrl`

Common scaler control: register map 0x000–0x02F, forwarding of 0x040+ to the IP, AXI4-Stream frame capture with SOF/EOL error detection, and frame sequencing in three modes: single frame buffer (NBUF=1), ping-pong (NBUF=2: capture into one buffer while the generator reads the other), and line buffer (LB_ROWS>0: generation starts at SOF, with row-level flow control that holds the output scan until its source rows have arrived and holds the input until the oldest row still in use has been read).

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/scaler_ctrl.sv`

[HTML module page](../scalers/scaler_ctrl/docs/index.html)

## scaler_dda

**scaler_dda** · category `scalers` · top `scaler_dda`

Raster scan of the output image producing 16.16 source coordinates OFFS + o·STEP by exact accumulation, with SOF/EOL/EOF flags and pipeline stall.

Sources: `src/scaler_dda.sv`

[HTML module page](../scalers/scaler_dda/docs/index.html)

## scaler_edge_directed

**scaler_edge_directed** · category `scalers` · top `scaler_edge_directed`

Edge-directed (data-dependent triangulation) scaler. Registers: 0x040 THRESH, 0x044 EDGE_CTRL.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/scaler_edge_directed.sv`

[HTML module page](../scalers/scaler_edge_directed/docs/index.html)

## scaler_lanczos

**scaler_lanczos** · category `scalers` · top `scaler_lanczos`

Lanczos-3 (6×6) scaler: scaler_polyphase with TAPS=6.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/../../scaler_polyphase/src/scaler_polyphase.sv`, `src/scaler_lanczos.sv`

[HTML module page](../scalers/scaler_lanczos/docs/index.html)

## scaler_mip

**scaler_mip** · category `scalers` · top `scaler_mip`

Mip-map scaler engine: hardware 2×2 box pyramid, trilinear sampling, optional anisotropic multi-probe averaging.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/scaler_mip.sv`

[HTML module page](../scalers/scaler_mip/docs/index.html)

## scaler_nearest

**scaler_nearest** · category `scalers` · top `scaler_nearest`

Nearest-neighbour scaler.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/scaler_nearest.sv`

[HTML module page](../scalers/scaler_nearest/docs/index.html)

## scaler_polyphase

**scaler_polyphase** · category `scalers` · top `scaler_polyphase`

Generic separable polyphase scaler, even TAPS 2–16, programmable H/V coefficient tables at 0x1000 / 0x2000.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/scaler_polyphase.sv`

[HTML module page](../scalers/scaler_polyphase/docs/index.html)

## scaler_trilinear

**scaler_trilinear** · category `scalers` · top `scaler_trilinear`

Trilinear scaler: scaler_mip with ANISO_MAX_LOG2=0.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/../../scaler_mip/src/scaler_mip.sv`, `src/scaler_trilinear.sv`

[HTML module page](../scalers/scaler_trilinear/docs/index.html)

## sharpen_cas

**sharpen_cas** · category `scalers` · top `sharpen_cas`

Contrast-adaptive sharpening (CAS) filter after AMD FidelityFX CAS: a 3×3 same-size filter that sharpens low-contrast detail strongly and edges or near-clipping areas gently, so it adds little ringing or halo. Streaming line-buffer design: about two lines of latency, 1 pixel per clock, no frame buffer. Registers: CTRL (ENABLE, BYPASS), STATUS, SIZE, FRAME_CNT, IP_ID "SHRP", SHARPNESS (0–256). The full arithmetic is in the header of src/sharpen_cas.sv and in docs/coefficient_derivation.md §8.

Sources: `src/../../axil_regbus/src/axil_regbus.sv`, `src/sharpen_cas.sv`

[HTML module page](../scalers/sharpen_cas/docs/index.html)

## spatial_upscaler

**spatial_upscaler** · category `scalers` · top `spatial_upscaler`

FSR 1-style spatial upscaler: scaler_lanczos resampling followed by sharpen_cas, behind a single AXI4-Lite port (axil_split). Scaler registers are at 0x0000–0x3FFF, sharpener registers at 0x4000–0x40FF. The sharpener SIZE must be programmed to the scaler OUT_SIZE. The testbench models both stages exactly: the Lanczos output image first, then CAS applied to it.

Sources: `src/../../axil_split/src/axil_split.sv`, `src/../../axil_regbus/src/axil_regbus.sv`, `src/../../scaler_ctrl/src/scaler_ctrl.sv`, `src/../../scaler_dda/src/scaler_dda.sv`, `src/../../banked_framebuf/src/banked_framebuf.sv`, `src/../../scaler_polyphase/src/scaler_polyphase.sv`, `src/../../scaler_lanczos/src/scaler_lanczos.sv`, `src/../../sharpen_cas/src/sharpen_cas.sv`, `src/spatial_upscaler.sv`

[HTML module page](../scalers/spatial_upscaler/docs/index.html)

## mac

**Mac** · category `math` · top `mac`

One-cycle-latency multiply-accumulate unit. Fixed-point mode supports independent operand widths/signs and Q-format binary points, optional round-to-nearest-even, output saturation, and overflow/inexact flags. Floating-point mode is IEEE-754 binary32 fused multiply-add with round-to-nearest-even and overflow/underflow/inexact/invalid flags. Clock - clk. Reset - synchronous active-low rst_n. Latency - one clock from valid_i to valid_o. Throughput - one result per clock. Errors - bad widths/fraction positions or non-binary32 floating-point widths rejected at elaboration.

Sources: `src/mac.sv`, `src/fp32_fma.sv`

[HTML module page](../math/mac/docs/index.html)
