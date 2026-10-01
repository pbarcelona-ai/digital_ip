# Digital IP — synthesizable SystemVerilog IP cores

Open-source (MIT), parameterized SystemVerilog IP cores for FPGA and ASIC by [FPGA Cores 4U](https://pbarcelona-ai.github.io/): AXI4-Lite and AXI4-Stream interconnect, clock-domain crossing, FIFOs, DSP, CRC/ECC, memories, peripherals (UART, I2C, SPI, SDIO, Ethernet, USB, PCIe), timers and video scalers.

Every core has a self-checking testbench (Icarus Verilog) and goes through the same Yosys `synth_xilinx` flow with utilization reports.

**Documentation and catalog:** https://pbarcelona-ai.github.io/ip/

- [`ip/`](ip/) — the IP library (see [ip/README.md](ip/README.md) for layout, build and test commands)
- [`image_processing/vision_system/`](image_processing/vision_system/) — streaming lens-distortion-correction system ([hardware overview](https://pbarcelona-ai.github.io/digital_ip/image_processing/vision_system/docs/site/index.html))

## Cores

**AXI & bus interconnect IP:** [AXI4-Lite Decoder](https://pbarcelona-ai.github.io/ip/axi4-lite-decoder/), [AXI4-Lite Mux](https://pbarcelona-ai.github.io/ip/axi4-lite-mux/), [AXI4-Lite Registers](https://pbarcelona-ai.github.io/ip/axi4-lite-regs/), [AXI4-Lite Slave](https://pbarcelona-ai.github.io/ip/axi4-lite-slave/), [AXI-Stream Arbiter](https://pbarcelona-ai.github.io/ip/axi-stream-arbiter/), [AXI-Stream FIFO](https://pbarcelona-ai.github.io/ip/axi-stream-fifo/), [AXI-Stream Width Converter](https://pbarcelona-ai.github.io/ip/axi-stream-width-converter/), [AXI-Stream DMA](https://pbarcelona-ai.github.io/ip/axis-dma/), [Demo Registers](https://pbarcelona-ai.github.io/ip/demo-regs/), [DMA Engine](https://pbarcelona-ai.github.io/ip/dma-engine/), [Packet Formatter](https://pbarcelona-ai.github.io/ip/packet-formatter/), [Packet Parser](https://pbarcelona-ai.github.io/ip/packet-parser/)

**Clock-domain crossing (CDC) IP:** [AXI4-Lite CDC](https://pbarcelona-ai.github.io/ip/axi4-lite-cdc/), [AXI-Stream Async Bridge](https://pbarcelona-ai.github.io/ip/axis-async-bridge/), [Bit Sync](https://pbarcelona-ai.github.io/ip/bit-sync/), [Clock Domain Bridge](https://pbarcelona-ai.github.io/ip/clock-domain-bridge/), [Pulse Sync](https://pbarcelona-ai.github.io/ip/pulse-sync/), [Reset Controller](https://pbarcelona-ai.github.io/ip/reset-ctrl/), [Reset Sync](https://pbarcelona-ai.github.io/ip/reset-sync/), [Toggle Sync](https://pbarcelona-ai.github.io/ip/toggle-sync/)

**DSP building blocks:** [CIC](https://pbarcelona-ai.github.io/ip/cic/), [CORDIC](https://pbarcelona-ai.github.io/ip/cordic/), [DDS](https://pbarcelona-ai.github.io/ip/dds/), [Edge Detect](https://pbarcelona-ai.github.io/ip/edge-detect/), [FIR](https://pbarcelona-ai.github.io/ip/fir/), [One-Hot Decoder](https://pbarcelona-ai.github.io/ip/onehot-decoder/), [Priority Encoder](https://pbarcelona-ai.github.io/ip/priority-encoder/)

**FIFOs:** [Async FIFO](https://pbarcelona-ai.github.io/ip/async-fifo/), [Fallthrough FIFO](https://pbarcelona-ai.github.io/ip/fallthrough-fifo/), [Packet FIFO](https://pbarcelona-ai.github.io/ip/packet-fifo/), [Sync FIFO](https://pbarcelona-ai.github.io/ip/sync-fifo/)

**CRC, ECC & data integrity IP:** [Checksum](https://pbarcelona-ai.github.io/ip/checksum/), [CRC-16](https://pbarcelona-ai.github.io/ip/crc16/), [CRC-32](https://pbarcelona-ai.github.io/ip/crc32/), [CRC-8](https://pbarcelona-ai.github.io/ip/crc8/), [ECC Memory Controller](https://pbarcelona-ai.github.io/ip/ecc-memory-ctrl/), [Error Status](https://pbarcelona-ai.github.io/ip/error-status/), [LFSR](https://pbarcelona-ai.github.io/ip/lfsr/), [Parity Check](https://pbarcelona-ai.github.io/ip/parity-check/), [Parity Gen](https://pbarcelona-ai.github.io/ip/parity-gen/)

**Arithmetic IP:** [MAC](https://pbarcelona-ai.github.io/ip/mac/)

**Memory IP:** [Memory Arbiter](https://pbarcelona-ai.github.io/ip/memory-arbiter/), [Register File](https://pbarcelona-ai.github.io/ip/register-file/), [ROM](https://pbarcelona-ai.github.io/ip/rom/), [Simple Dual-Port RAM](https://pbarcelona-ai.github.io/ip/simple-dual-port-ram/), [Single-Port RAM](https://pbarcelona-ai.github.io/ip/single-port-ram/), [True Dual-Port RAM](https://pbarcelona-ai.github.io/ip/true-dual-port-ram/)

**Peripheral interface IP:** [Edge Event Capture](https://pbarcelona-ai.github.io/ip/edge-event-capture/), [Ethernet MAC Interface](https://pbarcelona-ai.github.io/ip/eth-mac-if/), [GPIO](https://pbarcelona-ai.github.io/ip/gpio/), [I2C Master](https://pbarcelona-ai.github.io/ip/i2c-master/), [I2S](https://pbarcelona-ai.github.io/ip/i2s/), [Interrupt Controller](https://pbarcelona-ai.github.io/ip/intc/), [PCIe Transaction-Layer Endpoint](https://pbarcelona-ai.github.io/ip/pcie-tl-ep/), [Quadrature Decoder](https://pbarcelona-ai.github.io/ip/quadrature-decoder/), [SDIO Host](https://pbarcelona-ai.github.io/ip/sdio-host/), [SPI Flash Controller](https://pbarcelona-ai.github.io/ip/spi-flash-ctrl/), [SPI Master](https://pbarcelona-ai.github.io/ip/spi-master/), [SPI Slave](https://pbarcelona-ai.github.io/ip/spi-slave/), [UART](https://pbarcelona-ai.github.io/ip/uart/), [UART RX](https://pbarcelona-ai.github.io/ip/uart-rx/), [UART TX](https://pbarcelona-ai.github.io/ip/uart-tx/), [USB Full-Speed SIE](https://pbarcelona-ai.github.io/ip/usb-fs-sie/)

**Video scaler & image pipeline IP:** [AXI Checkers](https://pbarcelona-ai.github.io/ip/axi-checkers/), [AXI4-Lite Register Bus](https://pbarcelona-ai.github.io/ip/axil-regbus/), [AXI4-Lite Split](https://pbarcelona-ai.github.io/ip/axil-split/), [Banked Frame Buffer](https://pbarcelona-ai.github.io/ip/banked-framebuf/), [Anisotropic Scaler](https://pbarcelona-ai.github.io/ip/scaler-anisotropic/), [Bicubic Scaler](https://pbarcelona-ai.github.io/ip/scaler-bicubic/), [Bilinear Scaler](https://pbarcelona-ai.github.io/ip/scaler-bilinear/), [Scaler Controller](https://pbarcelona-ai.github.io/ip/scaler-ctrl/), [DDA Scaler](https://pbarcelona-ai.github.io/ip/scaler-dda/), [Edge-Directed Scaler](https://pbarcelona-ai.github.io/ip/scaler-edge-directed/), [Lanczos Scaler](https://pbarcelona-ai.github.io/ip/scaler-lanczos/), [MIP Scaler](https://pbarcelona-ai.github.io/ip/scaler-mip/), [Nearest Scaler](https://pbarcelona-ai.github.io/ip/scaler-nearest/), [Polyphase Scaler](https://pbarcelona-ai.github.io/ip/scaler-polyphase/), [Trilinear Scaler](https://pbarcelona-ai.github.io/ip/scaler-trilinear/), [Sharpen CAS](https://pbarcelona-ai.github.io/ip/sharpen-cas/), [Spatial Upscaler](https://pbarcelona-ai.github.io/ip/spatial-upscaler/)

**Timers, counters & clock generation:** [Baud Generator](https://pbarcelona-ai.github.io/ip/baud-generator/), [Baud NCO](https://pbarcelona-ai.github.io/ip/baud-nco/), [Clock Enable](https://pbarcelona-ai.github.io/ip/clock-enable/), [Counter](https://pbarcelona-ai.github.io/ip/counter/), [Frequency Counter](https://pbarcelona-ai.github.io/ip/frequency-counter/), [Interval Timer](https://pbarcelona-ai.github.io/ip/interval-timer/), [NCO](https://pbarcelona-ai.github.io/ip/nco/), [Pulse Generator](https://pbarcelona-ai.github.io/ip/pulse-generator/), [PWM](https://pbarcelona-ai.github.io/ip/pwm/), [Rate Limiter](https://pbarcelona-ai.github.io/ip/rate-limiter/), [Timeout Timer](https://pbarcelona-ai.github.io/ip/timeout-timer/), [Timestamp Counter](https://pbarcelona-ai.github.io/ip/timestamp-counter/), [Watchdog](https://pbarcelona-ai.github.io/ip/watchdog/)

## Design notes

- [Async FIFO and Gray-code clock-domain crossing](https://pbarcelona-ai.github.io/design-notes/async-fifo-gray-code-cdc.html)
- [AXI-Stream width converter](https://pbarcelona-ai.github.io/design-notes/axi-stream-width-converter.html)
- [Lens distortion correction: pipeline design decisions](https://pbarcelona-ai.github.io/design-notes/lens-distortion-correction.html)
- [FPGA image scalers compared: nearest, bilinear, bicubic and Lanczos](https://pbarcelona-ai.github.io/design-notes/fpga-image-scaler-comparison.html)
- [CRC-32 in SystemVerilog: parameters, reflection and parallel bytes](https://pbarcelona-ai.github.io/design-notes/crc-32-systemverilog.html)
- [Reset synchronizers: asynchronous assert, synchronous release](https://pbarcelona-ai.github.io/design-notes/reset-synchronizer.html)
- [UART fractional baud generator](https://pbarcelona-ai.github.io/design-notes/uart-fractional-baud-generator.html)

## License

MIT — see [LICENSE](LICENSE). Contact fpga.cores4u@gmail.com for custom IP and support.
