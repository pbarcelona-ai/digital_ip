#!/usr/bin/env python3
# ***************
# Filename: sv_format.py
# Author: FPGA Cores 4 U
# Description: Layout-only SystemVerilog reformatter with two rules:
#   1. one statement per line: a line holding several statements is split
#      at top-level ';', begin/end, fork/join, case headers and else, with
#      the new lines indented by block level;
#   2. one line per port: an instantiation with several port connections
#      on one line is rewritten as "inst (", one connection per line, ");".
#   3. one line per parameter: an instantiation's #( ... ) override list
#      with two entries on a line is rewritten as "#(", one entry per line,
#      ") inst (".
#   Everything else is left byte for byte as it was. Every rewritten file
#   is checked to hold exactly the same token sequence as before (only
#   whitespace changes), otherwise it is left untouched. Lines that cannot
#   be split safely (compiler directives, statement continuations) are
#   reported, not changed.
# Date: 2026-10-09
#
# Usage: scripts/sv_format.py [--check] [files...]
#   no files: every tracked *.sv / *.svh under the git work tree
#   --check   report what would change, write nothing (exit 1 if anything would)
import argparse, os, re, subprocess, sys

DIRECTIVES = {"define", "undef", "ifdef", "ifndef", "elsif", "else", "endif", "include", "timescale",
              "default_nettype", "resetall", "celldefine", "endcelldefine", "line", "pragma",
              "begin_keywords", "end_keywords", "unconnected_drive", "nounconnected_drive"}
CLOSERS = {"end", "join", "join_any", "join_none", "endcase", "endtask", "endfunction", "endmodule",
           "endgenerate", "endpackage", "endclass", "endinterface", "endprogram", "endgroup",
           "endproperty", "endsequence", "endclocking", "endchecker"}
HEADER_OPENERS = {"task", "function", "module", "package", "class", "interface", "program"}
KEYWORDS = CLOSERS | HEADER_OPENERS | {
    "always", "always_ff", "always_comb", "always_latch", "initial", "final", "assign", "begin", "fork",
    "if", "else", "for", "foreach", "while", "do", "repeat", "forever", "case", "casez", "casex", "unique",
    "unique0", "priority", "return", "break", "continue", "wait", "disable", "assert", "assume", "cover",
    "property", "sequence", "generate", "genvar", "localparam", "parameter", "typedef", "struct", "enum",
    "union", "logic", "reg", "wire", "bit", "byte", "int", "integer", "shortint", "longint", "real",
    "string", "input", "output", "inout", "ref", "const", "static", "automatic", "virtual", "import",
    "export", "extern", "pure", "default", "inside", "posedge", "negedge", "or", "and", "not", "buf",
    "void", "new", "this", "super", "null", "var", "signed", "unsigned", "packed", "tri", "supply0",
    "supply1", "wand", "wor", "event", "time", "realtime", "shortreal", "chandle", "mailbox",
    "semaphore", "covergroup", "coverpoint", "bins", "with", "iff", "throughout", "within", "intersect",
    "modport", "clocking", "checker", "let", "defparam", "specify", "endspecify", "table", "endtable",
    "primitive", "endprimitive", "release", "force", "deassign", "type", "nand", "nor", "xor", "xnor",
    "bufif0", "bufif1", "notif0", "notif1", "pullup", "pulldown", "tran", "rtran"}

TOKEN_RE = re.compile(r"""
  (?P<nl>\n)
 |(?P<ws>[ \t\r\f]+)
 |(?P<lcom>//[^\n]*)
 |(?P<bcom>/\*.*?\*/)
 |(?P<str>"(?:\\.|[^"\\\n])*")
 |(?P<attr>\(\*(?!\))[^;]*?\*\))
 |(?P<dir>`[A-Za-z_]\w*)
 |(?P<num>(?:\d[\d_]*)?'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ?_]+|'[01xXzZ]|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?(?:fs|ps|ns|us|ms|s)?)
 |(?P<esc>\\\S+)
 |(?P<id>[A-Za-z_$][\w$]*)
 |(?P<op><<<=|>>>=|===|!==|==\?|!=\?|<<=|>>=|<->|->>|\|->|\|=>|::|\+\+|--|\*\*|<<<|>>>|<<|>>|<=|>=|==|!=|&&|\|\||\+=|-=|\*=|/=|%=|&=|\|=|\^=|->|\+:|-:|\#\#|.)
""", re.S | re.X)


