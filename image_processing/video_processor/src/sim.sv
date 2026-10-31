// ***************
// Filename: sim.sv
// Author: FPGA Cores 4 U
// Description: Simulation-only module inclusions. Included in build.f for
//   both synthesis and simulation flows. When SIM is defined (simulation
//   flow), includes simulation models. When SYNTHESIS is defined
//   (synthesis flow), these are excluded.
// Date: 2026-10-24
// ***************

`ifdef SIM
  // DDR memory model for simulation (behavioral model of external SDRAM)
  // Not synthesizable - large memory array, timing checks, initial blocks
  `include "../../ip/memory/ddr_mem/src/ddr_mem.sv"
`endif

// Add other simulation-only modules here as needed
// `ifdef SIM
//   `include "../../ip/ai/npu/src/npu_model.sv"
// `endif

