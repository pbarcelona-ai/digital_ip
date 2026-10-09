#!/usr/bin/env python3
# ***************
# Filename: pyc.py
# Author: FPGA Cores 4 U
# Description: Host-side front end for py_core (the role mpy-cross plays for
#   MicroPython). Compiles a Python subset into py_core bytecode and writes:
#     <out>.code.hex   one byte per line   ($readmemh into code memory)
#     <out>.const.hex  one 34-bit tagged word per line (constant pool)
#     <out>.lst        disassembly with source lines
#     <out>_syms.svh   localparams for globals (G_<name>) for testbenches
#     <out>.flash.bin  boot image for SPI NOR flash (py_boot format below),
#                      plus the string table at STR_BASE when strings are used
#     <out>.flash.hex  the same, one byte per line (@8000 before the table)
#     <out>.strings.txt  the string table: slot, handle, text
#
#   Flash image (little endian): "PYC1", u16 code length, u16 constant
#   count, u32 sum of all payload bytes, then the code bytes, then each
#   34-bit constant as 5 bytes. py_boot copies it into code/constant memory.
#
#   Supported subset:
#     ints, True/False/None, names, + - & | ^ << >> ~ unary -, not/and/or
#     in conditions, one comparison per expression (< <= > >= == !=),
#     mem32[addr] loads/stores (also mem32[a] op= v), name op= expr,
#     if/elif/else, while/break/continue, pass, global, import (ignored).
#     "from <name> import *" where <name>.py sits next to the source file
#     inlines that file there (once), so firmware can be split into modules
#     that share one global namespace; errors name the original file / line.
#     UPPER_CASE module-level names bound once to a constant expression
#     (or const(expr)) are folded at compile time.
#     def f(a, b): ... return x   functions with positional parameters,
#     called as f(x, y) in expressions or statements; recursion is allowed
#     up to the core's call depth. Missing return -> None.
#     A function passed to irq_handler() is an interrupt handler instead:
#     no parameters, no return value, cannot be called directly.
#   Builtins: irq_handler(fn), irq_enable(), irq_disable(), halt(value).
#   Strings: a string literal (in any expression, e.g. puts("text")) is a
#     small int handle; the text goes to a string table in flash at
#     STR_BASE (0x8000), outside the boot image, for the firmware to read at
#     run time through the flash controller. The table has 512 slots of 64
#     bytes (0x8000-0xFFFF): [0] length (0..62), [1] 1 if the string
#     continues in the next slot, [2..] the bytes. A handle is the first slot
#     number; slots 128..255 are emitted as h - 256 so they fit LOAD_SMALL,
#     slots 256..511 as h (a constant). Firmware decodes a handle with
#     slot = h if h >= 256 else h & 255.
#     strings("a", "b", ...) returns the handle of a block of consecutive
#     one-slot strings (each <= 62 bytes), so handle + i selects entry i (a
#     block never straddles slot 256, so the decoding holds for handle + i).
#     Identical strings share slots.
#   Not in the hardware fast path (rejected): * / % ** on variables,
#   default/keyword arguments, closures, lists, dicts, floats, classes.
#
# Usage: pyc.py prog.py -o build/prog
# Date: 2026-10-01
import argparse
import ast
import struct
import sys

OP = dict(NOP=0x00, LOAD_SMALL=0x01, LOAD_CONST=0x02, LOAD_FAST=0x03, STORE_FAST=0x04,
          POP_TOP=0x05, DUP_TOP=0x06, LOAD_NONE=0x07, LOAD_GLOBAL=0x08, STORE_GLOBAL=0x09,
          LOAD_TRUE=0x0A, LOAD_FALSE=0x0B,
          BINARY_ADD=0x10, BINARY_SUB=0x11, BINARY_AND=0x12, BINARY_OR=0x13, BINARY_XOR=0x14,
          BINARY_LSHIFT=0x15, BINARY_RSHIFT=0x16,
          COMPARE_LT=0x18, COMPARE_EQ=0x19, COMPARE_NE=0x1A, COMPARE_GT=0x1B, COMPARE_LE=0x1C,
          COMPARE_GE=0x1D,
          JUMP=0x20, POP_JUMP_IF_FALSE=0x21, POP_JUMP_IF_TRUE=0x22,
          MEM32_LOAD=0x30, MEM32_STORE=0x31,
          SET_IRQ_VECTOR=0x38, IRQ_ENABLE=0x39, IRQ_DISABLE=0x3A, RETURN_FROM_IRQ=0x3B,
          CALL=0x3C, RETURN=0x3D,
          RETURN_VALUE=0x3F)