class Tok:
    __slots__ = ("kind", "text", "line")

    def __init__(self, kind, text, line):
        self.kind, self.text, self.line = kind, text, line

    def sig(self):
        return self.kind not in ("ws", "nl", "lcom", "bcom")


def lex(src):
    toks, line, pos = [], 0, 0
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        kind = m.lastgroup
        text = m.group()
        if kind == "dir" and text[1:] == "define":       # `define body runs to the unescaped end of line
            end = pos
            while True:
                nl = src.find("\n", end)
                if nl < 0: nl = len(src); break
                if src[nl - 1] != "\\": break
                end = nl + 1
            text = src[pos:nl]
            kind = "define"
        toks.append(Tok(kind, text, line))
        line += text.count("\n")
        pos += len(text)
    return toks


def sig_texts(toks):
    return [t.text for t in toks if t.sig()] + [t.text for t in toks if t.kind in ("lcom", "bcom")]


def split_lines(toks):
    """Physical lines: lists of tokens without the newline."""
    lines, cur = [], []
    for t in toks:
        if t.kind == "nl":
            lines.append(cur); cur = []
        else:
            cur.append(t)
    lines.append(cur)
    return lines


def detect_unit(lines):
    counts = {}
    prev = 0
    for ln in lines:
        if not ln or all(t.kind == "ws" for t in ln):
            continue
        ind = len(ln[0].text.expandtabs(2)) if ln[0].kind == "ws" else 0
        d = ind - prev
        if 0 < d <= 8:
            counts[d] = counts.get(d, 0) + 1
        prev = ind
    return " " * (max(counts, key=counts.get) if counts else 2)


def line_text(ln):
    return "".join(t.text for t in ln)


# ---------------------------------------------------------------- rule 1
def needs_split(sig):
    """sig: significant tokens of one line (depth 0 at start). True if it holds several statements."""
    depth, semis, i = 0, 0, 0
    after_first = None
    for i, t in enumerate(sig):
        if t.text in "([{" and t.kind == "op": depth += 1
        elif t.text in ")]}" and t.kind == "op": depth -= 1
        elif t.text == ";" and depth == 0:
            semis += 1
            if after_first is None: after_first = i + 1
    if semis >= 2:
        return True
    if semis == 1 and after_first < len(sig):
        rest = sig[after_first]
        return not (rest.text in CLOSERS or rest.text == "else" or rest.kind == "dir")
    return False


