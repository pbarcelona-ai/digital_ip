#!/usr/bin/env python3
"""Generate per-module HTML pages and the scaler IP documentation index."""
from __future__ import annotations

from html import escape
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SCALER_ROOT = ROOT / "scalers"
TOOLS_DOCS = ROOT / "tools" / "docs"


def clean_markdown(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = text.replace("**", "").replace("__", "")
    return " ".join(text.split())


def read_metadata(readme: Path) -> tuple[str, str, str, str]:
    lines = readme.read_text(encoding="utf-8").splitlines()
    title = readme.parent.name.replace("_", " ").title()
    for line in lines:
        if line.startswith("# "):
            title = line[2:].strip()
            break

    kind = "IP"
    for line in lines:
        match = re.match(r"\*\*Type:\*\*\s*(.+)", line.strip())
        if match:
            kind = clean_markdown(match.group(1))
            break

    paragraphs: list[str] = []
    current: list[str] = []
    past_type = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("**Type:**"):
            past_type = True
            continue
        if stripped.startswith("# "):
            past_type = True
            continue
        if not past_type:
            continue
        if not stripped:
            if current:
                paragraphs.append(" ".join(current))
                current = []
                if paragraphs:
                    break
            continue
        if stripped.startswith(("**Depends on:**", "- ", "|", "## ")):
            if current:
                paragraphs.append(" ".join(current))
                current = []
            if paragraphs or stripped.startswith("## "):
                break
            continue
        current.append(stripped)
    if current and not paragraphs:
        paragraphs.append(" ".join(current))

    description = clean_markdown(paragraphs[0]) if paragraphs else f"{title} hardware module."
    dependency = ""
    for line in lines:
        match = re.match(r"\*\*Depends on:\*\*\s*(.+)", line.strip())
        if match:
            dependency = clean_markdown(match.group(1))
            break
    return title, kind, description, dependency


def file_links(folder: Path, category: str, page_prefix: str) -> list[tuple[str, str]]:
    directory = folder / category
    if not directory.is_dir():
        return []
    accepted = {".sv", ".v", ".svh", ".vh", ".f", ".sh"}
    items = sorted(path for path in directory.rglob("*") if path.is_file() and path.suffix in accepted)
    result = []
    for path in items:
        relative = path.relative_to(folder).as_posix()
        href = f"{page_prefix}/{escape(relative, quote=True)}"
        result.append((relative, href))
    return result


def top_module_name(module: Path) -> str:
    manifest = module / "src/build.f"
    if manifest.is_file():
        source_paths = []
        for raw in manifest.read_text(encoding="utf-8").splitlines():
            entry = raw.split("#", 1)[0].strip()
            if entry and not entry.startswith("+"):
                path = module / "src" / entry
                if path.is_file():
                    source_paths.append(path)
    else:
        source_dir = module / "src"
        source_paths = sorted(source_dir.rglob("*.sv")) if source_dir.is_dir() else []

    names = []
    for path in source_paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        text = re.sub(r"/\*.*?\*/|//[^\n]*", " ", text, flags=re.DOTALL)
        names.extend(re.findall(r"\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_$][\w$]*)", text))
    names = list(dict.fromkeys(names))
    if module.name in names:
        return module.name
    return ", ".join(names) if names else "Support library"


def render_file_rows(files: list[tuple[str, str]], empty_text: str) -> str:
    if not files:
        return f'<p class="quiet">{escape(empty_text)}</p>'
    return "<ul class=\"file-list\">" + "".join(
        f'<li><a href="{href}">{escape(name)}</a></li>' for name, href in files
    ) + "</ul>"


def module_page(module: Path, modules: list[Path]) -> str:
    title, kind, description, dependency = read_metadata(module / "README.md")
    source_files = file_links(module, "src", "..")
    test_files = file_links(module, "tb", "..")
    include_files = file_links(module, "include", "..")
    scripts = file_links(module, "scripts", "..")
    readme = '<a class="button secondary" href="../README.md">README</a>'
    module_name = module.name
    back = "../../../tools/docs/index.html"
    depends = f'<p class="dependency"><strong>Depends on:</strong> {escape(dependency)}</p>' if dependency else ""
    make_targets = []
    if (module / "Makefile").is_file():
        make_targets.append(f"make -C scalers/{module_name} test")
        if (module / "scripts" / "synth.sh").is_file():
            make_targets.append(f"make -C scalers/{module_name} synth")
    target_text = " · ".join(make_targets) if make_targets else "Shared verification support"

    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="{escape(description, quote=True)}">
  <title>{escape(title)} | Scaler IP</title>
    <link rel="stylesheet" href="../../../tools/docs/site.css">
</head>
<body>
  <header class="topbar"><a class="brand" href="{back}"><span class="brand-mark">S</span><span>SCALER IP / MODULE NOTE</span></a><a class="back-link" href="{back}">All modules <span aria-hidden="true">↗</span></a></header>
  <main class="page-shell">
    <section class="hero">
      <p class="eyebrow">{escape(kind)} / {escape(module_name)}</p>
      <h1>{escape(title)}</h1>
      <p class="lede">{escape(description)}</p>
    <div class="actions">{readme}<span class="command">{escape(target_text)}</span></div>
    </section>
    <section class="content-grid">
      <article class="panel main-panel">
        <p class="eyebrow">RTL source</p>
        <h2>Implementation</h2>
        {render_file_rows(source_files, "No src/ directory was found for this module.")}
        <h2>Verification</h2>
        {render_file_rows(test_files, "No tb/ directory was found for this module.")}
      </article>
      <aside class="panel side-panel">
              <p class="eyebrow">Build surface</p>
        <h2>Scripts &amp; manifests</h2>
        {render_file_rows(scripts, "No scripts/ directory was found for this module.")}
        <h2>Includes</h2>
        {render_file_rows(include_files, "No include/ directory was found for this module.")}
        {depends}
      </aside>
    </section>
    <footer class="page-footer"><a href="{back}">← Back to scaler IP index</a><span>Generated from this module's README and file tree.</span></footer>
  </main>
</body>
</html>
'''


def summary_page(modules: list[Path]) -> str:
    rows = []
    for module in modules:
        title, kind, _, _ = read_metadata(module / "README.md")
        doc_href = f"../../scalers/{escape(module.name, quote=True)}/docs/index.html"
        has_synth = (module / "scripts" / "synth.sh").is_file()
        source_count = len(file_links(module, "src", ".."))
        test_count = len(file_links(module, "tb", ".."))
        flags = "RTL + testbench" if source_count and test_count else "Verification support"
        if has_synth:
            flags += " · synthesis"
        top_module = top_module_name(module)
        rows.append(
            f'<tr><td><a class="module-link" href="{doc_href}">{escape(title)}</a>'
            f'<span class="module-path">{escape(module.name)}</span></td>'
            f'<td><span class="kind">{escape(kind)}</span></td>'
            f'<td><code>{escape(top_module)}</code></td><td>{escape(flags)}</td></tr>'
        )
    count = len(modules)
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Generated index of the scaler IP modules, source code, tests, and build scripts.">
  <title>Scaler IP Atlas</title>
  <link rel="stylesheet" href="site.css">
</head>
<body>
    <header class="topbar"><a class="brand" href="index.html"><span class="brand-mark">S</span><span>SCALER IP / DIRECTORY</span></a><a class="back-link" href="../../SCALER_README.md">Project README <span aria-hidden="true">↗</span></a></header>
  <main class="page-shell">
    <section class="hero index-hero">
      <p class="eyebrow">Hardware library / SystemVerilog</p>
      <h1>Scaler IP<br><em>Atlas</em></h1>
      <p class="lede">Browse {count} module and verification packages, with direct links to RTL, testbenches, includes, and build scripts.</p>
      <div class="metrics"><div><strong>{count:02d}</strong><span>documented modules</span></div><div><strong>RTL</strong><span>source / test / scripts</span></div><div><strong>SV</strong><span>hardware library</span></div></div>
    </section>
    <section class="directory-section">
      <div class="section-heading"><div><p class="eyebrow">Module index</p><h2>Browse the library</h2></div><span class="section-count">{count} pages</span></div>
      <div class="table-wrap"><table>
        <thead><tr><th>Module</th><th>Kind</th><th>Top module</th><th>Contents</th></tr></thead>
        <tbody>{''.join(rows)}</tbody>
      </table></div>
    </section>
    <footer class="page-footer"><span>Generated by <code>tools/generate_docs.py</code>.</span><a href="../../SCALER_README.md">Open the project README ↗</a></footer>
  </main>
</body>
</html>
'''


def main() -> None:
    modules = sorted(
        (path for path in SCALER_ROOT.iterdir() if path.is_dir() and (path / "README.md").is_file()),
        key=lambda path: path.name.casefold(),
    )
    TOOLS_DOCS.mkdir(parents=True, exist_ok=True)
    for module in modules:
        docs = module / "docs"
        docs.mkdir(exist_ok=True)
        (docs / "index.html").write_text(module_page(module, modules), encoding="utf-8")
    (TOOLS_DOCS / "index.html").write_text(summary_page(modules), encoding="utf-8")
    print(f"Generated {len(modules)} module pages and {TOOLS_DOCS / 'index.html'}")


if __name__ == "__main__":
    main()
