<!-- Industry reference check of i2c_master: copied into docs/i2c_master_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - i2c_master (2026-10-16)
// Sources:
//   [1] NXP, "I2C-bus specification and user manual", UM10204 Rev. 7.0 (2021),
//   https://www.nxp.com/docs/en/user-guide/UM10204.pdf - 3.1 (START / STOP, ACK, arbitration,
//   clock stretching), Table 10 (tLOW / tHIGH)
//   [2] Linux, "i2c: uniphier-f: fix violation of tLOW requirement for Fast-mode" (2018),
//   https://lkml.iu.edu/hypermail/linux/kernel/1812.2/03952.html - a 50 % duty SCL violates
//   tLOW at 400 kHz
// Published algorithm / equations:
//   UM10204: START (SDA falls while SCL high), STOP (SDA rises while SCL high), data changes
//   while SCL low, 9th-clock ACK, clock stretching (master waits for SCL to rise), arbitration
//   (master loses when it releases SDA but reads it low). Table 10 timing: Standard-mode (100
//   kHz) tLOW >= 4.7 us, tHIGH >= 4.0 us; Fast-mode (400 kHz) tLOW >= 1.3 us, tHIGH >= 0.6 us;
//   Fast-mode Plus (1 MHz) tLOW >= 0.5 us, tHIGH >= 0.26 us.
// Comparison with this IP (section 6):
//   Matches: START / repeated START / STOP, ACK / NACK, clock stretching, arbitration loss,
//   open-drain pins. Differs: SCL is 50 % duty (four equal phases, f_scl = f_clk / (4 (DIV +
//   1))), so at 400 kHz tLOW = 1.25 us < 1.3 us (UM10204 Fast-mode minimum; the same bug was
//   fixed in Linux i2c-uniphier-f). video_processor runs I2C0 at 400 kHz, so this matters.
// TODO(REF-I2C_MASTER-1) [MEDIUM] Fast-mode tLOW violation. Prompt: in
//   ip/peripherals/i2c_master/src/i2c_bit_ctrl.sv, make the SCL low time longer than the high
//   time: split each bit into the low phases and high phases with a programmable ratio (e.g.
//   low = 3 phases, high = 2 phases of a 5-phase bit, f_scl = f_clk / (5 (DIV + 1))), or add a
//   LOW_EXTRA register; update DIV_RST in i2c_top.sv so the default meets UM10204 Table 10 for
//   SCL_HZ (100 kHz: tLOW >= 4.7 us, tHIGH >= 4.0 us; 400 kHz: tLOW >= 1.3 us, tHIGH >= 0.6
//   us), update the i2c_master.sv header formula, and add a testbench check that measures tLOW
//   / tHIGH at 100 kHz and 400 kHz against those limits.
```