def format_stmts(ln, base, unit, start_level=0):
    """Re-layout the tokens of one physical line, starting start_level blocks deep.
    Returns (text lines, block level still open at the end of the line)."""
    body = [t for t in ln if t.kind != "ws" or t is not ln[0]]
    trailing = None
    if body and body[-1].kind == "lcom":
        trailing = body.pop()
    while body and body[-1].kind == "ws":
        body.pop()
    sig_idx = [i for i, t in enumerate(body) if t.sig()]
    out, cur, level = [], [], start_level
    cur_level = [start_level]
    if_levels = []
    depth = 0
    header = None              # pending task/function/module header: ';' opens a block
    case_hdr = 0               # 1: saw case keyword, waiting for its ')'
    prev_sig = None

    def flush():
        nonlocal cur
        while cur and cur[-1].kind == "ws": cur.pop()
        while cur and cur[0].kind == "ws": cur.pop(0)
        if cur:
            out.append(base + unit * cur_level[0] + "".join(t.text for t in cur))
        cur = []
        cur_level[0] = level

    def pop_ifs(lvl):
        nonlocal level
        while if_levels and if_levels[-1][0] >= lvl:
            if if_levels.pop()[1]:
                level -= 1

    def has_else(i):
        """the if statement starting at body[i] has an else branch"""
        d = nest = 0
        for j in range(i + 1, len(body)):
            u = body[j]
            if not u.sig(): continue
            if u.kind == "op" and u.text in ("(", "[", "{"): d += 1; continue
            if u.kind == "op" and u.text in (")", "]", "}"): d -= 1; continue
            if d: continue
            if u.text in ("begin", "fork") or u.text in ("case", "casez", "casex"): nest += 1; continue
            if u.text in CLOSERS: nest -= 1
            elif u.text != ";": continue
            if nest <= 0:
                n2 = next_sig(j)
                return n2 is not None and n2.text == "else"
        return False

    def next_sig(i):
        for j in range(i + 1, len(body)):
            if body[j].sig(): return body[j]
        return None

    def next_is_comment(i):
        j = i + 1
        while j < len(body) and body[j].kind == "ws": j += 1
        return j < len(body) and body[j].kind == "bcom"

    i = 0
    while i < len(body):
        t = body[i]
        if not t.sig():
            cur.append(t); i += 1; continue
        x = t.text
        if t.kind == "op" and x in ("(", "[", "{"):
            depth += 1
            cur.append(t); i += 1; prev_sig = t; continue
        if t.kind == "op" and x in (")", "]", "}"):
            depth -= 1
            cur.append(t); i += 1; prev_sig = t
            if depth == 0 and case_hdr == 1 and x == ")":       # end of "case (expr)"
                nxt = next_sig(i - 1)
                if nxt is not None and nxt.text == "inside":
                    case_hdr = 2
                else:
                    case_hdr = 0; level += 1
                    if nxt is not None and not next_is_comment(i - 1): flush()
            continue
        if depth > 0:
            cur.append(t); i += 1; prev_sig = t; continue
        if case_hdr == 2 and x == "inside":
            cur.append(t); i += 1; prev_sig = t
            case_hdr = 0; level += 1
            if next_sig(i - 1) is not None and not next_is_comment(i - 1): flush()
            continue
        if x in ("case", "casez", "casex", "randcase") and t.kind == "id":
            case_hdr = 1
        if x in HEADER_OPENERS and t.kind == "id" and (prev_sig is None or prev_sig.text not in ("import", "export", "extern", "pure", "virtual")) and not (x == "function" and prev_sig is not None and prev_sig.text == "new"):
            header = x
        if x == "else" and t.kind == "id":
            if not cur or all(c.kind == "ws" for c in cur):
                cur = []
                cur_level[0] = if_levels[-1][0] if if_levels else level
            cur.append(t); i += 1; prev_sig = t; continue
        if x == "if" and t.kind == "id":
            if not (prev_sig is not None and prev_sig.text == "else"):
                bumped = any(c.sig() for c in cur) and has_else(i)
                if bumped:                 # "always @(..) if (a) x; else y;": the if/else goes below the header
                    flush(); level += 1; cur_level[0] = level
                if_levels.append((cur_level[0], bumped))
            cur.append(t); i += 1; prev_sig = t; continue
        if x in CLOSERS and t.kind == "id":
            flush()
            level = max(level - 1, 0)
            cur_level[0] = level
            cur.append(t)
            j = i + 1
            # optional ": label"
            k = j
            while k < len(body) and body[k].kind == "ws": k += 1
            if k < len(body) and body[k].text == ":":
                k2 = k + 1
                while k2 < len(body) and body[k2].kind == "ws": k2 += 1
                if k2 < len(body) and body[k2].kind == "id":
                    cur.extend(body[j:k2 + 1]); j = k2 + 1
            i = j; prev_sig = cur[-1]
            nxt = next_sig(i - 1)
            pop_ifs(level + 1)
            if nxt is not None and nxt.text == "else":
                continue
            pop_ifs(level)
            if nxt is not None and not next_is_comment(i - 1):
                flush()
            continue
        if x in ("begin", "fork") and t.kind == "id":
            cur.append(t)
            j = i + 1
            k = j
            while k < len(body) and body[k].kind == "ws": k += 1
            if x == "begin" and k < len(body) and body[k].text == ":":
                k2 = k + 1
                while k2 < len(body) and body[k2].kind == "ws": k2 += 1
                if k2 < len(body) and body[k2].kind == "id":
                    cur.extend(body[j:k2 + 1]); j = k2 + 1
            level += 1
            i = j; prev_sig = cur[-1]
            if next_sig(i - 1) is not None:
                flush()
            continue
        if x == ";":
            cur.append(t)
            if header:
                header = None; level += 1
            nxt = next_sig(i)
            if nxt is None or nxt.text != "else":
                pop_ifs(level)
            i += 1; prev_sig = t
            if nxt is not None and not next_is_comment(i - 1):
                flush()
            continue
        cur.append(t); i += 1; prev_sig = t
    flush()
    if trailing is not None:              # a comment that ended the original line stays with its first line
        out[0] += " " + trailing.text
    return out, level


