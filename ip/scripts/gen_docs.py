#!/usr/bin/env python3
"""Generate Markdown and standalone HTML documentation for the root IP catalog."""
from __future__ import annotations

import csv
from html import escape
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
ACCEPTED = {".sv", ".v", ".svh", ".vh", ".f", ".sh"}


def catalog() -> list[tuple[str, str, str]]:
    with (ROOT / "scripts/ips.csv").open(encoding="utf-8", newline="") as source:
        return [(name, category, top) for name, category, top in csv.reader(source)
                if name and not name.startswith("#")]


def manifest_files(module: Path, manifest: str) -> list[Path]:
    path = module / manifest
    if not path.is_file():
        return []
    result = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        entry = raw.split("//", 1)[0].strip()
        if entry and not entry.startswith("+"):
            candidate = module / entry
            if candidate.is_file():
                result.append(candidate)
    return result


def clean_description(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    return " ".join(text.replace("**", "").split())


def scaler_metadata(module: Path) -> tuple[str, str, str]:
    lines = (module / "README.md").read_text(encoding="utf-8").splitlines()
    title = module.name.replace("_", " ").title()
    kind = "IP"
    description = f"SystemVerilog scaler module {module.name}."
    for line in lines:
        if line.startswith("# "):
            title = line[2:].strip()
            break
    for index, line in enumerate(lines):
        match = re.match(r"\*\*Type:\*\*\s*(.+)", line.strip())
        if not match:
            continue
        kind = re.sub(r"`([^`]+)`", r"\1", match.group(1)).strip()
        paragraph = []
        for detail in lines[index + 1:]:
            detail = detail.strip()
            if not detail:
                if paragraph:
                    break
                continue
            if detail.startswith(("#", "**Depends on:**", "- ", "|")):
                if paragraph:
                    break
                continue
            paragraph.append(detail)
        if paragraph:
            description = clean_description(" ".join(paragraph))
        break
    return title, kind, description


def scaler_sources(module: Path) -> list[Path]:
    manifest = module / "src/build.f"
    if not manifest.is_file():
        return sorted(path for path in (module / "src").rglob("*")
                      if path.is_file() and path.suffix in ACCEPTED)
    result = []
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        entry = raw.split("#", 1)[0].strip()
        if entry and not entry.startswith("+"):
            path = module / "src" / entry
            if path.is_file():
                result.append(path)
    return result


def module_info(name: str, category: str, top: str) -> tuple[str, str, list[Path]]:
    module = ROOT / category / name
    if category == "scalers":
        title, _, description = scaler_metadata(module)
        return title, description, scaler_sources(module)
    sources = manifest_files(module, "scripts/build.f")
    top_file = next((path for path in sources if re.search(
        rf"^\s*module\s+(?:automatic\s+|static\s+)?{re.escape(top)}\b",
        path.read_text(encoding="utf-8", errors="replace"), re.MULTILINE)), None)
    title = top.replace("_", " ").title()
    description = f"SystemVerilog IP module {top}."
    if top_file:
        text = top_file.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.startswith("// Filename:"):
                title = line.partition(":")[2].strip().removesuffix(".sv").replace("_", " ").title()
                break
        lines = text.splitlines()
        start = next((i for i, line in enumerate(lines) if "Description:" in line), None)
        if start is not None:
            details = []
            first = lines[start].split("Description:", 1)[1].strip()
            if first:
                details.append(first)
            for line in lines[start + 1:]:
                if "Date:" in line or not line.lstrip().startswith("//"):
                    break
                details.append(line.lstrip()[2:].strip())
            if details:
                description = " ".join(details)
    return title, description, sources


def file_rows(module: Path, files: list[Path], href_prefix: str) -> str:
    if not files:
        return '<p class="quiet">No files listed.</p>'
    rows = []
    for path in files:
        rel = path.relative_to(module).as_posix()
        rows.append(f'<li><a href="{escape(href_prefix, quote=True)}/{escape(rel, quote=True)}">{escape(rel)}</a></li>')
    return '<ul class="file-list">' + "".join(rows) + "</ul>"


def render_module(name: str, category: str, top: str, root_docs_copy: bool = False) -> str:
    module = ROOT / category / name
    title, description, sources = module_info(name, category, top)
    tests = manifest_files(module, "tb/scripts/build.f")
    source_files = [path for path in sources if path.suffix in ACCEPTED]
    if root_docs_copy:
        module_prefix = f"../../{category}/{name}"
        stylesheet = "../site.css"
        catalog = "../index.html"
        readme = "../../README.md"
    else:
        module_prefix = ".."
        stylesheet = "../../../docs/site.css"
        catalog = "../../../docs/index.html"
        readme = "../../../README.md"
    diagram_prefix = f"{module_prefix}/docs/" if root_docs_copy else ""
    if (module / "docs/block_diagram.svg").is_file():
        diagram = f'<a href="{diagram_prefix}block_diagram.svg">SVG diagram</a> · <a href="{diagram_prefix}block_diagram.dot">DOT source</a>'
    elif (module / "docs/block_diagram.dot").is_file():
        diagram = f'<a href="{diagram_prefix}block_diagram.dot">DOT source</a> · <span class="quiet">Install Graphviz to render SVG</span>'
    else:
        diagram = '<span class="quiet">Diagram not generated</span>'
    return f'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="#0a192f">
<meta name="description" content="{escape(description, quote=True)}">
<title>{escape(title)} | Digital IP</title><link rel="stylesheet" href="{stylesheet}">
</head><body>
<header class="topbar"><a class="brand" href="{catalog}">FPGA Cores 4 U / DIGITAL IP / {escape(category.upper())}</a><a href="{readme}">Repository README</a></header>
<main class="shell">
<section class="hero"><p class="eyebrow">{escape(category)} / {escape(name)}</p><h1>{escape(title)}</h1><p class="lede">{escape(description)}</p>
<div class="actions"><code>make -C {escape(category)}/{escape(name)} test</code><code>make -C {escape(category)}/{escape(name)} diagrams</code></div></section>
<section class="content"><article><p class="eyebrow">Implementation</p><h2>RTL sources</h2>{file_rows(module, source_files, module_prefix)}
<h2>Verification</h2>{file_rows(module, tests, module_prefix)}</article>
<aside><p class="eyebrow">Build surface</p><h2>Commands</h2><ul class="targets"><li><code>make test</code> simulation</li><li><code>make yosys</code> synthesis</li><li><code>make docs</code> HTML and Markdown</li><li><code>make diagrams</code> DOT and SVG</li></ul><h2>Diagram</h2><p>{diagram}</p><p><a href="{module_prefix}/scripts/build.f">RTL manifest</a> · <a href="{module_prefix}/tb/scripts/build.f">Testbench manifest</a></p></aside></section>
<footer><a href="{catalog}">All IP modules</a><span>Generated from the catalog and RTL headers.</span></footer>
</main></body></html>
'''


def render_index(rows: list[tuple[str, str, str]]) -> str:
    groups: dict[str, list[tuple[str, str, str]]] = {}
    for row in rows:
        groups.setdefault(row[1], []).append(row)
    sections = []
    for category in sorted(groups, key=str.casefold):
        display_category = category.upper() if category.casefold() in {"cdc", "fifo"} else category.title()
        items = []
        for name, _, top in sorted(groups[category], key=lambda row: row[0].casefold()):
            title, _, _ = module_info(name, category, top)
            module = ROOT / category / name
            contents = []
            if category == "scalers":
                _, kind, _ = scaler_metadata(module)
                if scaler_sources(module):
                    contents.append("RTL")
                if any((module / "tb").glob("*.sv")):
                    contents.append("testbench")
                if (module / "scripts/synth.sh").is_file():
                    contents.append("synthesis")
            else:
                kind = "IP"
                if manifest_files(module, "scripts/build.f"):
                    contents.append("RTL")
                if manifest_files(module, "tb/scripts/build.f"):
                    contents.append("testbench")
                if (module / "scripts/build.f").is_file() and (ROOT / "scripts/synth.ys").is_file():
                    contents.append("synthesis")
            content_text = " + ".join(contents[:2])
            if len(contents) > 2:
                content_text += " · " + " · ".join(contents[2:])
            items.append(f'<tr><td><a href="{escape(name, quote=True)}/index.html">{escape(title)}</a><small>{escape(name)}</small></td><td>{escape(kind)}</td><td><code>{escape(top)}</code></td><td>{escape(content_text)}</td></tr>')
        sections.append(f'<section class="category-group"><div class="section-head"><h2>{escape(display_category)}</h2><span>{len(groups[category])} IPs</span></div><div class="table-wrap"><table><thead><tr><th>IP</th><th>Kind</th><th>Top module</th><th>Contents</th></tr></thead><tbody>{"".join(items)}</tbody></table></div></section>')
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="#0a192f"><meta name="description" content="SystemVerilog IP catalog with source, simulation, diagrams, and generated documentation."><title>Digital IP Catalog | FPGA Cores 4 U</title><link rel="stylesheet" href="site.css"></head>
<body><header class="topbar"><a class="brand" href="index.html">FPGA Cores 4 U / DIGITAL IP CATALOG</a><a href="../README.md">Library guide</a></header><main class="shell">
<section class="hero"><p class="eyebrow">SystemVerilog library · {len(rows)} modules</p><h1>Digital IP</h1><p class="lede">Independent modules, each with local RTL, simulation, build scripts, and generated documentation. The scaler family shares tools and regression support at the library root.</p><div class="actions"><a href="../tools/docs/index.html">Scaler IP catalog</a><a href="../SCALER_README.md">Scaler project README</a></div></section>
<section class="directory"><div class="section-head"><h2>Module directory</h2><span>{len(rows)} IPs</span></div>{''.join(sections)}</section>
<footer><span>Generated by <code>scripts/gen_docs.py</code>.</span><a href="../Makefile">Build targets</a></footer></main></body></html>
'''


def main() -> None:
    rows = catalog()
    DOCS.mkdir(parents=True, exist_ok=True)
    markdown = ["# IP catalog", "", "Generated from `scripts/ips.csv`, RTL headers, and scaler module READMEs.", "",
                "| IP | Category | Top module | Testbench |", "|---|---|---|---|"]
    for name, category, top in rows:
        if category == "scalers":
            testbench = f"../scalers/{name}/tb/{name}_tb.sv"
        else:
            testbench = f"../{category}/{name}/tb/{name}_tb.sv"
        markdown.append(f"| [{name}]({name}/index.html) | {category} | `{top}` | [`{testbench.rsplit('/', 2)[-1]}`]({testbench}) |")
    markdown.append("")
    for name, category, top in rows:
        module = ROOT / category / name
        title, description, sources = module_info(name, category, top)
        markdown.extend([f"## {name}", "", f"**{title}** · category `{category}` · top `{top}`", "", description, "",
                         "Sources: " + ", ".join(f"`{path.relative_to(module).as_posix()}`" for path in sources), "",
                         f"[HTML module page]({name}/index.html)", ""])
        if category != "scalers":
            docs = module / "docs"
            docs.mkdir(exist_ok=True)
            (docs / "index.html").write_text(render_module(name, category, top), encoding="utf-8")
            module_docs = DOCS / name
            module_docs.mkdir(parents=True, exist_ok=True)
            (module_docs / "index.html").write_text(
                render_module(name, category, top, root_docs_copy=True), encoding="utf-8")
    (DOCS / "IP_CATALOG.md").write_text("\n".join(markdown), encoding="utf-8")
    (DOCS / "index.html").write_text(render_index(rows), encoding="utf-8")
    general_pages = sum(category != "scalers" for _, category, _ in rows)
    print(f"gen_docs: {len(rows)} catalog entries, {general_pages} general-IP pages, HTML index, and Markdown catalog generated")


if __name__ == "__main__":
    main()