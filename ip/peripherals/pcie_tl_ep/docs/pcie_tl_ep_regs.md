# pcie_tl_ep register map

PCIe transaction-layer endpoint: DMA control, address and length, link status, completer ID, BAR0, TLP counters.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "PCIE" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000000 | [0] DMA enabled |
| 0x14 | DMA_ADDR_LO | RW | 0x00000000 | DMA host address [31:0] (a write reloads the address) |
| 0x18 | DMA_ADDR_HI | RW | 0x00000000 | DMA host address [63:32] (a write reloads the address) |
| 0x1C | DMA_LEN_DW | RW | 0x00000008 | DMA payload per TLP, DWs |
| 0x20 | STATUS | RO | 0x00000000 | status |
| 0x24 | CPL_ID | RO | 0x00000000 | completer ID (bus / device / function) |
| 0x28 | BAR0 | RO | 0x00000000 | BAR0 as programmed by the host |
| 0x2C | RX_TLP | RO | 0x00000000 | TLPs received |
| 0x30 | MWR | RO | 0x00000000 | memory writes received |
| 0x34 | MRD | RO | 0x00000000 | memory reads received |
| 0x38 | CFG | RO | 0x00000000 | configuration requests received |
| 0x3C | UR | RO | 0x00000000 | unsupported requests |
| 0x40 | DMA_TLP | RO | 0x00000000 | DMA TLPs sent |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | MEM_EN | memory space enabled by the host |
| 1 | BUS_MASTER | bus mastering enabled by the host |
| 2 | DMA_BUSY | DMA engine busy |
| 31:16 | SF_LEVEL | words in the DMA source FIFO |