def rule1(lines, unit, report, fname):
    """Split multi-statement lines; returns new list of text lines."""
    out = []
    depth = 0
    prev_sig = None            # last significant token of preceding lines
    stmt_start_prev = {";", "begin", "else", "end", ")", ":", "fork", "join", "join_any", "join_none",
                       "endcase", "endtask", "endfunction", "endgenerate", "generate", "*)"}
    carry = None               # (base, level): a block opened by a split line continues on later lines
    for n, ln in enumerate(lines):
        sig = [t for t in ln if t.sig()]
        start_depth = depth
        for t in sig:
            if t.kind == "op" and t.text in "([{": depth += 1
            elif t.kind == "op" and t.text in ")]}": depth -= 1
        txt = line_text(ln)
        has_dir = any(t.kind in ("dir", "define") and t.text[1:].split()[0] in DIRECTIVES
                      or t.kind == "define" for t in ln)
        at_stmt_start = (prev_sig is None or prev_sig.text in stmt_start_prev or prev_sig.text in CLOSERS
                         or prev_sig.kind in ("dir", "define", "attr")
                         or (prev_sig.kind == "id" and n > 0 and _label_before(lines, n)))
        if carry and sig and start_depth == 0 and not has_dir:
            new, lvl = format_stmts(ln, carry[0], unit, carry[1])   # re-indent inside the carried block
            out.extend(new)
            carry = (carry[0], lvl) if lvl > 0 else None
        elif carry or not sig:
            out.append(txt)
        elif start_depth == 0 and needs_split(sig):
            if has_dir:
                report.append(f"{fname}:{n + 1}: skipped (compiler directive on the line): {txt.strip()}")
                out.append(txt)
            elif not at_stmt_start:
                report.append(f"{fname}:{n + 1}: skipped (continues a statement): {txt.strip()}")
                out.append(txt)
            else:
                base = ln[0].text if ln and ln[0].kind == "ws" else ""
                new, lvl = format_stmts(ln, base, unit)
                out.extend(new)
                if lvl > 0 and depth == 0:
                    carry = (base, lvl)
        else:
            out.append(txt)
        if has_dir:
            prev_sig = None            # `ifdef X / `include "f": the next line starts a statement
        elif sig:
            prev_sig = sig[-1]
    return out


def _label_before(lines, n):
    """previous significant tokens end in 'begin : label' / 'end : label'."""
    toks = [t for ln in lines[max(0, n - 3):n] for t in ln if t.sig()]
    return len(toks) >= 3 and toks[-2].text == ":" and toks[-3].text in ("begin", "end", "fork")


def _keep_trailing_comments(pieces):
    """A comment after an entry's comma on that entry's own line belongs to that entry, not to
    the next one: move it from the next entry's leading comments to the entry's tail."""
    out = [list(p) for p in pieces]
    for i in range(1, len(out)):
        prev_line = out[i - 1][3]
        keep = []
        for c in out[i][0]:
            if prev_line is not None and c.line == prev_line:
                out[i - 1][2] = out[i - 1][2] + [c]
            else:
                keep.append(c)
        out[i][0] = keep
    return [tuple(p) for p in out]


