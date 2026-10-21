"""Register map model shared by every IP model (ip/shared/pymodel), built from an IP's
src/include/<name>_regs.json (the same source regmap_gen.py generates the RTL register block from).

Behaviour of the generated block (axi4_lite_slave front end + <name>_regs.sv):
  ID / VERSION / DATE at 0x00 / 0x04 / 0x08 (read only), 0x0C reserved (reads 0);
  RW   register value, written with the byte strobes (always all 4 from py_core), cfg_<reg>_wr pulse;
  RO   value from the logic (sts_<reg>), a write answers SLVERR;
  W1C  status the logic sets (a set wins over a clear in the same clock), software writes 1 to clear;
  W1S  software writes 1 to set, the logic clears;
  WO   reads 0, a write gives the data and a pulse;
  CMD  reads the logic's value, a write gives the data and a pulse;
  RC   reads the logic's value, the read gives a pulse;
  arrays: count registers at offset + stride * i; unmapped words in the map read 0, writes ignored;
  at and above the map's end (regmap_gen's MAP_WORDS: the last register word reserved) DECERR.
The model keeps the register values; the IP model supplies `sts(name, i)` for logic values and is
told about writes / reads through `on_write(name, i, data)` / `on_read(name, i)`.
"""
import ast
import json
import os
import re


def _eval(expr, params):
    """Value of a JSON width / count / reset expression with the given parameter values."""
    if isinstance(expr, int):
        return expr
    e = str(expr).strip()
    m = None if "+:" in e else re.fullmatch(r"(\w+)\[(.+):(.+)\]", e)   # PARAM[hi:lo] slice
    if m:
        v = _eval(m.group(1), params)
        hi, lo = _eval(m.group(2), params), _eval(m.group(3), params)
        return (v >> lo) & ((1 << (hi - lo + 1)) - 1)
    e = re.sub(r"(\d+)'[hH]([0-9a-fA-F_]+)", lambda mm: str(int(mm.group(2).replace("_", ""), 16)), e)
    e = re.sub(r"(\d+)'[dD](\d+)", r"\2", e)
    e = re.sub(r"'([01])\b", r"\1", e)                          # '0 / '1 (fill: only '0 is used)
    e = re.sub(r"\b\w+::(\w+)", r"\1", e)                      # pkg::name -> name
    e = e.replace("$clog2", "clog2")
    e = re.sub(r"(\w+)\[([^\[\]]+?)\s*\+:\s*([^\[\]]+)\]", r"psel(\1, \2, \3)", e)   # X[a +: w]
    e = re.sub(r"\{([^{}]+)\}", r"concat(\1)", e)                 # {A, B}
    while "?" in e:                                                # (c ? a : b) -> (a if c else b)
        e2 = re.sub(r"\(([^()?:]+)\?([^()?:]+):([^()?:]+)\)", r"((\2) if (\1) else (\3))", e)
        if e2 == e:
            raise ValueError(f"register map: cannot evaluate {expr!r}")
        e = e2
    return _arith(ast.parse(e, mode="eval").body, params)


# SystemVerilog package functions used by register maps (conv2d_pkg)
FUNCS = {"blur_shift": lambda n: 2 * (n - 1)}
WIDTHS = {}                                                     # parameter widths for {A, B} (from "type")


_OPS = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
        ast.Div: lambda a, b: a // b, ast.FloorDiv: lambda a, b: a // b, ast.Mod: lambda a, b: a % b,
        ast.LShift: lambda a, b: a << b, ast.RShift: lambda a, b: a >> b, ast.BitOr: lambda a, b: a | b,
        ast.BitAnd: lambda a, b: a & b, ast.BitXor: lambda a, b: a ^ b, ast.Pow: lambda a, b: a ** b}


def _arith(n, params):
    """Integer arithmetic of constants, parameters, + - * / % << >> | & ^ ** and clog2() only (no eval)."""
    if isinstance(n, ast.Constant) and isinstance(n.value, int):
        return n.value
    if isinstance(n, ast.Name) and n.id in params:
        return int(params[n.id])
    if isinstance(n, ast.BinOp) and type(n.op) in _OPS:
        return _OPS[type(n.op)](_arith(n.left, params), _arith(n.right, params))
    if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub):
        return -_arith(n.operand, params)
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
        args = [_arith(a, params) for a in n.args]
        if n.func.id == "clog2" and len(args) == 1:
            return max(0, (args[0] - 1).bit_length())
        if n.func.id == "psel" and len(args) == 3:
            return (args[0] >> args[1]) & ((1 << args[2]) - 1)
        if n.func.id == "concat":
            v = 0
            for a, src in zip(args, n.args):
                w = WIDTHS.get(src.id, 32) if isinstance(src, ast.Name) else 32
                v = (v << w) | (a & ((1 << w) - 1))
            return v
        if n.func.id in FUNCS:
            return FUNCS[n.func.id](*args)
    if isinstance(n, ast.IfExp):
        return _arith(n.body, params) if _arith(n.test, params) else _arith(n.orelse, params)
    if isinstance(n, ast.Compare) and len(n.ops) == 1:
        a, b = _arith(n.left, params), _arith(n.comparators[0], params)
        return int({ast.Lt: a < b, ast.LtE: a <= b, ast.Gt: a > b, ast.GtE: a >= b, ast.Eq: a == b,
                    ast.NotEq: a != b}[type(n.ops[0])])
    raise ValueError(f"register map: cannot evaluate {ast.dump(n)}")