NAME = {v: k for k, v in OP.items()}
ARGS = {OP[k]: 1 for k in ('LOAD_SMALL', 'LOAD_CONST', 'LOAD_FAST', 'STORE_FAST', 'LOAD_GLOBAL', 'STORE_GLOBAL')}
ARGS.update({OP[k]: 2 for k in ('JUMP', 'POP_JUMP_IF_FALSE', 'POP_JUMP_IF_TRUE', 'SET_IRQ_VECTOR', 'CALL')})

BINOP = {ast.Add: 'BINARY_ADD', ast.Sub: 'BINARY_SUB', ast.BitAnd: 'BINARY_AND', ast.BitOr: 'BINARY_OR',
         ast.BitXor: 'BINARY_XOR', ast.LShift: 'BINARY_LSHIFT', ast.RShift: 'BINARY_RSHIFT'}
CMPOP = {ast.Lt: 'COMPARE_LT', ast.Eq: 'COMPARE_EQ', ast.NotEq: 'COMPARE_NE', ast.Gt: 'COMPARE_GT',
         ast.LtE: 'COMPARE_LE', ast.GtE: 'COMPARE_GE'}
FOLD = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
        ast.FloorDiv: lambda a, b: a // b, ast.Mod: lambda a, b: a % b, ast.BitAnd: lambda a, b: a & b,
        ast.BitOr: lambda a, b: a | b, ast.BitXor: lambda a, b: a ^ b, ast.LShift: lambda a, b: a << b,
        ast.RShift: lambda a, b: a >> b, ast.Pow: lambda a, b: a ** b}

SMALL_MIN, SMALL_MAX = -(1 << 32), (1 << 32) - 1     # 33-bit signed small int
STR_BASE, STR_SLOTS, STR_SLOT_BYTES = 0x8000, 512, 64  # string table in flash (up to 0xFFFF)
STR_CHUNK = STR_SLOT_BYTES - 2
N_LOCALS, N_GLOBALS, N_CONSTS, CODE_SIZE = 16, 32, 256, 1 << 13


class CompileError(Exception):
    def __init__(self, node, msg):
        self.lineno, self.msg = getattr(node, 'lineno', None), msg
        super().__init__(f"line {self.lineno or '?'}: {msg}")


def handle(slot):
    """String handle of a slot: 0..127 as is, 128..255 as slot - 256 (LOAD_SMALL), 256.. as is."""
    return slot - 256 if 128 <= slot < 256 else slot


def inline_imports(path, seen=None):
    """Source of path with every "from <name> import *" of a sibling <name>.py replaced by that file
    (each file once), and (file, line) of every line of the result."""
    import os
    import re
    seen = set() if seen is None else seen
    seen.add(os.path.abspath(path))
    lines, where = [], []
    for k, line in enumerate(open(path).read().splitlines(), 1):
        m = re.match(r"\s*from\s+(\w+)\s+import\s+\*\s*(#.*)?$", line)
        sub = os.path.join(os.path.dirname(os.path.abspath(path)), m.group(1) + ".py") if m else None
        if sub and os.path.isfile(sub):
            if os.path.abspath(sub) not in seen:
                t, w = inline_imports(sub, seen)
                lines += t
                where += w
            continue
        lines.append(line)
        where.append((path, k))
    return lines, where