# ---------------------------------------------------------------- rule 2
def find_instances(toks):
    """Yield (start, lparen, rparen, semi) token indices of single-instance instantiations."""
    sig = [i for i, t in enumerate(toks) if t.sig()]
    pos = {ti: k for k, ti in enumerate(sig)}
    depth_at = {}
    d = 0
    for k, ti in enumerate(sig):
        depth_at[ti] = d
        t = toks[ti]
        if t.kind == "op" and t.text in "([{": d += 1
        elif t.kind == "op" and t.text in ")]}": d -= 1

    def match(k):        # k: index into sig of an opening bracket -> index of its closer
        d = 0
        for k2 in range(k, len(sig)):
            x = toks[sig[k2]].text
            if toks[sig[k2]].kind == "op" and x in "([{": d += 1
            elif toks[sig[k2]].kind == "op" and x in ")]}":
                d -= 1
                if d == 0: return k2
        return None

    starts = {";", "begin", "end", "endgenerate", "generate", ")", ":", "else", "*)"}
    for k, ti in enumerate(sig):
        t = toks[ti]
        if t.kind != "id" or t.text in KEYWORDS or depth_at[ti] != 0:
            continue
        if k > 0:
            p = toks[sig[k - 1]]
            # "begin : label" (named generate block) also starts a statement
            named = k >= 3 and toks[sig[k - 2]].text == ":" and toks[sig[k - 3]].text == "begin"
            if not (p.text in starts or p.kind in ("dir", "define", "attr") or named):
                continue
        k2 = k + 1
        if k2 < len(sig) and toks[sig[k2]].text == "#":
            if k2 + 1 >= len(sig) or toks[sig[k2 + 1]].text != "(":
                continue
            m = match(k2 + 1)
            if m is None: continue
            k2 = m + 1
        if k2 >= len(sig) or toks[sig[k2]].kind not in ("id", "esc") or toks[sig[k2]].text in KEYWORDS:
            continue
        k3 = k2 + 1
        while k3 < len(sig) and toks[sig[k3]].text == "[":
            m = match(k3)
            if m is None: break
            k3 = m + 1
        if k3 >= len(sig) or toks[sig[k3]].text != "(":
            continue
        m = match(k3)
        if m is None or m + 1 >= len(sig) or toks[sig[m + 1]].text != ";":
            continue
        yield sig[k], sig[k3], sig[m], sig[m + 1]


