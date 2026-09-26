# Shared argument handling for run_iverilog.sh / run_sim.sh (sourced, bash).
# Input : ROOT, IP, and the plusargs "$@" given after the directory name.
# Output: PLUSARGS (array) with absolute paths, TB_MAX_W / TB_MAX_H.
#   +IMG=<file.ppm>  : made absolute; its header sets TB_MAX_W/TB_MAX_H so the
#                      testbench is compiled large enough (min 48 x 40)
#   +OUTDIR=<dir>    : made absolute and created; default $ROOT/ppm_out/<IP>
#   anything else    : passed through unchanged (+OUT_W=, +OUT_H=, +NO_PPM, ...)
PLUSARGS=()
VDEFS=()        # -D<NAME>[=<v>] compile defines, as +define+ for Verilator
TB_MAX_W=${TB_MAX_W:-48}
TB_MAX_H=${TB_MAX_H:-40}
OUTDIR_SET=0
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
for a in "$@"; do
  case "$a" in
    +IMG=*)
      f="$(abspath "${a#+IMG=}")"
      [ -r "$f" ] || { echo "cannot read $f"; exit 1; }
      # header: magic width height maxval, '#' comments allowed
      read -r magic w h _ < <(LC_ALL=C head -c 512 "$f" | LC_ALL=C tr -c '[:print:]\n' ' ' \
                              | sed 's/#.*//' | tr -s ' \t\r\n' '\n' | head -4 | tr '\n' ' '; echo) || true
      [ "$magic" = "P6" ] || { echo "$f is not a P6 PPM"; exit 1; }
      [ "$w" -gt "$TB_MAX_W" ] && TB_MAX_W=$w
      [ "$h" -gt "$TB_MAX_H" ] && TB_MAX_H=$h
      PLUSARGS+=("+IMG=$f") ;;
    +OUTDIR=*)
      d="$(abspath "${a#+OUTDIR=}")"; mkdir -p "$d"; OUTDIR_SET=1
      PLUSARGS+=("+OUTDIR=$d") ;;
    -D*) VDEFS+=("+define+${a#-D}") ;;
    *) PLUSARGS+=("$a") ;;
  esac
done
if [ $OUTDIR_SET -eq 0 ]; then
  case "$IP" in
    scaler_ctrl|scaler_dda) ;;                       # no image output
    scaler_*|sharpen_*|spatial_*) mkdir -p "$ROOT/ppm_out/$IP"; PLUSARGS+=("+OUTDIR=$ROOT/ppm_out/$IP") ;;
  esac
fi
