<!-- Industry reference check of tracker.py: copied into docs/python/tracker_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - tracker.py (2026-10-16)
// Sources:
//   [1] P. R. Kalata, "The Tracking Index: A Generalized Parameter for alpha-beta and alpha-
//   beta-gamma Target Trackers", IEEE Trans. AES 20(2):174-182, 1984; summary
//   https://en.wikipedia.org/wiki/Alpha_beta_filter (x_p = x + v T; r = z - x_p; x += alpha r;
//   v += beta r / T)
//   [2] Y. Bar-Shalom, T. E. Fortmann, "Tracking and Data Association", Academic Press 1988;
//   global vs greedy nearest-neighbour association with gating,
//   https://pytcl.readthedocs.io/en/latest/user_guide/data_association.html
// Published algorithm / rules:
//   alpha-beta tracker: predict x_p = x + v, residual r = z - x_p, x = x_p + alpha r, v = v +
//   beta r (0 < alpha, beta <= 1; smaller gains smooth noise, larger follow manoeuvres);
//   association of measurements to tracks by gated nearest neighbour (greedy per track, or
//   global assignment).
// Comparison with this program (section 6):
//   Matches the structure: constant-velocity prediction, gate (size + TRK_GATE), coast on
//   misses, track dropped after TRK_LOST misses. Differs: alpha = 1 (the position jumps to the
//   measurement, no smoothing) and v = (v + (z - x)) / 2, i.e. beta = 1/2 of the residual;
//   association is greedy per track in slot order, not a global assignment, so two close
//   targets can swap.
// RESOLVED(REF-TRACKER-1) [LOW] Filter gains and association. Resolution: 2026-10-16:
//   documented in track_step's docstring (alpha = 1, beta = 1/2, Kalata 1984; greedy gated
//   nearest neighbour as a stand-in for GNN, Bar-Shalom & Fortmann 1988); behaviour kept.
```