class Compiler:
    def __init__(self, src):
        self.src = src.splitlines()
        self.code = bytearray()
        self.lines = []            # (offset, lineno) for the listing
        self.labels, self.fixups = {}, []
        self.consts, self.globals_, self.symconst = [], {}, {}
        self.locals_, self.declared_global = None, set()
        self.loops = []            # (continue_label, break_label)
        self.funcs, self.handlers = {}, set()
        self.in_handler = False
        self.nlabel = 0
        self.str_slots = []        # (bytes, continues, text) per 64-byte slot
        self.str_index = {}        # text -> first slot

    # ---------------- emission ----------------
    def label(self):
        self.nlabel += 1
        return f"L{self.nlabel}"

    def place(self, lab):
        self.labels[lab] = len(self.code)

    def emit(self, name, arg=None, node=None):
        if node is not None and hasattr(node, 'lineno'):
            self.lines.append((len(self.code), node.lineno))
        op = OP[name]
        self.code.append(op)
        n = ARGS.get(op, 0)
        if n == 1:
            self.code.append(arg & 0xFF)
        elif n == 2:
            if isinstance(arg, str):
                self.fixups.append((len(self.code), arg))
                arg = 0
            self.code += bytes([arg & 0xFF, (arg >> 8) & 0xFF])

    # ---------------- strings (flash string table) ----------------
    def string_handle(self, text, node, single=False):
        data = text.encode('latin-1', errors='replace')
        if text in self.str_index:
            first = self.str_index[text]
            if single and self.str_slots[first][1]:
                raise CompileError(node, "strings() entries must fit one slot (62 bytes)")
            return handle(first)
        chunks = [data[i:i + STR_CHUNK] for i in range(0, len(data), STR_CHUNK)] or [b'']
        if single and len(chunks) > 1:
            raise CompileError(node, f"strings() entry is {len(data)} bytes, at most {STR_CHUNK}")
        if len(self.str_slots) + len(chunks) > STR_SLOTS:
            raise CompileError(node, f"string table full ({STR_SLOTS} slots of {STR_CHUNK} bytes)")
        first = len(self.str_slots)
        for k, c in enumerate(chunks):
            self.str_slots.append((c, k < len(chunks) - 1, text if k == 0 else ''))
        self.str_index[text] = first
        return handle(first)

    def string_block(self, args, node):
        """strings("a", "b", ...): consecutive one-slot entries; the handle of the first."""
        if not args or not all(isinstance(a, ast.Constant) and isinstance(a.value, str) for a in args):
            raise CompileError(node, "strings() takes string literals")
        if len(self.str_slots) < 256 < len(self.str_slots) + len(args):
            while len(self.str_slots) < 256:               # keep handle + i decodable: start at slot 256
                self.str_slots.append((b'', False, ''))
        first = len(self.str_slots)
        for a in args:
            data = a.value.encode('latin-1', errors='replace')
            if len(data) > STR_CHUNK:
                raise CompileError(a, f"strings() entry is {len(data)} bytes, at most {STR_CHUNK}")
            if len(self.str_slots) == STR_SLOTS:
                raise CompileError(node, "string table full")
            self.str_slots.append((data, False, a.value))
        return handle(first)

    def string_table(self):
        out = bytearray()
        for data, cont, _ in self.str_slots:
            slot = bytes([len(data), 1 if cont else 0]) + data
            out += slot + b'\0' * (STR_SLOT_BYTES - len(slot))
        return bytes(out)

    def load_int(self, v, node):
        if isinstance(v, bool):
            return self.emit('LOAD_TRUE' if v else 'LOAD_FALSE', node=node)
        if not SMALL_MIN <= v <= SMALL_MAX:
            raise CompileError(node, f"{v} does not fit a 33-bit small int (bigints need the runtime)")
        if -128 <= v <= 127:
            return self.emit('LOAD_SMALL', v, node)
        word = ((v << 1) | 1) & ((1 << 34) - 1)
        if word not in self.consts:
            if len(self.consts) == N_CONSTS:
                raise CompileError(node, "constant pool full")
            self.consts.append(word)
        self.emit('LOAD_CONST', self.consts.index(word), node)

    # ---------------- names ----------------
    def global_index(self, name, node):
        if name not in self.globals_:
            if len(self.globals_) == N_GLOBALS:
                raise CompileError(node, "too many globals")
            self.globals_[name] = len(self.globals_)
        return self.globals_[name]

    def is_local(self, name):
        return self.locals_ is not None and name in self.locals_ and name not in self.declared_global

    def load_name(self, name, node):
        if name in self.symconst:
            return self.load_int(self.symconst[name], node)
        if self.is_local(name):
            return self.emit('LOAD_FAST', self.locals_[name], node)
        self.emit('LOAD_GLOBAL', self.global_index(name, node), node)

    def store_name(self, name, node):
        if name in self.symconst:
            raise CompileError(node, f"{name} is a constant")
        if self.is_local(name):
            return self.emit('STORE_FAST', self.locals_[name], node)
        self.emit('STORE_GLOBAL', self.global_index(name, node), node)

    # ---------------- constant folding ----------------
    def const_value(self, e):
        """Return the compile-time value of e, or None if it is not constant."""
        if isinstance(e, ast.Constant) and (isinstance(e.value, int) or e.value is None):
            return e.value if not isinstance(e.value, bool) else e.value
        if isinstance(e, ast.Name) and e.id in self.symconst:
            return self.symconst[e.id]
        if isinstance(e, ast.UnaryOp) and isinstance(e.op, (ast.USub, ast.Invert, ast.UAdd)):
            v = self.const_value(e.operand)
            if isinstance(v, int) and not isinstance(v, bool):
                return {ast.USub: -v, ast.Invert: ~v, ast.UAdd: v}[type(e.op)]
        if isinstance(e, ast.BinOp) and type(e.op) in FOLD:
            a, b = self.const_value(e.left), self.const_value(e.right)
            if isinstance(a, int) and isinstance(b, int) and not isinstance(a, bool) and not isinstance(b, bool):
                return FOLD[type(e.op)](a, b)
        if isinstance(e, ast.Call) and isinstance(e.func, ast.Name) and e.func.id == 'const' and len(e.args) == 1:
            return self.const_value(e.args[0])
        return None

    # ---------------- expressions ----------------
    def is_mem32(self, e):
        return isinstance(e, ast.Subscript) and isinstance(e.value, ast.Name) and e.value.id == 'mem32'

    def expr(self, e):
        if isinstance(e, ast.Constant) and isinstance(e.value, str):
            return self.load_int(self.string_handle(e.value, e), e)
        if isinstance(e, ast.Call) and getattr(e.func, 'id', None) == 'strings':
            return self.load_int(self.string_block(e.args, e), e)
        v = self.const_value(e)
        if v is not None or (isinstance(e, ast.Constant) and e.value is None):
            if v is None:
                return self.emit('LOAD_NONE', node=e)
            return self.load_int(v, e)
        if isinstance(e, ast.Name):
            return self.load_name(e.id, e)
        if self.is_mem32(e):
            self.expr(e.slice)
            return self.emit('MEM32_LOAD', node=e)
        if isinstance(e, ast.BinOp):
            if type(e.op) not in BINOP:
                raise CompileError(e, f"operator {type(e.op).__name__} is not in the hardware fast path")
            self.expr(e.left)
            self.expr(e.right)
            return self.emit(BINOP[type(e.op)], node=e)
        if isinstance(e, ast.UnaryOp):
            if isinstance(e.op, ast.USub):
                self.load_int(0, e)
                self.expr(e.operand)
                return self.emit('BINARY_SUB', node=e)
            if isinstance(e.op, ast.Invert):
                self.expr(e.operand)
                self.load_int(-1, e)
                return self.emit('BINARY_XOR', node=e)
            if isinstance(e.op, ast.UAdd):
                return self.expr(e.operand)
        if isinstance(e, ast.Compare):
            if len(e.ops) != 1:
                raise CompileError(e, "chained comparisons are not supported")
            if type(e.ops[0]) not in CMPOP:
                raise CompileError(e, f"comparison {type(e.ops[0]).__name__} is not supported")
            self.expr(e.left)
            self.expr(e.comparators[0])
            return self.emit(CMPOP[type(e.ops[0])], node=e)
        if isinstance(e, ast.Call):
            return self.call(e)
        if isinstance(e, (ast.BoolOp, ast.UnaryOp)):      # not / and / or as a value -> bool
            f, end = self.label(), self.label()
            self.cond_jump(e, f, False)
            self.emit('LOAD_TRUE', node=e)
            self.emit('JUMP', end)
            self.place(f)
            self.emit('LOAD_FALSE', node=e)
            self.place(end)
            return
        raise CompileError(e, f"expression {type(e).__name__} is not supported")

    def cond_jump(self, e, target, jump_if):
        """Jump to target when bool(e) == jump_if, else fall through."""
        if isinstance(e, ast.UnaryOp) and isinstance(e.op, ast.Not):
            return self.cond_jump(e.operand, target, not jump_if)
        if isinstance(e, ast.BoolOp):
            is_and = isinstance(e.op, ast.And)
            if is_and != jump_if:      # and/jump-if-false or or/jump-if-true: any operand decides
                for v in e.values:
                    self.cond_jump(v, target, jump_if)
            else:                      # all operands must agree
                skip = self.label()
                for v in e.values[:-1]:
                    self.cond_jump(v, skip, not jump_if)
                self.cond_jump(e.values[-1], target, jump_if)
                self.place(skip)
            return
        v = self.const_value(e)
        if v is not None:
            if bool(v) == jump_if:
                self.emit('JUMP', target, e)
            return
        self.expr(e)
        self.emit('POP_JUMP_IF_TRUE' if jump_if else 'POP_JUMP_IF_FALSE', target, e)

    # ---------------- statements ----------------
    def block(self, stmts):
        for s in stmts:
            self.stmt(s)

    def stmt(self, s):
        if isinstance(s, (ast.Import, ast.ImportFrom, ast.Pass)):
            return
        if isinstance(s, ast.Expr):
            if isinstance(s.value, ast.Constant):           # docstring
                return
            if isinstance(s.value, ast.Call):
                return self.call_stmt(s.value)
            raise CompileError(s, "expression statement has no effect")
        if isinstance(s, ast.Global):
            if self.locals_ is None:
                return
            self.declared_global.update(s.names)
            return
        if isinstance(s, ast.Assign):
            if self.locals_ is None and len(s.targets) == 1 and isinstance(s.targets[0], ast.Name) \
                    and s.targets[0].id in self.symconst:
                return                                      # folded constant
            if self.is_mem32(s.targets[0]) and len(s.targets) == 1:
                self.expr(s.targets[0].slice)
                self.expr(s.value)
                return self.emit('MEM32_STORE', node=s)
            self.expr(s.value)
            for i, t in enumerate(s.targets):
                if not isinstance(t, ast.Name):
                    raise CompileError(s, "only name and mem32[...] targets are supported")
                if i < len(s.targets) - 1:
                    self.emit('DUP_TOP', node=s)
                self.store_name(t.id, s)
            return
        if isinstance(s, ast.AugAssign):
            if type(s.op) not in BINOP:
                raise CompileError(s, f"operator {type(s.op).__name__} is not in the hardware fast path")
            if self.is_mem32(s.target):
                self.expr(s.target.slice)
                self.emit('DUP_TOP', node=s)
                self.emit('MEM32_LOAD', node=s)
                self.expr(s.value)
                self.emit(BINOP[type(s.op)], node=s)
                return self.emit('MEM32_STORE', node=s)
            if not isinstance(s.target, ast.Name):
                raise CompileError(s, "only name and mem32[...] targets are supported")
            self.load_name(s.target.id, s)
            self.expr(s.value)
            self.emit(BINOP[type(s.op)], node=s)
            return self.store_name(s.target.id, s)
        if isinstance(s, ast.If):
            else_l, end_l = self.label(), self.label()
            self.cond_jump(s.test, else_l, False)
            self.block(s.body)
            if s.orelse:
                self.emit('JUMP', end_l, s)
            self.place(else_l)
            self.block(s.orelse)
            self.place(end_l)
            return
        if isinstance(s, ast.While):
            if s.orelse:
                raise CompileError(s, "while/else is not supported")
            top, end = self.label(), self.label()
            self.place(top)
            self.cond_jump(s.test, end, False)
            self.loops.append((top, end))
            self.block(s.body)
            self.loops.pop()
            self.emit('JUMP', top, s)
            self.place(end)
            return
        if isinstance(s, (ast.Break, ast.Continue)):
            if not self.loops:
                raise CompileError(s, "break/continue outside a loop")
            top, end = self.loops[-1]
            return self.emit('JUMP', end if isinstance(s, ast.Break) else top, s)
        if isinstance(s, ast.Return):
            if self.locals_ is None:
                raise CompileError(s, "return outside a function (use halt(value))")
            if self.in_handler:
                if s.value is not None:
                    raise CompileError(s, "an interrupt handler cannot return a value")
                return self.emit('RETURN_FROM_IRQ', node=s)
            if s.value is None:
                self.emit('LOAD_NONE', node=s)
            else:
                self.expr(s.value)
            return self.emit('RETURN', node=s)
        if isinstance(s, ast.FunctionDef):
            if self.locals_ is not None:
                raise CompileError(s, "nested functions are not supported")
            return                                          # compiled after the main program
        raise CompileError(s, f"statement {type(s).__name__} is not supported")

    def call_stmt(self, c):
        if not isinstance(c.func, ast.Name):
            raise CompileError(c, "only builtin calls are supported")
        f, args = c.func.id, c.args
        if f == 'irq_handler':
            if len(args) != 1 or not isinstance(args[0], ast.Name) or args[0].id not in self.funcs:
                raise CompileError(c, "irq_handler() takes a handler function defined in this file")
            return self.emit('SET_IRQ_VECTOR', 'fn:' + args[0].id, c)
        if f in ('irq_enable', 'irq_disable') and not args:
            return self.emit('IRQ_ENABLE' if f == 'irq_enable' else 'IRQ_DISABLE', node=c)
        if f == 'halt' and len(args) <= 1:
            if args:
                self.expr(args[0])
            else:
                self.emit('LOAD_NONE', node=c)
            return self.emit('RETURN_VALUE', node=c)
        if f in self.funcs:
            self.call(c)
            return self.emit('POP_TOP', node=c)              # discard the return value
        raise CompileError(c, f"unknown builtin {f}()")

    def call(self, c):
        f = getattr(c.func, 'id', None)
        if f not in self.funcs:
            raise CompileError(c, f"{f or 'this'}() is not a function defined in this file (builtins are statements)")
        if f in self.handlers:
            raise CompileError(c, f"{f}() is an interrupt handler and cannot be called")
        if c.keywords or any(isinstance(a, ast.Starred) for a in c.args):
            raise CompileError(c, "keyword and * arguments are not supported")
        nparams = len(self.funcs[f].args.args)
        if len(c.args) != nparams:
            raise CompileError(c, f"{f}() takes {nparams} arguments, {len(c.args)} given")
        for a in c.args:
            self.expr(a)
        self.emit('CALL', 'fn:' + f, c)

    # ---------------- top level ----------------
    def collect_constants(self, tree):
        counts = {}
        for s in tree.body:
            if isinstance(s, (ast.Assign, ast.AnnAssign)):
                for t in (s.targets if isinstance(s, ast.Assign) else [s.target]):
                    if isinstance(t, ast.Name):
                        counts[t.id] = counts.get(t.id, 0) + 1
        for node in ast.walk(tree):                          # names reassigned anywhere are not constants
            if isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name):
                counts[node.target.id] = 99
            if isinstance(node, ast.FunctionDef):
                for n in ast.walk(node):
                    if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                        counts[n.id] = 99
        for s in tree.body:
            if isinstance(s, ast.Assign) and len(s.targets) == 1 and isinstance(s.targets[0], ast.Name):
                name = s.targets[0].id
                is_const_call = isinstance(s.value, ast.Call) and getattr(s.value.func, 'id', '') == 'const'
                if counts.get(name) == 1 and (name.isupper() or is_const_call):
                    v = self.const_value(s.value)
                    if isinstance(v, int):
                        self.symconst[name] = v

    def function(self, fn):
        a = fn.args
        if a.vararg or a.kwarg or a.kwonlyargs or a.defaults or a.posonlyargs:
            raise CompileError(fn, "only plain positional parameters are supported")
        self.in_handler = fn.name in self.handlers
        if self.in_handler and a.args:
            raise CompileError(fn, "interrupt handlers take no arguments")
        self.place('fn:' + fn.name)
        self.declared_global = {n for s in ast.walk(fn) if isinstance(s, ast.Global) for n in s.names}
        self.locals_ = {p.arg: i for i, p in enumerate(a.args)}
        if len(self.locals_) > N_LOCALS:
            raise CompileError(fn, "too many parameters")
        for i in reversed(range(len(a.args))):              # arguments arrive on the operand stack
            self.emit('STORE_FAST', i, fn)
        for n in ast.walk(fn):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id not in self.declared_global:
                if n.id not in self.locals_:
                    if len(self.locals_) == N_LOCALS:
                        raise CompileError(fn, "too many locals")
                    self.locals_[n.id] = len(self.locals_)
        self.block(fn.body)
        if self.in_handler:
            self.emit('RETURN_FROM_IRQ', node=fn.body[-1])
        else:
            self.emit('LOAD_NONE', node=fn.body[-1])
            self.emit('RETURN', node=fn.body[-1])
        self.locals_, self.declared_global, self.in_handler = None, set(), False

    def compile(self, tree):
        self.collect_constants(tree)
        self.funcs = {s.name: s for s in tree.body if isinstance(s, ast.FunctionDef)}
        self.handlers = {n.args[0].id for n in ast.walk(tree)
                         if isinstance(n, ast.Call) and getattr(n.func, 'id', '') == 'irq_handler'
                         and n.args and isinstance(n.args[0], ast.Name)}
        self.block(tree.body)
        self.emit('LOAD_NONE')
        self.emit('RETURN_VALUE')                           # falling off the end halts with None
        for fn in self.funcs.values():
            self.function(fn)
        for pos, lab in self.fixups:
            addr = self.labels[lab]
            self.code[pos], self.code[pos + 1] = addr & 0xFF, addr >> 8
        if len(self.code) > CODE_SIZE:
            raise CompileError(tree, f"program is {len(self.code)} bytes, code memory holds {CODE_SIZE}")

    # ---------------- output ----------------
    def listing(self):
        out, line_at, pos = [], dict(self.lines), 0
        rev = {}
        for k, v in self.labels.items():
            rev.setdefault(v, []).append(k)
        last_line = None
        while pos < len(self.code):
            if pos in line_at and line_at[pos] != last_line:
                last_line = line_at[pos]
                out.append(f"\n; {last_line:4d}: {self.src[last_line - 1].strip()}")
            for lab in rev.get(pos, []):
                if lab.startswith('fn:'):
                    out.append(f"{lab[3:]}:")
            op = self.code[pos]
            n = ARGS.get(op, 0)
            arg = ''
            if n == 1:
                a = self.code[pos + 1]
                arg = str(a - 256 if op == OP['LOAD_SMALL'] and a > 127 else a)
                if op == OP['LOAD_CONST']:
                    arg += f"    ({self.consts[a] >> 1 if self.consts[a] < (1 << 33) else (self.consts[a] >> 1) - (1 << 33)})"
                if op in (OP['LOAD_GLOBAL'], OP['STORE_GLOBAL']):
                    arg += f"    ({next(k for k, v in self.globals_.items() if v == a)})"
            elif n == 2:
                arg = str(self.code[pos + 1] | self.code[pos + 2] << 8)
            out.append(f"  {pos:5d}  {NAME.get(op, '??'):<18} {arg}")
            pos += 1 + n
        return '\n'.join(out).lstrip('\n') + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('src')
    ap.add_argument('-o', '--out', required=True, help='output path prefix')
    args = ap.parse_args()
    lines, where = inline_imports(args.src)
    text = "\n".join(lines) + "\n"
    c = Compiler(text)
    try:
        c.compile(ast.parse(text, args.src))
    except (CompileError, SyntaxError) as e:
        n = e.lineno
        f, k = where[n - 1] if n and 0 < n <= len(where) else (args.src, n or '?')
        sys.exit(f"{f}:{k}: {getattr(e, 'msg', e)}")
    with open(args.out + '.code.hex', 'w') as f:
        f.writelines(f"{b:02x}\n" for b in c.code)
    with open(args.out + '.const.hex', 'w') as f:
        f.writelines(f"{w:09x}\n" for w in (c.consts or [0]))
    with open(args.out + '.lst', 'w') as f:
        f.write(c.listing())
    with open(args.out + '_syms.svh', 'w') as f:
        f.write(f"// Generated by pyc.py from {args.src}\n")
        f.write(f"localparam int PROG_BYTES = {len(c.code)};\n")
        for k, v in c.globals_.items():
            f.write(f"localparam int G_{k} = {v};\n")
    payload = bytes(c.code) + b''.join(w.to_bytes(5, 'little') for w in c.consts)
    image = b'PYC1' + struct.pack('<HHI', len(c.code), len(c.consts), sum(payload) & 0xFFFFFFFF) + payload
    table = c.string_table()
    if table and len(image) > STR_BASE:
        sys.exit(f"{args.src}: boot image ({len(image)} bytes) overlaps the string table at 0x{STR_BASE:X}")
    with open(args.out + '.flash.bin', 'wb') as f:
        f.write(image)
        if table:
            f.write(b'\xff' * (STR_BASE - len(image)) + table)
    with open(args.out + '.flash.hex', 'w') as f:
        f.writelines(f"{b:02x}\n" for b in image)
        if table:
            f.write(f"@{STR_BASE:x}\n")
            f.writelines(f"{b:02x}\n" for b in table)
    with open(args.out + '.strings.txt', 'w') as f:
        for k, (data, cont, text) in enumerate(c.str_slots):
            if text or not cont:
                h = handle(k)
                f.write(f"slot {k:3d}  handle {h:4d}  {text!r}\n" if text else f"slot {k:3d}  (continued)\n")
    print(f"{args.src}: {len(c.code)} bytes, {len(c.consts)} consts, {len(c.globals_)} globals, "
          f"{len(image)} byte flash image, {len(c.str_slots)} string slots")


if __name__ == '__main__':
    main()
