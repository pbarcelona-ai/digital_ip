#!/usr/bin/env python3
"""Generate source-hierarchy block diagrams from each IP's RTL manifest."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def sources(module: Path) -> list[Path]:
    result = []
    for raw in (module / "scripts/build.f").read_text(encoding="utf-8").splitlines():
        entry = raw.split("//", 1)[0].strip()
        if entry and not entry.startswith("+"):
            path = module / entry
            if path.is_file():
                result.append(path)
    return result


def hierarchy(name: str, category: str, top: str) -> str:
    module = ROOT / category / name
    bodies: dict[str, str] = {}
    for path in sources(module):
        text = path.read_text(encoding="utf-8", errors="replace")
        text = re.sub(r"/\*.*?\*/|//[^\n]*", " ", text, flags=re.DOTALL)
        for match in re.finditer(r"\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_$][\w$]*)\b(.*?)\bendmodule\b", text, re.DOTALL):
            bodies[match.group(1)] = match.group(2)
    types = set(bodies)
    instances: dict[str, list[tuple[str, str]]] = {}
    if types:
        type_pattern = "|".join(re.escape(item) for item in sorted(types, key=len, reverse=True))
        pattern = re.compile(rf"\b({type_pattern})\s*(?:#\s*\(.*?\)\s*)?([A-Za-z_$][\w$]*)\s*(?:\[[^\]]+\]\s*)?\(", re.DOTALL)
        for parent, body in bodies.items():
            instances[parent] = [(match.group(1), match.group(2)) for match in pattern.finditer(body)]

    nodes = ['  n0 [label="' + top + '\\n(top)", style="rounded,filled", fillcolor="#dcefe8", color="#176b59"];']
    edges: list[str] = []
    counter = 0

    def add_children(parent_id: str, module_name: str, stack: tuple[str, ...]) -> None:
        nonlocal counter
        for child, instance in instances.get(module_name, []):
            counter += 1
            child_id = f"n{counter}"
            label = f"{child}\\n({instance})".replace('"', '\\"')
            nodes.append(f'  {child_id} [label="{label}", style="rounded,filled", fillcolor="#f4f6f5", color="#71817a"];')
            edges.append(f"  {parent_id} -> {child_id};")
            if child not in stack:
                add_children(child_id, child, stack + (child,))

    add_children("n0", top, (top,))
    return "\n".join([
        f'digraph "{name}" {{',
        '  graph [rankdir=LR, bgcolor="white", pad=0.25, nodesep=0.35, ranksep=0.65, label="' + name + ' RTL hierarchy", labelloc=t, fontname="Helvetica", fontsize=16];',
        '  node [shape=box, fontname="Helvetica", fontsize=10, margin="0.14,0.08"];',
        '  edge [color="#52635c", arrowsize=0.7];',
        *nodes, *edges, "}", "",
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modules", nargs="*", help="IP names; default is the full catalog")
    parser.add_argument("--dot-only", action="store_true", help="write DOT without requiring Graphviz")
    parser.add_argument("--check", action="store_true", help="fail if a generated DOT file is stale")
    args = parser.parse_args()
    with (ROOT / "scripts/ips.csv").open(encoding="utf-8", newline="") as source:
        catalog = [(name, category, top) for name, category, top in csv.reader(source)
                   if name and not name.startswith("#")]
    selected = set(args.modules)
    general_catalog = [(name, category, top) for name, category, top in catalog if category != "scalers"]
    rows = [(name, category, top) for name, category, top in general_catalog if not selected or name in selected]
    unknown = selected - {name for name, _, _ in general_catalog}
    if unknown:
        parser.error("unknown IP(s): " + ", ".join(sorted(unknown)))
    dot = shutil.which("dot")
    if not args.check and not args.dot_only and not dot:
        print("Graphviz 'dot' is required; use --dot-only to write DOT sources", file=sys.stderr)
        return 2
    stale = []
    for name, category, top in rows:
        docs = ROOT / category / name / "docs"
        docs.mkdir(exist_ok=True)
        target = docs / "block_diagram.dot"
        content = hierarchy(name, category, top)
        if args.check:
            if not target.is_file() or target.read_text(encoding="utf-8") != content:
                stale.append(name)
            continue
        target.write_text(content, encoding="utf-8")
        if not args.dot_only:
            subprocess.run([dot, "-Tsvg", str(target), "-o", str(docs / "block_diagram.svg")], check=True)
    if stale:
        print("stale or missing block diagrams: " + ", ".join(stale), file=sys.stderr)
        return 1
    verb = "checked" if args.check else "generated"
    print(f"{verb} {len(rows)} RTL hierarchy diagram(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())