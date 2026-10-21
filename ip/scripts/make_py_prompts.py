#!/usr/bin/env python3
# ***************
# Filename: make_py_prompts.py
# Author: FPGA Cores 4 U
# Description: Writes a generation prompt for every Python program of a
#   design or IP, reverse-engineered from its source (the Python counterpart
#   of make_ip_prompts.py): <owner>/docs/python/<name>_prompt.md, where
#   <owner> is the design (image_processing/<design>), the IP directory, or
#   ip/ for the library tools. The prompt lists the runtime (CPython, or the
#   py_core subset for firmware compiled by pyc.py), the project modules and
#   SystemVerilog packages it depends on, its command line, public functions
#   and classes, module constants, the hardware registers it touches, the
#   behaviour text (docstrings) and, when <owner>/docs/python/<name>_reference.md
#   exists, the industry reference check (section 6a, copied verbatim).
#   Usage: python3 ip/scripts/make_py_prompts.py [--only NAME ...] [--dry-run] [PATH ...]
#   (PATH: files or directories; default: image_processing/*, ip/scripts, ip/tools,
#   ip/shared/pymodel, every ip/*/*/tb/python, ip/*/*/tools and ip/*/*/model)
#   Imports resolve to the importing file's folder, its IP's scripts/, tb/scripts/
#   and sw/, then to the Python models (ip/shared/pymodel, every model/ folder)
#   and the IP scripts (ip/*/*/scripts), as the simulations put them on sys.path.
# Date: 2026-10-20
import argparse
import ast
import datetime
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]            # digital_ip/
TODAY = datetime.date.today().isoformat()
GEN = "ip/scripts/make_py_prompts.py"
SKIP_DIRS = {"__pycache__", "build", "sim_out", "obj_dir", ".claude", "work"}
PYC = REPO / "ip/cpu/py_core/tools/pyc.py"


def owner(f: Path) -> Path:
    rel = f.relative_to(REPO)
    if rel.parts[0] == "image_processing":
        if len(rel.parts) > 4 and rel.parts[2] == "ip":            # a design's own sub-IP: ip/<name>/...
            return REPO / rel.parts[0] / rel.parts[1] / "ip" / rel.parts[3]
        return REPO / rel.parts[0] / rel.parts[1]
    if rel.parts[0] == "ip" and len(rel.parts) > 3 and rel.parts[1] not in ("scripts", "tools", "docs"):
        return REPO / "ip" / rel.parts[1] / rel.parts[2]
    return REPO / "ip"


def is_firmware(f: Path, text: str) -> bool:
    """Compiled by pyc.py for py_core: every module of a sw/ or programs/ directory (pyc.py inlines
    them into one image; some only hold constants)."""
    return f.parent.name in ("sw", "programs")


def first_sentence(doc: str) -> str:
    """First sentence; a short label ending in ':' (e.g. 'video_processor firmware:') keeps the next one."""
    doc = " ".join(doc.split())
    m = re.match(r"(.+?[.:])(\s|$)", doc)
    s = m.group(1) if m else doc
    if s.endswith(":") and len(s) < 48 and m:
        m2 = re.match(r"(.+?[.:])(\s|$)", doc[m.end():])
        s += " " + (m2.group(1) if m2 else doc[m.end():])
    return s[:300]


def sig(fn: ast.FunctionDef) -> str:
    a = fn.args
    parts = [x.arg for x in a.posonlyargs + a.args]
    d = len(a.defaults)
    if d:
        for i, dv in enumerate(a.defaults):
            k = len(parts) - d + i
            parts[k] += "=" + ast.unparse(dv)
    if a.vararg:
        parts.append("*" + a.vararg.arg)
    parts += [k.arg + ("=" + ast.unparse(v) if v is not None else "") for k, v in zip(a.kwonlyargs, a.kw_defaults)]
    if a.kwarg:
        parts.append("**" + a.kwarg.arg)
    ret = f" -> {ast.unparse(fn.returns)}" if fn.returns else ""
    return f"{fn.name}({', '.join(parts)}){ret}"


