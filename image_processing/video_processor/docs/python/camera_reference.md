<!-- Industry reference check of camera.py: copied into docs/python/camera_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - camera.py (2026-10-16)
// Sources:
//   [1] MIPI CSI-2 Camera Control Interface (CCI): I2C transfers with an 8- or 16-bit register
//   index sent big-endian after the device address, then the data bytes (Linux v4l2-cci
//   helpers, https://codebrowser.dev/linux/linux/include/media/v4l2-cci.h.html; MIPI CSI-2 v1.3
//   ch. 6)
//   [2] NXP, "I2C-bus specification and user manual", UM10204 Rev. 7.0 (2021),
//   https://www.nxp.com/docs/en/user-guide/UM10204.pdf - 3.1 (START / STOP, ACK, arbitration,
//   clock stretching), Table 10 (tLOW / tHIGH)
//   [3] ip/cpu/py_core/tools/pyc.py header (supported Python subset) and
//   ip/cpu/py_core/docs/py_core_prompt.md
// Published algorithm / rules:
//   CCI: register index after the device address, then data; a read is a write of the index
//   followed by a repeated-START (or STOP + START) read.
// Comparison with this program (section 6):
//   Matches: 8-bit register index (allowed by CCI), write of the index then a separate read
//   transfer (STOP + START: allowed), multi-byte values high byte first (CCI big-endian).
// Result: in line with the reference; no TODO.
```
