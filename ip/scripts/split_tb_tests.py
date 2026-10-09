#!/usr/bin/env python3
# ***************
# Filename: split_tb_tests.py
# Author: FPGA Cores 4 U
# Description: Moves the test tasks of every testbench into their own file.
#   For a testbench <dir>/<name>_tb.sv (or <dir>/tb_<name>.sv) the
#   module-level tasks, each with the comment block directly above it (its
#   description), are moved to <dir>/tests/<name>_tests.sv, and the
#   testbench gets
#       `include "<name>_tests.sv"
#   where its last task was, so every signal / variable the tasks use is
#   still declared before them. The simulation flows add <dir>/tests to the
#   include path (-I / +incdir+). Tasks inside classes or generate blocks
#   stay in the testbench, and testbenches whose tasks sit inside `ifdef
#   blocks are left alone (reported).
#   Testbenches without tasks, and files already split, are skipped, so the
#   script can be re-run.
# Date: 2026-10-08
# ***************
"""Usage: python3 ip/scripts/split_tb_tests.py [--dry-run] [tb files...]"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DIGITAL_IP = Path(__file__).resolve().parents[2]

TASK_RE = re.compile(r"^\s*(?:(?:static|automatic|virtual|protected|local)\s+)*task\b")
ENDTASK_RE = re.compile(r"\bendtask\b")
TASK_NAME_RE = re.compile(r"\btask\s+(?:(?:automatic|static)\s+)?(?:[\w:\[\]\s]+?\s+)?(\w+)\s*[(;]")
DECL_RE = re.compile(r"^\s*(?:logic|bit|int|integer|longint|shortint|byte|real|reg|wire|string|\w+_t)\b[^()]*;\s*(//.*)?$")
PP_OPEN = re.compile(r"^\s*`(ifdef|ifndef)\b")
PP_CLOSE = re.compile(r"^\s*`endif\b")


# Description of common helper tasks that carry no comment of their own
KNOWN = {
    "check": "Counts an error and prints the message when the condition is false",
    "axil_write": "AXI4-Lite write of one register",
    "axil_read": "AXI4-Lite read of one register",
    "wr": "Register write over the bus",
    "rd": "Register read over the bus",
    "ip_configure": "Programs the IP-specific registers before each test (hook of the shared scaler suite)",
    "stream_frame_in": "Streams one input frame into the DUT (AXI4-Stream, tuser = start of frame)",
    "capture_frame_out": "Captures one output frame of the DUT",
    "stream_send": "Sends one AXI4-Stream beat",
    "wait_idle": "Waits until the DUT is idle",
    "wait_done": "Waits until the DUT reports done",
}


def tb_name(path: Path) -> str | None:
    stem = path.stem
    if stem.endswith("_tb"):
        return stem[:-3]
    if stem.startswith("tb_"):
        return stem[3:]
    return None


def find_testbenches() -> list[Path]:
    out = []
    for p in sorted(DIGITAL_IP.rglob("*.sv")) + sorted(DIGITAL_IP.rglob("*.v")):
        if {"build", "sim_out", "tests", ".git"} & set(p.parts):
            continue
        if not re.search(r"/tb(_verilog)?/", p.as_posix()):
            continue
        if tb_name(p):
            out.append(p)
    return out


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("//")


def first_sentence(comment: list[str]) -> str:
    m = re.match(r"\s*//\s*[-=]{2,}\s*(.*?)\s*[-=]*\s*$", comment[0])
    if m and m.group(1):                        # "// ---- heading ----" names the task
        s = m.group(1).rstrip(".;:")
        return s[:1].upper() + s[1:]
    text = " ".join(l.strip().lstrip("/").strip() for l in comment)
    text = re.sub(r"-{3,}|={3,}", " ", text).strip()
    text = re.sub(r"\s+", " ", text)
    m = re.match(r"(.+?[.;:])(\s|$)", text)
    s = (m.group(1) if m else text).rstrip(".;:")
    return s[:1].upper() + s[1:] if s else ""


def wrap(text: str, width: int, indent: str) -> list[str]:
    lines, cur = [], ""
    for w in text.split():
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}" if cur else w
    if cur:
        lines.append(cur)
    return [indent + l for l in lines]


def module_tasks(lines: list[str], start: int, end: int):
    """Module-level tasks between lines start and end: (first line incl. comment, task line, last line, name,
    comment lines), or a reason string when the module cannot be split."""
    tasks = []
    depth_class = 0
    depth_blk = 0
    pp = 0
    i = start + 1
    while i < end:
        l = lines[i]
        code = l.split("//", 1)[0]
        if PP_OPEN.match(l):
            pp += 1
        elif PP_CLOSE.match(l):
            pp -= 1
        if re.search(r"\bclass\b", code) and not re.search(r"\bendclass\b", code):
            depth_class += 1
        if re.search(r"\bendclass\b", code):
            depth_class -= 1
        if depth_class == 0 and depth_blk == 0 and TASK_RE.match(code):
            j = i
            while j < end and not ENDTASK_RE.search(lines[j].split("//", 1)[0]):
                j += 1
            if pp:
                return f"task at line {i + 1} inside `ifdef: left alone"
            c = i
            while c - 1 > start and is_comment(lines[c - 1]):
                c -= 1
            m = TASK_NAME_RE.search(code)
            detached = None
            if c == i:
                # description above a block of declarations the task uses: move the comment, keep the declarations
                k = i
                while k - 1 > start and not lines[k - 1].strip():
                    k -= 1
                n_decl = 0
                while k - 1 > start and DECL_RE.match(lines[k - 1]) and not is_comment(lines[k - 1]):
                    k -= 1
                    n_decl += 1
                if n_decl and is_comment(lines[k - 1]):
                    cb = k - 1
                    while cb - 1 > start and is_comment(lines[cb - 1]):
                        cb -= 1
                    detached = (cb, k - 1)
            comment = lines[detached[0]:detached[1] + 1] if detached else lines[c:i]
            tasks.append((c, i, j, m.group(1) if m else "?", comment, detached))
            i = j + 1
            continue
        # begin/end and generate nesting: tasks inside a generate block (one copy per instance) stay put
        depth_blk += len(re.findall(r"\b(begin|fork|generate)\b", code))
        depth_blk -= len(re.findall(r"\b(end|join|join_any|join_none|endgenerate)\b", code))
        i += 1
    return tasks


def split(path: Path, dry: bool) -> str:
    name = tb_name(path)
    lines = path.read_text().splitlines(keepends=True)
    inc = f'`include "{name}_tests.sv"'
    if any(inc in l for l in lines):
        return "already split"
    # the module holding the tasks: the testbench itself, or a parameterised test-case module in the same file
    mods = [i for i, l in enumerate(lines) if re.match(r"\s*module\s+\w+", l)]
    if not mods:
        return "no module"
    for start in mods:
        end = next((i for i in range(start, len(lines)) if re.match(r"\s*endmodule\b", lines[i])), len(lines))
        tasks = module_tasks(lines, start, end)
        if isinstance(tasks, str) or tasks:
            break
    if isinstance(tasks, str):
        return tasks
    if not tasks:
        return "no tasks"
    mod = re.match(r"\s*module\s+(\w+)", lines[start]).group(1)

    rel_tb = path.relative_to(path.parent).as_posix()
    tests_dir = path.parent / "tests"
    out_file = tests_dir / f"{name}_tests.sv"

    # ---- tests file
    head = ["// ***************", f"// Filename: {out_file.name}", "// Author: FPGA Cores 4 U"]
    where = (f"the {mod} testbench ({rel_tb})" if name in mod else
             f"{mod}, the test-case module of the {name} testbench ({rel_tb})")
    desc = (f"Test tasks of {where}, moved out of it and `included into that module, so they use its signals, "
            f"parameters and models directly. Tasks, in file order:")
    d = wrap(desc, 72, "//   ")
    first = wrap(desc, 60, "")[0]
    d = ["// Description: " + first] + wrap(desc[len(first):], 72, "//   ")
    head += d
    width = max(len(t[3]) for t in tasks)
    for _, _, _, tname, comment, _ in tasks:
        s = (first_sentence(comment) if comment else "") or KNOWN.get(tname, "")
        body = wrap(s, 70 - width, "") if s else [""]
        head.append(f"//     {tname:<{width}}  {body[0]}".rstrip())
        head += [f"//     {'':<{width}}  {b}" for b in body[1:]]
    head += ["// Date: 2026-10-08", "// ***************", ""]
    body = []
    for c, _, j, _, _, det in tasks:
        chunk = (lines[det[0]:det[1] + 1] if det else []) + lines[c:j + 1]
        if body and body[-1].strip():
            body.append("\n")
        body += chunk
    text = "\n".join(head) + "".join(body)
    if not text.endswith("\n"):
        text += "\n"

    # ---- testbench: drop the tasks, include the file where the last task was
    removed = set()
    note = {}                                   # line -> comment left where a detached description was
    for c, _, j, tname, _, det in tasks:
        removed.update(range(c, j + 1))
        if det:
            removed.update(range(det[0], det[1] + 1))
            ind = re.match(r"\s*", lines[det[0]]).group(0)
            note[det[0]] = f"{ind}// used by task {tname} (tests/{out_file.name})\n"
    last = tasks[-1][0]
    indent = re.match(r"\s*", lines[tasks[-1][1]]).group(0)
    new = []
    for k, l in enumerate(lines):
        if k == last:
            new.append(f"{indent}// test tasks: tests/{out_file.name}\n")
            new.append(f"{indent}{inc}\n")
        if k in note:
            new.append(note[k])
        if k in removed:
            continue
        new.append(l)
    # collapse the blank runs left behind
    tidy = []
    for l in new:
        if not l.strip() and tidy and not tidy[-1].strip():
            continue
        tidy.append(l)
    # header: say where the tasks went (last Description line, before Date)
    for k, l in enumerate(tidy[:40]):
        if re.match(r"//\s*Date\s*:", l):
            tidy.insert(k, f"//   The test tasks are in tests/{out_file.name} (`included).\n")
            break
    if not dry:
        tests_dir.mkdir(exist_ok=True)
        out_file.write_text(text)
        path.write_text("".join(tidy))
    return f"{len(tasks)} tasks -> {out_file.relative_to(DIGITAL_IP)}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("files", nargs="*", type=Path)
    a = ap.parse_args()
    files = [f.resolve() for f in a.files] or find_testbenches()
    for f in files:
        print(f"{f.relative_to(DIGITAL_IP)}: {split(f, a.dry_run)}")


if __name__ == "__main__":
    main()
