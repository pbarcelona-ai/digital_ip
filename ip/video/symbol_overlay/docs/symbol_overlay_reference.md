<!-- Industry reference check of symbol_overlay: copied into docs/symbol_overlay_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - symbol_overlay (2026-10-16)
// Sources:
//   [1] T. Porter, T. Duff, "Compositing Digital Images", SIGGRAPH 1984,
//   https://graphics.pixar.com/library/Compositing (over: c = a cA + (1 - a) cB)
// Published algorithm / equations:
//   Compositing: over operator c = a * c_fg + (1 - a) * c_bg (Porter & Duff 1984); 50 % blend =
//   (fg + bg) / 2. Shapes by implicit tests (circle dx^2 + dy^2 <= R^2, ellipse dx^2 B^2 + dy^2
//   A^2 <= A^2 B^2).
// Comparison with this IP (section 6):
//   Matches: opaque or a = 0.5 over, implicit circle / ellipse tests, z-order (object 0 on
//   top), frame-synchronous commit.
// Result: in line with the reference; no TODO.
```
