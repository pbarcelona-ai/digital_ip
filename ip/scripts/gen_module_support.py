#!/usr/bin/env python3
"""Create each catalog IP's local Makefile and testbench file manifest."""
import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
with (ROOT / "scripts/ips.csv").open(encoding="utf-8", newline="") as source:
    rows = [(name, category) for name, category, _top in csv.reader(source)
            if name and not name.startswith("#")]

generated = 0
for name, category in rows:
    if category == "scalers":
        continue
    module = ROOT / category / name
    (module / "Makefile").write_text(
        f"IP := {name}\ninclude ../../scripts/ip.mk\n", encoding="utf-8")
    test_dir = module / "tb/scripts"
    test_dir.mkdir(parents=True, exist_ok=True)
    entries = [f"tb/{name}_tb.sv"]
    for helper in ("axil_bfm.sv", "axi4_mem_model.sv"):
        if (ROOT / "shared/tb/lib" / helper).is_file():
            entries.append(f"../../shared/tb/lib/{helper}")
    (test_dir / "build.f").write_text("\n".join(entries) + "\n", encoding="utf-8")
    generated += 1

print(f"generated local Makefiles and bench manifests for {generated} general IPs")