def rule2(src, unit):
    toks = lex(src)
    edits = []
    for start, lp, rp, semi in find_instances(toks):
        inner = toks[lp + 1:rp]
        # split connections at depth-0 commas
        ports, cur, d = [], [], 0
        comments_after = []
        for t in inner:
            if t.kind == "op" and t.text in "([{": d += 1
            elif t.kind == "op" and t.text in ")]}": d -= 1
            if d == 0 and t.text == "," and t.kind == "op":
                ports.append(cur); cur = []
                continue
            cur.append(t)
        ports.append(cur)
        ports_sig = [p for p in ports if any(t.sig() for t in p)]
        if len(ports_sig) < 2:
            continue
        # one line per port already? (no physical line starts two connections)
        start_lines = []
        for p in ports:
            fs = next((t for t in p if t.sig()), None)
            if fs is not None: start_lines.append(fs.line)
        if len(set(start_lines)) == len(start_lines):
            continue
        if any(t.kind in ("dir", "define") for t in inner):
            # `ifdef inside the connection list: keep its lines, split every line holding
            # several connections into one line per connection at that line's indentation
            starts = []
            d = 0
            prev_split = True
            in_dir = False
            for k in range(lp + 1, rp):
                u = toks[k]
                if u.kind == "nl":
                    in_dir = False
                if in_dir:
                    continue
                if u.kind == "dir" and u.text[1:] in DIRECTIVES:
                    in_dir = True                    # the rest of a directive line is its argument
                    continue
                # a macro call (e.g. a port-group macro) is a connection of its own
                if u.kind == "op" and u.text in ("(", "[", "{"): d += 1
                elif u.kind == "op" and u.text in (")", "]", "}"): d -= 1
                if d == 0 and u.kind == "op" and u.text == ",":
                    prev_split = True
                elif u.sig() and prev_split and d >= 0:
                    starts.append(k)
                    prev_split = False
            by_line = {}
            for k in starts:
                by_line.setdefault(toks[k].line, []).append(k)
            line_start = start
            while line_start > 0 and toks[line_start - 1].kind != "nl": line_start -= 1
            base = toks[line_start].text if toks[line_start].kind == "ws" else ""
            if starts and toks[starts[0]].line == toks[lp].line:
                k = starts[0]                        # first connection on the "inst (" line
                ws = k - 1 if toks[k - 1].kind == "ws" else k
                edits.append((ws, k, "\n" + base + unit))
            ind = base + unit                        # every connection at the port indentation
            for ln_no, ks in by_line.items():
                k0 = ks[0]
                ls = k0
                while ls > 0 and toks[ls - 1].kind != "nl": ls -= 1
                if all(toks[j].kind == "ws" for j in range(ls, k0)) and toks[k0].line != toks[lp].line:
                    if ls < k0 and toks[ls].text != ind:
                        edits.append((ls, k0, ind))  # re-indent a line that starts with a connection
                    elif ls == k0 and ind:
                        edits.append((k0, k0, ind))
                for k in ks[1:]:
                    ws = k - 1 if toks[k - 1].kind == "ws" else k
                    edits.append((ws, k, "\n" + ind))
            continue
        # base indentation of the instance line
        line_start = start
        while line_start > 0 and toks[line_start - 1].kind != "nl": line_start -= 1
        base = toks[line_start].text if toks[line_start].kind == "ws" else ""
        pieces = []
        bad = False
        for idx, p in enumerate(ports):
            lead = []          # own-line comments before the connection
            body = []
            tail = []          # comments after the connection
            seen = False
            for t in p:
                if t.sig(): seen = True; body.extend(tail); tail = []; body.append(t)
                elif t.kind in ("lcom", "bcom"):
                    (tail if seen else lead).append(t)
                elif seen:
                    tail.append(t)
            if any(t.kind == "lcom" for t in body):
                bad = True                                  # line comment inside a connection: leave as is
            text = "".join(t.text for t in body)
            text = re.sub(r"\s*\n\s*", " ", text).strip()
            pieces.append((lead, text, [t for t in tail if t.kind in ("lcom", "bcom")],
                           body[-1].line if body else None))
        if bad:
            continue
        pieces = _keep_trailing_comments(pieces)
        lines = []
        n = len(pieces)
        for idx, (lead, text, tail, _) in enumerate(pieces):
            for c in lead:
                lines.append(base + unit + c.text)
            if not text:
                continue
            ln = base + unit + text + ("," if idx < n - 1 else "")
            for c in tail:
                ln += " " + c.text
            lines.append(ln)
        head = "".join(t.text for t in toks[start:lp + 1]).rstrip()
        new = head + "\n" + "\n".join(lines) + "\n" + base + ")"
        edits.append((start, rp + 1, new))
    if not edits:
        return src
    out, last = [], 0
    offs = []
    acc = 0
    for t in toks:
        offs.append(acc); acc += len(t.text)
    offs.append(acc)
    for s, e, new in sorted(edits):
        if offs[s] < last:
            continue
        out.append(src[last:offs[s]]); out.append(new); last = offs[e]
    out.append(src[last:])
    return "".join(out)


