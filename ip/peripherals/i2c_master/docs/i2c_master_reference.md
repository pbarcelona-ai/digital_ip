<!-- Industry reference check of i2c_master: copied into docs/i2c_master_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - i2c_master (2026-10-16, updated 2026-10-20)
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
// RESOLVED(REF-I2C_MASTER-1) [MEDIUM] Fast-mode tLOW violation. Resolution: 2026-10-20: DIV's reset
//   value (i2c_master_regs.json DIV_RST, computed in i2c_top) is the larger of CLK_HZ / (4 SCL_HZ) and
//   the phase that makes SCL low (2 phases) last the UM10204 Table 10 tLOW minimum of the bus mode
//   (4.7 us up to 100 kHz, 1.3 us up to 400 kHz, 0.5 us above), so the default meets tLOW and tHIGH
//   (e.g. 384.6 kHz for 400 kHz at 200 MHz); the i2c_master.sv header states the formula and the rule
//   for software writing DIV; tb/python test_scl_timing measures every SCL low / high time and the
//   period at the reset DIV (100 kHz: tLOW 5.02 us, tHIGH 5.02 us; 400 kHz: 1.31 / 1.31 us, 381.7 kHz).
```
