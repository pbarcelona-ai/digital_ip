"""scaler_bilinear model (Python model of ip/scalers/scaler_bilinear/src/scaler_bilinear.sv), register window
only: the ID block (ID "BLIN", VERSION "1.10", DATE); the video_processor firmware bypasses the scaler
(video_pipeline BYPASS[7]), so its arithmetic is not modelled. Writes are accepted and ignored."""


class Scaler:
    """scaler_bilinear's register window (bypassed by the firmware: BYPASS[7]); reads its ID block."""

    def read(self, off):
        return {0: 0x424C494E, 4: 0x312E3130, 8: 0x10162026}.get(off & 0xFF, 0), 0

    def write(self, off, d):
        return 0
