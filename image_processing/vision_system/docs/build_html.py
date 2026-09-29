#!/usr/bin/env python3
"""Refresh the HTML synthesis dashboard from the Yosys Markdown summary."""
from html import escape
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "docs" / "site"
PAGE = SITE / "synthesis.html"
SUMMARY = ROOT / "synth" / "summary.md"


def report_fragment() -> tuple[str, str]:
    if not SUMMARY.exists():
        return (
            '<div class="callout"><p><strong>No synthesis summary found.</strong></p>'
            '<p>Run <code>make synth</code> from the <code>vision_system</code> '
            'directory to execute <code>synth/run_all_yosys.sh</code>, which uses '
            '<code>summarize.py</code> for utilization and <code>est_timing.py</code> '
            'for timing estimates. Then run <code>make html</code> if you generated '
            'the report another way.</p></div>',
            "SYNTHESIS DATA",
        )

    text = SUMMARY.read_text(encoding="utf-8")
    title = re.search(r"^# Yosys synthesis summary \((.+)\)$", text, re.M)
    target = title.group(1) if title else "Yosys synthesis summary"
    rows = []
    for line in text.splitlines():
        if not line.startswith("|") or line.startswith("|---"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if not cells or cells[0] == "module":
            continue
        if len(cells) < 10:
            continue
        module = cells[0]
        safe_module = escape(module)
        report_path = module.strip("/") + "/yosys/utilization_hier.rpt"
        report_href = "../../" + escape(report_path, quote=True)
        status = cells[9]
        status_class = "status-bad" if "VIOLATED" in status or "FAIL" in status else "status-ok"
        status_text = "VIOLATED" if "VIOLATED" in status else "SYNTH FAIL" if "FAIL" in status else "MET"
        module_cell = f'<a href="{report_href}">{safe_module}</a>'
        rows.append(
            "<tr>"
            f"<td>{module_cell}</td><td>{escape(cells[1])}</td>"
            f"<td>{escape(cells[2])}</td><td>{escape(cells[3])}</td>"
            f"<td>{escape(cells[4])}</td><td>{escape(cells[5])}</td>"
            f"<td>{escape(cells[6])}</td><td>{escape(cells[7])}</td>"
            f"<td>{escape(cells[8])}</td>"
            f'<td><span class="status {status_class}">{status_text}</span></td>'
            "</tr>"
        )

    if not rows:
        fragment = '<div class="callout"><p>The synthesis summary exists but contains no module rows. Re-run <code>make synth</code> to regenerate it.</p></div>'
    else:
        fragment = (
            '<p class="file-link"><a href="../../synth/summary.md">Open raw Markdown summary</a></p>'
            '<div class="table-wrap"><table class="data-table">'
            "<thead><tr><th>Module</th><th>LUT</th><th>FF</th><th>DSP48E1</th>"
            "<th>RAMB36</th><th>RAMB18</th><th>SRL</th><th>Worst path</th>"
            "<th>Slack (ns)</th><th>Timing</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody></table></div>"
            '<p class="quiet">Select a module name to open its raw hierarchical utilization report.</p>'
        )
    return fragment, target


def main() -> None:
    fragment, target = report_fragment()
    page = PAGE.read_text(encoding="utf-8")
    page = re.sub(r'<div id="report">.*?</div>\s*</section>', lambda _: f'<div id="report">{fragment}</div>\n    </section>', page, count=1, flags=re.S)
    page = re.sub(
        r'(<span class="index" id="target">).*?(</span>)',
        lambda match: f"{match.group(1)}{escape(target)}{match.group(2)}",
        page,
        count=1,
        flags=re.S,
    )
    PAGE.write_text(page, encoding="utf-8")
    print(f"[html] refreshed {PAGE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()