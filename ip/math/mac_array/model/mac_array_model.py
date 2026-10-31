"""mac_array model (Python model of ip/math/mac_array/src/mac_array.sv): a ROWS x COLS array of INT8 x INT8 -> INT32
MAC units. The array computes a matrix-vector product per clock: output[c] = sum_r (a[r] * w[c][r]) + acc[c].
Latency: 1 clock (the MAC unit's latency). Throughput: one output vector per clock when valid_i=1.
The array is parameterized for verification with small sizes (e.g., 8x8) that give bit-identical results
to the full 64x64 array; the NPU's arithmetic is independent of the array size.
"""
import numpy as np


class MacArray:
    """ROWS x COLS INT8 x INT8 -> INT32 MAC array model."""

    def __init__(self, rows=64, cols=64):
        self.rows = rows
        self.cols = cols
        self.weights = np.zeros((cols, rows), dtype=np.int8)  # weight matrix: COLS x ROWS
        self.acc = np.zeros(cols, dtype=np.int32)
        self.valid_q = False
        self.result_q = np.zeros(cols, dtype=np.int32)

    def load_weights(self, weights):
        """Load weight matrix (COLS x ROWS int8)."""
        assert weights.shape == (self.cols, self.rows), f"weights shape {weights.shape} != ({self.cols}, {self.rows})"
        self.weights = weights.astype(np.int8)

    def load_acc(self, acc):
        """Load accumulator vector (COLS int32)."""
        assert acc.shape == (self.cols,), f"acc shape {acc.shape} != ({self.cols},)"
        self.acc = acc.astype(np.int32)

    def cycle(self, valid_i, a_vec, w_row=None, acc_vec=None):
        """One clock cycle. If w_row is not None, load a weight row (for streaming weights).
        If acc_vec is not None, load accumulator vector.
        Returns (valid_o, result_vec)."""
        if acc_vec is not None:
            self.load_acc(acc_vec)
        if w_row is not None:
            # Streaming weight load: one row per clock (for large arrays)
            pass  # Not modeled here; weights are pre-loaded
        
        if valid_i:
            # a_vec: ROWS int8
            assert len(a_vec) == self.rows, f"a_vec length {len(a_vec)} != {self.rows}"
            a = np.array(a_vec, dtype=np.int8)
            # result[c] = sum_r (a[r] * weights[c][r]) + acc[c]
            result = (self.weights.astype(np.int32) @ a.astype(np.int32)) + self.acc
            self.result_q = result.astype(np.int32)
            self.valid_q = True
        else:
            self.valid_q = False
            self.result_q = np.zeros(self.cols, dtype=np.int32)
        
        return int(self.valid_q), self.result_q.copy()

    def reset(self):
        self.valid_q = False
        self.result_q = np.zeros(self.cols, dtype=np.int32)
        self.acc = np.zeros(self.cols, dtype=np.int32)