def rule3(src, unit):
    """One line per parameter: an instantiation's #( ... ) override list with several entries
    and a line holding two of them is rewritten as "#(", one entry per line, ")"."""
    toks = lex(src)
    edits = []
    for start, lp, rp, semi in find_instances(toks):
        hs = next((k for k in range(start + 1, lp) if toks[k].sig() and toks[k].text == "#"), None)
        if hs is None:
            continue
        po = next(k for k in range(hs + 1, lp) if toks[k].sig())          # "(" of the list
        d, pc = 0, None
        for k in range(po, lp):
            if toks[k].kind == "op" and toks[k].text in "([{": d += 1
            elif toks[k].kind == "op" and toks[k].text in ")]}":
                d -= 1
                if d == 0: pc = k; break
        if pc is None:
            continue
        inner = toks[po + 1:pc]
        if any(t.kind in ("dir", "define") for t in inner):
            continue
        entries, cur, d = [], [], 0
        for t in inner:
            if t.kind == "op" and t.text in "([{": d += 1
            elif t.kind == "op" and t.text in ")]}": d -= 1
            if d == 0 and t.kind == "op" and t.text == ",":
                entries.append(cur); cur = []
                continue
            cur.append(t)
        entries.append(cur)
        firsts = [next((t for t in e if t.sig()), None) for e in entries]
        if len(entries) < 2 or any(f is None for f in firsts):
            continue
        lines_of = [f.line for f in firsts]
        if len(set(lines_of)) == len(lines_of) and toks[po].line not in lines_of:
            continue                                        # already one entry per line
        line_start = start
        while line_start > 0 and toks[line_start - 1].kind != "nl": line_start -= 1
        base = toks[line_start].text if toks[line_start].kind == "ws" else ""
        pieces, bad = [], False
        for e in entries:
            lead, body, tail, seen = [], [], [], False
            for t in e:
                if t.sig(): seen = True; body.extend(tail); tail = []; body.append(t)
                elif t.kind in ("lcom", "bcom"): (tail if seen else lead).append(t)
                elif seen: tail.append(t)
            if any(t.kind == "lcom" for t in body):
                bad = True
                break
            text = re.sub(r"\s*\n\s*", " ", "".join(t.text for t in body)).strip()
            pieces.append((lead, text, [t for t in tail if t.kind in ("lcom", "bcom")], body[-1].line))
        if bad:
            continue
        pieces = _keep_trailing_comments(pieces)
        out = []
        for idx, (lead, text, tail, _) in enumerate(pieces):
            for c in lead:
                out.append(base + unit + c.text)
            ln = base + unit + text + ("," if idx < len(pieces) - 1 else "")
            for c in tail:
                ln += " " + c.text
            out.append(ln)
        edits.append((hs, pc + 1, "#(\n" + "\n".join(out) + "\n" + base + ")"))
    if not edits:
        return src
    offs, acc = [], 0
    for t in toks:
        offs.append(acc); acc += len(t.text)
    offs.append(acc)
    res, last = [], 0
    for s, e, new in sorted(edits):
        if offs[s] < last:
            continue
        res.append(src[last:offs[s]]); res.append(new); last = offs[e]
    res.append(src[last:])
    return "".join(res)


def process(path, unit_override=None):
    src = open(path, encoding="utf-8").read()
    toks = lex(src)
    lines = split_lines(toks)
    unit = unit_override or detect_unit(lines)
    report = []
    new = "\n".join(rule1(lines, unit, report, path))
    new = rule2(new, unit)
    new = rule3(new, unit)
    if new == src:
        return src, src, report
    # code tokens must be identical and in order; comments identical (a trailing one may move up)
    new_toks = lex(new)
    code = lambda ts: [t.text for t in ts if t.sig()]
    notes = lambda ts: sorted(t.text for t in ts if t.kind in ("lcom", "bcom"))
    if code(toks) != code(new_toks) or notes(toks) != notes(new_toks):
        report.append(f"{path}: NOT CHANGED - token check failed (formatter bug), please report")
        return src, src, report
    return src, new, report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    files = a.files or subprocess.run(["git", "ls-files", "*.sv", "*.svh"], capture_output=True,
                                      text=True, check=True).stdout.split()
    changed, reports = [], []
    for f in files:
        src, new, rep = process(f)
        reports += rep
        if new != src:
            changed.append(f)
            if not a.check:
                with open(f, "w", encoding="utf-8") as fh:
                    fh.write(new)
    for r in reports:
        print(r, file=sys.stderr)
    for f in changed:
        print(f"{'would change' if a.check else 'changed'}: {f}")
    print(f"{'would change' if a.check else 'changed'} {len(changed)} of {len(files)} files")
    sys.exit(1 if a.check and changed else 0)


if __name__ == "__main__":
    main()