def cli_args(tree: ast.Module) -> list[list[str]]:
    rows = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "add_argument":
            names = [ast.unparse(a).strip("'\"") for a in n.args]
            kw = {k.arg: ast.unparse(k.value) for k in n.keywords if k.arg}
            rows.append([" / ".join(f"`{x}`" for x in names), kw.get("default", ""),
                         kw.get("help", "").strip("'\"").replace("|", "/")])
    return rows


def table(header: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c).replace("\n", " ") for c in r) + " |" for r in rows]
    return "\n".join(out)


def fence(text: str) -> str:
    return "```text\n" + text.strip() + "\n```"


_MODEL_INDEX: dict[str, Path] = {}


def model_index() -> dict[str, Path]:
    """Module name -> file of the Python models and IP scripts (ip/shared/pymodel, */model, ip/*/*/scripts)."""
    if not _MODEL_INDEX:
        for g in ("ip/shared/pymodel/*.py", "ip/*/*/model/*.py", "image_processing/*/model/*.py",
                  "ip/*/*/scripts/*.py"):
            for q in sorted(REPO.glob(g)):
                if not set(q.relative_to(REPO).parts) & SKIP_DIRS:
                    _MODEL_INDEX.setdefault(q.stem, q)
    return _MODEL_INDEX


def local_module(name: str, f: Path) -> Path | None:
    stem = name.split(".")[0]
    for d in (f.parent, f.parent.parent / "scripts", f.parent.parent / "tb" / "scripts", f.parent.parent / "sw"):
        q = d / (stem + ".py")
        if q.is_file():
            return q
    return model_index().get(stem)


def sv_package(name: str, f: Path) -> Path | None:
    hits = [p for p in REPO.glob(f"**/src/{name}.sv") if not set(p.parts) & SKIP_DIRS]
    return hits[0] if hits else None


def users_of(f: Path, files: list[Path]) -> list[str]:
    stem = f.stem
    out = []
    for g in files:
        if g == f:
            continue
        t = g.read_text(encoding="utf-8", errors="replace")
        if re.search(rf"^\s*(from\s+{stem}\s+import|import\s+{stem}\b)", t, re.M):
            out.append(str(g.relative_to(REPO)))
    for g in list(owner(f).glob("**/*.sh")) + list(owner(f).glob("**/Makefile")) + list(owner(f).glob("**/*.mk")):
        if set(g.parts) & SKIP_DIRS:
            continue
        if f.name in g.read_text(encoding="utf-8", errors="replace"):
            out.append(str(g.relative_to(REPO)))
    return sorted(set(out))


def registers(tree: ast.Module, text: str) -> list[list[str]]:
    """mem32[...] accesses per function: the address expressions (register names) read / written."""
    rows = []
    for fn in [n for n in tree.body if isinstance(n, ast.FunctionDef)]:
        rd, wr = set(), set()
        for n in ast.walk(fn):
            if isinstance(n, ast.Subscript) and isinstance(n.value, ast.Name) and n.value.id == "mem32":
                e = ast.unparse(n.slice)
                (wr if isinstance(n.ctx, ast.Store) else rd).add(e)
            if isinstance(n, ast.AugAssign) and isinstance(n.target, ast.Subscript) and \
                    isinstance(n.target.value, ast.Name) and n.target.value.id == "mem32":
                rd.add(ast.unparse(n.target.slice))
        if rd or wr:
            rows.append([f"`{fn.name}`", ", ".join(f"`{x}`" for x in sorted(rd)) or "-",
                         ", ".join(f"`{x}`" for x in sorted(wr)) or "-"])
    return rows


def reference_section(own: Path, name: str) -> list[str]:
    ref = own / "docs" / "python" / f"{name}_reference.md"
    if not ref.is_file():
        return []
    body = re.sub(r"^<!--.*?-->\s*", "", ref.read_text(encoding="utf-8"), flags=re.S).strip()
    return ["## 6a. Industry reference check", "",
            "Comparison of section 6 with published engineering references. Every difference is a "
            "`TODO(REF-...)` written as a prompt for updating the program.", "", body, ""]


def pyc_subset() -> str:
    t = PYC.read_text(encoding="utf-8")
    m = re.search(r"#   Supported subset:\n(.*?)#\s*\n# Usage", t, re.S)
    return "\n".join(l[4:] if l.startswith("#   ") else l.lstrip("#") for l in (m.group(1) if m else "").splitlines())