def _ip_stamps(sv_path):
    """(IP_VERSION as ASCII "d.dd" or None, IP_DATE or None) of a generated register block: the stamps
    stamp_version.py keeps current (localparam logic [31:0] IP_VERSION = "1.10"; IP_DATE = 32'h10122026)."""
    try:
        with open(sv_path, encoding="utf-8") as fh:
            t = fh.read()
    except OSError:
        return None, None
    v = re.search(r'IP_VERSION\s*=\s*"([^"]{4})"', t)
    d = re.search(r"IP_DATE\s*=\s*32'h([0-9A-Fa-f_]+)", t)
    return (v.group(1) if v else None), (int(d.group(1).replace("_", ""), 16) if d else None)


class RegMap:
    def __init__(self, json_path, params=None, version="1.00", date=None):
        """The map of json_path with the parameter values params. ID comes from the JSON, VERSION and DATE from
        the IP_VERSION / IP_DATE stamps of the generated register block next to it (<name>.sv), as the RTL
        reads them; without a block, the JSON's version (else version) and date (else 0x10162026)."""
        with open(json_path, encoding="utf-8") as fh:
            m = json.load(fh)
        self.name = m["name"]
        for p in m.get("params", []):
            tm = re.search(r"\[(\d+):0\]", str(p.get("type", "")))
            if tm:
                WIDTHS[p["name"]] = int(tm.group(1)) + 1
        self.params = {p["name"]: _eval(p["default"], {}) for p in m.get("params", [])}
        self.params.update(params or {})
        self.id = int.from_bytes(m["id"].encode("ascii"), "big")
        sv_v, sv_d = _ip_stamps(os.path.join(os.path.dirname(json_path), m["name"] + ".sv"))
        self.version = int.from_bytes((sv_v or m.get("version", version)).encode("ascii"), "big")
        self.date = date if date is not None else (sv_d if sv_d is not None else 0x10162026)
        self.regs = {}                                  # offset -> (name, index, access, width)
        self.value = {}                                 # (name, index) -> stored value
        end = 0x10
        for r in m["registers"]:
            off = int(str(r["offset"]), 0)
            cnt = _eval(r.get("count", 1), self.params)
            width = _eval(r.get("width", 32), self.params)
            stride = int(r.get("stride", 4))
            reset = r.get("reset", 0)
            for i in range(cnt):
                a = off + stride * i
                self.regs[a] = (r["name"], i, r["access"], width)
                rv = _eval(reset, dict(self.params, i=i)) if reset not in (None, "") else 0
                self.value[(r["name"], i)] = rv & ((1 << width) - 1)
            # words reserved as regmap_gen.py counts them: max_count, else a literal count, else 1
            mc = int(r.get("max_count", r.get("count", 1) if isinstance(r.get("count", 1), int) else 1))
            end = max(end, off + stride * (mc - 1) + 4)
        self.size = end                                 # MAP_WORDS * 4: above it the slave answers DECERR
        self.sts = lambda name, i: 0                    # logic values (RO / CMD / RC), set by the IP model
        self.on_write = lambda name, i, data: None
        self.on_read = lambda name, i: None

    # -- logic side
    def get(self, name, i=0):
        return self.value[(name, i)]

    def set(self, name, value, i=0):
        self.value[(name, i)] = value

    def hw_set(self, name, bits, i=0):
        """W1C: the logic sets bits."""
        self.value[(name, i)] |= bits

    # -- bus side
    def read(self, off):
        """(data, resp): resp 0 OKAY, 2 SLVERR, 3 DECERR."""
        off &= ~3
        if off >= self.size:
            return 0, 3
        if off == 0:
            return self.id, 0
        if off == 4:
            return self.version, 0
        if off == 8:
            return self.date, 0
        if off not in self.regs:
            return 0, 0
        name, i, acc, width = self.regs[off]
        mask = (1 << width) - 1
        if acc in ("RW", "W1C", "W1S"):
            v = self.value[(name, i)]
        elif acc == "WO":
            v = 0
        else:                                            # RO / CMD / RC: the logic's value
            v = self.sts(name, i)
            if acc == "RC":
                self.on_read(name, i)
        return v & mask & 0xFFFFFFFF, 0

    def write(self, off, data):
        off &= ~3
        if off >= self.size:
            return 3
        if off < 0x10:
            return 2 if off < 0xC else 0
        if off not in self.regs:
            return 0
        name, i, acc, width = self.regs[off]
        mask = (1 << width) - 1
        d = data & mask
        if acc == "RO" or acc == "RC":
            return 2
        if acc == "RW":
            self.value[(name, i)] = d
        elif acc == "W1C":
            self.value[(name, i)] &= ~d
        elif acc == "W1S":
            self.value[(name, i)] |= d
        elif acc in ("WO", "CMD"):
            self.value[(name, i)] = d
        self.on_write(name, i, d)
        return 0


def ip_regs(model_file, name):
    """Path of <ip>/src/include/<name>_regs.json for a model at <ip>/model/<file> (each model reads the
    register JSON of its own IP)."""
    ip_dir = os.path.dirname(os.path.dirname(os.path.abspath(model_file)))
    return os.path.join(ip_dir, "src", "include", f"{name}_regs.json")
