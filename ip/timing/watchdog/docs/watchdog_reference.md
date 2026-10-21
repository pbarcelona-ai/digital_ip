<!-- Industry reference check of watchdog: copied into docs/watchdog_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - watchdog (2026-10-16, updated 2026-10-20)
// Sources:
//   [1] Arm, "ARM Watchdog Module (SP805) Technical Reference Manual", ARM DDI 0270B,
//   https://developer.arm.com/documentation/ddi0270/b - WdogLoad, interrupt on the first time-
//   out, reset on the second, WdogLock key 0x1ACCE551
// Published algorithm / equations:
//   Arm SP805: a down counter reloaded from WdogLoad; the first time-out raises the interrupt
//   and reloads, a second time-out with the interrupt still pending asserts the reset; writing
//   WdogIntClr (any value) restarts the count; all registers are write-protected until
//   0x1ACCE551 is written to WdogLock.
// Comparison with this IP (section 6):
//   Partly matches: pre-timeout interrupt before the reset, keyed restart, write protection.
//   Differs: separate PRETIMEOUT threshold instead of the two-time-out scheme; restart key
//   0x5AFEC0DE written to KICK instead of WdogIntClr; LOCK is one-way until reset (SP805 can
//   unlock with the key); optional window (early kick resets, as in windowed watchdogs) has no
//   SP805 counterpart.
// RESOLVED(REF-WATCHDOG-1) [LOW] Document the watchdog model. Resolution: 2026-10-20: the watchdog.sv
//   header states the windowed-watchdog model (pre-timeout interrupt at PRETIMEOUT ticks, reset at
//   TIMEOUT ticks, early-kick reset in window mode, one-way LOCK) and the differences from Arm SP805
//   (two consecutive time-outs, unlock key 0x1ACCE551); behaviour unchanged and compared clock for
//   clock with the golden model (tb/python).
```