def prompt(f: Path, files: list[Path]) -> str:
    text = f.read_text(encoding="utf-8")
    tree = ast.parse(text)
    doc = ast.get_docstring(tree) or ""
    if not doc:                                    # header comment block instead of a docstring
        hm = re.search(r"# Description:(.*?)(?:\n# Date|\n[^#])", text, re.S)
        doc = re.sub(r"\n#\s?", "\n", hm.group(1)).strip() if hm else ""
    fw = is_firmware(f, text)
    own = owner(f)
    name = f.stem
    imports = []
    for n in tree.body:
        if isinstance(n, ast.Import):
            imports += [a.name for a in n.names]
        elif isinstance(n, ast.ImportFrom) and n.module:
            imports.append(n.module)
    imports += [n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module and n not in tree.body]
    imports += [a.name for n in ast.walk(tree) if isinstance(n, ast.Import) and n not in tree.body for a in n.names]
    local, pkgs, ext = [], [], []
    for im in sorted(set(imports)):
        lm = local_module(im, f)
        if lm:
            local.append([f"`{im}`", f"`{lm.relative_to(REPO)}`", first_sentence(ast.get_docstring(ast.parse(lm.read_text(encoding='utf-8'))) or "")])
        elif fw and im != "machine" and sv_package(im, f):
            pkgs.append([f"`{im}`", f"`{sv_package(im, f).relative_to(REPO)}`", "SystemVerilog package read by pyc.py (localparams -> constants)"])
        elif im != "machine":
            ext.append(im)
    funcs = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
    classes = [n for n in tree.body if isinstance(n, ast.ClassDef)]
    consts = []
    for n in tree.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) \
                and n.targets[0].id.isupper():
            consts.append([f"`{n.targets[0].id}`", f"`{ast.unparse(n.value)[:80]}`"])
    args = cli_args(tree)
    regs = registers(tree, text) if fw else []
    users = users_of(f, files)
    rel = f.relative_to(REPO)
    L = [f"# {name}: generation prompt (Python)", "",
         f"*Generated by `{GEN}` from `{rel}` on {TODAY}. It follows the structure of "
         "`ip/docs/MODULE_PROMPT_TEMPLATE.md` for software; edit any field before use.*", "",
         "```text", f"Write the Python {'firmware module' if fw else 'program'} {f.name} for the FPGA Cores 4 U "
         f"digital IP library ({own.relative_to(REPO)}).", "```", "",
         "## 1. Identity", "",
         f"- File: `{rel}`",
         f"- Kind: {'py_core firmware (compiled by ip/cpu/py_core/tools/pyc.py into the py_soc flash image)' if fw else 'host program (CPython 3.10+)'}",
         f"- Owner: `{own.relative_to(REPO)}`",
         f"- One-line purpose: {first_sentence(doc) or '(no docstring: add one)'}", "",
         "## 2. Context", "",
         "- Used by: " + (", ".join(f"`{u}`" for u in users) if users else "run directly (no importer found)") + ".",
         "- Project modules it imports (do not duplicate):" + ("" if local or pkgs else " none.")]
    if local or pkgs:
        L += ["", table(["Module", "File", "Description"], local + pkgs)]
    L += ["", "- Third-party / standard library: " + (", ".join(f"`{x}`" for x in sorted(set(ext))) or "none") + ".", "",
          "## 3. Runtime and constraints", ""]
    if fw:
        L += ["Compiled by `pyc.py` for `py_core`; only this subset is allowed (anything else is rejected at "
              "compile time):", "", fence(pyc_subset()), "",
              "- Register addresses come from the SystemVerilog map packages (`from <pkg> import *`), never "
              "hard-coded numbers, so firmware and RTL decoders share one source.",
              "- Every hardware wait has a bound (poll count) and reports a timeout instead of hanging.", ""]
    else:
        L += ["- CPython 3.10 or newer; only the listed third-party packages.",
              "- Command-line tools: argparse, a usage line, non-zero exit status on error, no network access.",
              "- Library style: module docstring, function docstrings, no mutable default arguments, explicit "
              "file encodings.", ""]
    L += ["## 4. Interfaces", ""]
    if args:
        L += ["Command line:", "", table(["Argument", "Default", "Help"], args), ""]
    if funcs:
        L += ["Functions:", "", table(["Signature", "Description"],
              [[f"`{sig(fn)}`", first_sentence(ast.get_docstring(fn) or "")] for fn in funcs]), ""]
    if classes:
        L += ["Classes:", "", table(["Class", "Methods", "Description"],
              [[f"`{c.name}`", ", ".join(f"`{m.name}`" for m in c.body if isinstance(m, ast.FunctionDef)),
                first_sentence(ast.get_docstring(c) or "")] for c in classes]), ""]
    if consts:
        L += ["Module constants:", "", table(["Name", "Value"], consts[:120]), ""]
    if regs:
        L += ["Hardware registers (mem32 address expressions read / written per function):", "",
              table(["Function", "Reads", "Writes"], regs), ""]
    L += ["## 5. Requirements traceability", "",
          ("- Every register access must match the register map of the block it addresses (its "
           "`<ip>/docs/<ip>_prompt.md` section 5/6 and `src/include/<ip>_regs.json`): offset, access type "
           "(RO / RW / W1C / CMD), bit fields and reset values." if fw else
           "- Every file format, protocol or algorithm it implements must match the reference in section 6a."),
          "- Behaviour described below and not covered by a requirement is reported in the review.", "",
          "## 6. Function", "", "Implement exactly this behaviour (from the reference program's documentation):", "",
          fence(doc or "(no module docstring)"), ""]
    fdocs = [f"{fn.name}: {ast.get_docstring(fn)}" for fn in funcs + classes if ast.get_docstring(fn)]
    if fdocs:
        L += ["Per function:", "", fence("\n\n".join(fdocs)), ""]
    L += reference_section(own, name)
    L += ["## 7. Verification", "",
          ("- Builds with `pyc.py` without errors and runs in the design simulation "
           "(`scripts/run_sim.sh`); the UART transcript shows every step passing." if fw else
           "- A self-test or example run documented in the docstring; the program's outputs are checked by "
           "the design's tests that use them."),
          "- `python3 -m py_compile` clean; review per CLAUDE.md (Python checklist) with no findings.", "",
          "## 8. Report back", "",
          "Files changed, the requirement each change satisfies, test results, and any requirement that "
          "could not be met.", ""]
    return "\n".join(L)


def discover(paths: list[str]) -> list[Path]:
    roots = [REPO / p for p in paths] if paths else (
        sorted((REPO / "image_processing").glob("*")) + [REPO / "ip/scripts", REPO / "ip/tools"] +
        [REPO / "ip/shared/pymodel"] + sorted((REPO / "ip").glob("*/*/model")) +
        sorted((REPO / "ip").glob("*/*/tb/python")) + sorted((REPO / "ip").glob("*/*/tools")) +
        sorted((REPO / "ip").glob("*/*/scripts")) + sorted((REPO / "ip").glob("*/*/tb/programs")))
    out = []
    for r in roots:
        cand = ([r] if r.suffix == ".py" else []) if r.is_file() else r.rglob("*.py")   # not .DS_Store etc.
        for f in cand:
            if set(f.relative_to(REPO).parts) & SKIP_DIRS or f.name.startswith("__"):
                continue
            out.append(f)
    return sorted(set(out))


def main() -> None:
    ap = argparse.ArgumentParser(description="Write docs/python/<name>_prompt.md for every Python program.")
    ap.add_argument("paths", nargs="*", help="files or directories (default: all)")
    ap.add_argument("--only", nargs="*", help="limit to these program names (file stems)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    files = discover(a.paths)
    allpy = discover([])
    n = 0
    for f in files:
        if a.only and f.stem not in a.only:
            continue
        try:
            text = prompt(f, allpy)
        except SyntaxError as e:
            print(f"skip {f.relative_to(REPO)}: {e}")
            continue
        out = owner(f) / "docs" / "python" / f"{f.stem}_prompt.md"
        print(out.relative_to(REPO))
        if not a.dry_run:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text, encoding="utf-8")
        n += 1
    print(f"{n} prompt files" + (" (dry run)" if a.dry_run else ""))


if __name__ == "__main__":
    main()
