#!/usr/bin/env python3
# ***************
# Filename: make_system_prompt.py
# Author: FPGA Cores 4 U
# Description: Interactive builder for a system-generation prompt (see
#   ip/docs/SYSTEM_PROMPT_TEMPLATE.md). It asks for the system's goal,
#   target, features and interfaces, shows the existing library IP (catalog
#   + every ip/<category>/<name>/src + image_processing designs) so the user
#   can choose what to reuse, works out which functions the chosen features
#   need, and for every function that no existing module provides asks how
#   to get it (new library module, vendor IP, third-party core, simulation
#   stub, or drop it). It writes a complete Markdown prompt.
# Date: 2026-10-08
# ***************
"""Build a system-generation prompt from the library catalog and your answers.

Usage:
  python3 ip/scripts/make_system_prompt.py                     interactive
  python3 ip/scripts/make_system_prompt.py --answers a.json    answers from a file (missing ones are asked,
                                                               or defaulted with --defaults)
  python3 ip/scripts/make_system_prompt.py --defaults ...      take the default for every unanswered question
  python3 ip/scripts/make_system_prompt.py --list              print the existing IP and exit
  python3 ip/scripts/make_system_prompt.py --features          print the feature list and exit
  -o FILE      output (default: system_prompt_<name>.md in the current directory)
  --save-answers FILE   write every answer given, for a repeatable rerun with --answers

Answer keys (JSON): name, purpose, target, location, features (list of feature keys),
custom_functions (list of strings), reuse_add / reuse_remove (lists of module names),
decision.<function> ("new" | "vendor" | "thirdparty" | "stub" | "drop" | "existing:<module>"),
detail.<function>, interfaces_extra, resolution, throughput, clocks, cpu, firmware,
budget, speed, verification, notes.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import textwrap
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

IP_ROOT = Path(__file__).resolve().parents[1]           # digital_ip/ip
REPO = IP_ROOT.parent                                    # digital_ip
SYSTEMS_ROOT = REPO / "image_processing"


# ======================================================================= catalog

@dataclass
class Module:
    name: str
    category: str
    path: Path
    description: str = ""
    catalogued: bool = False
    system: bool = False


def first_sentence(text: str) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s*Version \d+(\.\d+)*\.?", "", text)
    m = re.match(r"(.+?(?<!\be\.g)(?<!\bi\.e)(?<!\betc)[.!?])(\s|$)", text)
    return (m.group(1) if m else text)[:160]


def header_description(src: Path) -> str:
    """The Description: field of a library file header."""
    try:
        lines = src.read_text(encoding="utf-8", errors="replace").splitlines()[:40]
    except OSError:
        return ""
    out, on = [], False
    for line in lines:
        m = re.match(r"\s*//\s*Description:\s*(.*)", line)
        if m:
            on = True
            out.append(m.group(1))
            continue
        if on:
            m = re.match(r"\s*//\s{2,}(.*)", line)
            if not m or re.match(r"\s*//\s*Date:", line):
                break
            out.append(m.group(1))
    return first_sentence(" ".join(out))


def discover() -> dict[str, Module]:
    mods: dict[str, Module] = {}
    csv_path = IP_ROOT / "scripts" / "ips.csv"
    if csv_path.is_file():
        for row in csv.reader(l for l in csv_path.read_text().splitlines() if l and not l.startswith("#")):
            if len(row) >= 3:
                name, cat, top = row[0].strip(), row[1].strip(), row[2].strip()
                d = IP_ROOT / cat / name
                src = d / "src" / f"{top}.sv"
                if not src.is_file():
                    src = d / "src" / f"{name}.sv"
                mods[name] = Module(name, cat, d, header_description(src), catalogued=True)
    for src_dir in sorted(IP_ROOT.glob("*/*/src")):
        d = src_dir.parent
        if d.name in mods or d.parent.name in ("docs", "build", "tools"):
            continue
        src = src_dir / f"{d.name}.sv"
        if not src.is_file():
            continue
        mods[d.name] = Module(d.name, d.parent.name, d, header_description(src))
    if SYSTEMS_ROOT.is_dir():
        for d in sorted(p for p in SYSTEMS_ROOT.iterdir() if (p / "src" / f"{p.name}.sv").is_file()):
            mods[d.name] = Module(d.name, "system", d, header_description(d / "src" / f"{d.name}.sv"), system=True)
    return mods


# ======================================================================= knowledge base
# A function is something the system needs. modules lists the options that can
# provide it, best first; an option "a+b" needs all of its modules. The function
# is provided when any option exists. EXTERNAL functions are never library RTL (PHYs, PLLs, memory
# controllers): they always get a decision, defaulting to vendor IP.

@dataclass
class Function:
    key: str
    label: str
    modules: list[str] = field(default_factory=list)
    external: bool = False
    hint: str = ""


FUNCTIONS = {f.key: f for f in [
    # clocks, resets, control
    Function("pll", "Clock generation (PLL / MMCM)", external=True, hint="vendor clocking wizard; give every output frequency and phase"),
    Function("reset", "Reset synchronisation per clock domain", ["reset_sync", "reset_ctrl"]),
    Function("cpu", "Control processor", ["py_soc"], hint="py_soc runs Python bytecode from SPI flash; a RISC-V core is an alternative"),
    Function("bus", "AXI4-Lite register interconnect", ["axi4_lite_mux", "axi4_lite_decoder"]),
    Function("bus_cdc", "AXI4-Lite clock-domain crossing", ["axi4_lite_cdc"]),
    Function("irq", "Interrupt controller", ["intc"]),
    Function("boot_flash", "SPI NOR flash controller (boot / data)", ["spi_flash_ctrl"]),
    Function("watchdog", "Watchdog timer", ["watchdog"]),
    # low-speed peripherals
    Function("uart", "UART", ["uart"]),
    Function("i2c", "I2C master", ["i2c_master"]),
    Function("spi", "SPI master", ["spi_master"]),
    Function("spi_slave", "SPI slave", ["spi_slave"]),
    Function("gpio", "GPIO", ["gpio"]),
    Function("pwm", "PWM generator", ["pwm"]),
    Function("encoder", "Quadrature encoder decoder", ["quadrature_decoder"]),
    Function("timers", "Timers / timestamps", ["interval_timer", "timestamp_counter", "counter"]),
    Function("sdio", "SD card host", ["sdio_host"]),
    # video in
    Function("dphy_rx", "MIPI D-PHY receiver (analog front end)", external=True, hint="vendor D-PHY RX or resistor network + LVDS inputs; PPI byte interface"),
    Function("csi2_rx", "MIPI CSI-2 receiver (packet layer)", ["csi2_rx+csi2_raw_unpack"]),
    Function("dvp_rx", "Parallel (DVP) camera capture", hint="pclk / href / vsync / data to AXI4-Stream video, tuser = SOF, tlast = EOL"),
    Function("hdmi_rx", "HDMI / DVI receiver (TMDS decode, clock recovery)", hint="TMDS deserialiser + 10b/8b decode + channel alignment; the PHY is usually vendor"),
    Function("isp", "Image signal processor (Bayer to RGB)", ["isp_blc_wb+isp_dpc+isp_demosaic+isp_ccm+isp_gamma+isp_csc", "video_pipeline"]),
    # video processing
    Function("scaler", "Video scaler", ["scaler_bilinear", "scaler_bicubic", "scaler_lanczos", "scaler_polyphase"]),
    Function("lens", "Lens distortion correction", ["vision_system"]),
    Function("filter", "Spatial filters (blur / sharpen / convolution)", ["blur_sharpen", "conv2d_filter"]),
    Function("osd", "On-screen display / overlay (alpha blend, text, cursor)", hint="AXI4-Stream video in/out, overlay plane from memory or a character ROM"),
    Function("csc", "Colour-space conversion", ["isp_csc"]),
    Function("stats", "Image statistics (AE / AWB / histogram)", ["isp_stats"]),
    Function("codec", "Video compression (JPEG / H.264)", hint="usually vendor or third-party IP; define the bitstream output interface"),
    # memory
    Function("ddr", "DDR memory controller and PHY", external=True, hint="vendor memory interface generator; AXI4 slave port"),
    Function("dma", "DMA between AXI4-Stream and memory", ["axis_dma", "dma_engine"]),
    Function("vdma", "Video frame-buffer manager (triple buffering, frame-rate conversion)",
             hint="writes frames with axis_dma, reads the newest complete frame for the display; register-programmed base addresses"),
    Function("ecc", "ECC memory protection", ["ecc_memory_ctrl"]),
    # video out
    Function("vtg", "Video timing generator and stream-to-video", ["vid_timing_gen+axis_to_video"]),
    Function("hdmi_tx", "HDMI / DVI transmitter", ["hdmi_tx"]),
    Function("tmds_phy", "TMDS serialiser / output buffers", ["tmds_serializer"], hint="OSERDES + OBUFDS above ~100 MHz pixel clock"),
    Function("lvds_tx", "LVDS (OpenLDI) panel transmitter", ["lvds_tx+lvds_serializer"]),
    Function("dsi_tx", "MIPI DSI transmitter", ["dsi_tx"]),
    Function("csi2_tx", "MIPI CSI-2 transmitter", ["csi2_tx"]),
    Function("dphy_tx", "MIPI D-PHY transmitter (analog)", external=True, hint="vendor D-PHY TX; PPI byte interface"),
    Function("dp_tx", "DisplayPort transmitter", hint="main link (8b/10b or 128b/132b), AUX channel, link training; GT transceiver is vendor"),
    # comms
    Function("eth_mac", "Ethernet MAC", ["eth_mac_if"]),
    Function("eth_phy", "Ethernet PHY (RGMII / SGMII)", external=True, hint="external PHY chip; RGMII/SGMII adapter may be vendor IP"),
    Function("udp", "UDP/IP offload (ARP, ICMP, UDP)", hint="AXI4-Stream payload in/out, register-programmed MAC/IP/port"),
    Function("usb_fs", "USB full-speed device", ["usb_fs_sie"]),
    Function("usb_hs", "USB 2.0 high-speed (ULPI)", hint="ULPI PHY link layer; external USB3300-class PHY"),
    Function("pcie", "PCIe endpoint (transaction layer)", ["pcie_tl_ep"]),
    Function("pcie_phy", "PCIe PHY / hard block", external=True, hint="vendor PCIe hard IP"),
    Function("can", "CAN 2.0 / CAN FD controller", hint="bit timing, arbitration, CRC, error counters, FIFOs, AXI4-Lite"),
    # audio, DSP, integrity, security
    Function("i2s", "I2S audio", ["i2s"]),
    Function("dsp", "DSP blocks (FIR / CIC / NCO / CORDIC)", ["fir", "cic", "nco", "dds", "cordic", "mac"]),
    Function("crc", "CRC / checksums", ["crc32", "crc16", "crc8", "checksum"]),
    Function("aes", "AES encryption", hint="AES-128/256, AXI4-Stream, key via AXI4-Lite; state the mode (CTR, GCM ...)"),
    Function("sha", "SHA-256 hashing", hint="AXI4-Stream message in, digest via AXI4-Lite"),
]}


def option_parts(option: str) -> list[str]:
    return option.split("+")


def option_exists(option: str, mods) -> bool:
    return all(m in mods for m in option_parts(option))


@dataclass
class Feature:
    key: str
    label: str
    functions: list[str]
    interfaces: list[tuple[str, str, str, str]]   # (interface, standard / pins, direction, notes)


FEATURES = {f.key: f for f in [
    Feature("cpu", "Control CPU with firmware",
            ["cpu", "bus", "irq", "boot_flash", "watchdog", "reset"],
            [("SPI flash", "SPI NOR: sclk, cs_n, mosi, miso", "out/in", "firmware image")]),
    Feature("debug_uart", "Console / host UART", ["uart"], [("UART", "txd, rxd", "out/in", "115200 8N1 default")]),
    Feature("i2c", "I2C bus (sensors, EEPROM, PMIC, DDC)", ["i2c"], [("I2C", "scl, sda (open drain)", "inout", "")]),
    Feature("spi", "SPI peripherals", ["spi"], [("SPI", "sclk, mosi, miso, cs_n", "out/in", "")]),
    Feature("gpio", "GPIO, LEDs, buttons", ["gpio"], [("GPIO", "width TBD", "inout", "")]),
    Feature("motor", "Motor control (PWM + encoder)", ["pwm", "encoder", "timers"],
            [("PWM", "outputs TBD", "out", ""), ("Encoder", "A, B, index", "in", "")]),
    Feature("sd", "SD card storage", ["sdio"], [("SD", "clk, cmd, dat[3:0]", "inout", "")]),
    Feature("mipi_camera", "MIPI CSI-2 camera input", ["dphy_rx", "csi2_rx", "isp", "stats", "i2c"],
            [("MIPI CSI-2 RX", "1-4 data lanes + clock lane (D-PHY)", "in", "RAW8/RAW10"),
             ("Camera control", "I2C (CCI), reset, power-down GPIO", "out", "")]),
    Feature("dvp_camera", "Parallel (DVP) camera input", ["dvp_rx", "isp", "i2c"],
            [("DVP", "pclk, href, vsync, d[7:0..11:0]", "in", "")]),
    Feature("hdmi_in", "HDMI / DVI input", ["hdmi_rx", "i2c"],
            [("HDMI RX", "3 TMDS pairs + clock, DDC, HPD", "in", "")]),
    Feature("scaler", "Video scaling", ["scaler"], []),
    Feature("lens", "Lens distortion correction", ["lens"], []),
    Feature("filter", "Blur / sharpen filtering", ["filter"], []),
    Feature("osd", "On-screen display / overlay", ["osd"], []),
    Feature("framebuffer", "DRAM frame buffer (frame-rate conversion)", ["ddr", "dma", "vdma"],
            [("DDR", "DDR3/DDR4/LPDDR, width TBD", "inout", "vendor controller")]),
    Feature("codec", "Video compression", ["codec"], []),
    Feature("hdmi_out", "HDMI / DVI output", ["vtg", "hdmi_tx", "tmds_phy"],
            [("HDMI TX", "3 TMDS pairs + clock, DDC, HPD", "out", "")]),
    Feature("lvds_out", "LVDS panel output", ["vtg", "lvds_tx"], [("LVDS", "4 data + clock pairs per link", "out", "single/dual link")]),
    Feature("dsi_out", "MIPI DSI panel output", ["vtg", "dsi_tx", "dphy_tx"], [("MIPI DSI", "1-4 lanes (D-PHY)", "out", "")]),
    Feature("csi2_out", "MIPI CSI-2 output to a processor", ["vtg", "csi2_tx", "dphy_tx"], [("MIPI CSI-2 TX", "1-4 lanes (D-PHY)", "out", "")]),
    Feature("dp_out", "DisplayPort output", ["vtg", "dp_tx"], [("DisplayPort", "1-4 lanes + AUX, HPD", "out", "")]),
    Feature("ethernet", "Ethernet (UDP streaming / control)", ["eth_mac", "eth_phy", "udp", "crc"],
            [("Ethernet", "RGMII / SGMII + MDIO", "inout", "")]),
    Feature("usb", "USB device (full speed)", ["usb_fs"], [("USB", "D+, D-", "inout", "")]),
    Feature("usb_hs", "USB 2.0 high-speed", ["usb_hs"], [("ULPI", "12 pins to the USB PHY", "inout", "")]),
    Feature("pcie", "PCIe endpoint", ["pcie", "pcie_phy"], [("PCIe", "lanes TBD, refclk, PERST#", "inout", "")]),
    Feature("can", "CAN bus", ["can"], [("CAN", "tx, rx to a transceiver", "out/in", "")]),
    Feature("audio", "Audio (I2S)", ["i2s"], [("I2S", "bclk, lrclk, sdata", "inout", "")]),
    Feature("dsp", "Signal processing (FIR, NCO, CORDIC)", ["dsp"], []),
    Feature("security", "Encryption / authentication", ["aes", "sha"], []),
    Feature("ecc", "ECC-protected memory", ["ecc"], []),
]}

DECISIONS = {
    "new": "create a new library module (use ip/docs/MODULE_PROMPT_TEMPLATE.md for it)",
    "vendor": "use vendor IP behind a thin technology-independent wrapper (black box in synthesis, behavioural model in simulation)",
    "thirdparty": "use a third-party / open-source core (give its name and licence)",
    "stub": "simulation stub only for now (same interface, behavioural model); the real block comes later",
    "drop": "leave it out (remove the dependent feature)",
}


# ======================================================================= questions

class Asker:
    def __init__(self, answers: dict, defaults: bool):
        self.answers, self.defaults, self.given = answers, defaults, {}

    def _input(self, prompt: str) -> str:
        try:
            return input(prompt)
        except EOFError:
            return ""

    def text(self, key: str, question: str, default: str = "") -> str:
        if key in self.answers:
            v = self.answers[key]
        elif self.defaults:
            v = default
        else:
            d = f" [{default}]" if default else ""
            v = self._input(f"\n{question}{d}\n> ").strip() or default
        self.given[key] = v
        return v

    def choose(self, key: str, question: str, options: list[tuple[str, str]], default: str) -> str:
        if key in self.answers:
            v = self.answers[key]
        elif self.defaults:
            v = default
        else:
            print(f"\n{question}")
            for i, (k, label) in enumerate(options, 1):
                print(f"  {i}) {label}{'  (default)' if k == default else ''}")
            while True:
                raw = self._input("> ").strip()
                if not raw:
                    v = default
                    break
                if raw.isdigit() and 1 <= int(raw) <= len(options):
                    v = options[int(raw) - 1][0]
                    break
                if any(raw == k or raw.startswith(k + ":") for k, _ in options):
                    v = raw
                    break
                print("  enter a number from the list")
        self.given[key] = v
        return v

    def multi(self, key: str, question: str, options: list[tuple[str, str]], default: list[str]) -> list[str]:
        if key in self.answers:
            v = list(self.answers[key])
        elif self.defaults:
            v = list(default)
        else:
            print(f"\n{question}")
            for i, (k, label) in enumerate(options, 1):
                print(f"  {i:2d}) {label}")
            raw = self._input("numbers or keys, separated by spaces or commas (empty = none)\n> ").strip()
            v = []
            for tok in re.split(r"[,\s]+", raw):
                if tok.isdigit() and 1 <= int(tok) <= len(options):
                    v.append(options[int(tok) - 1][0])
                elif any(tok == k for k, _ in options):
                    v.append(tok)
        self.given[key] = v
        return v

    def names(self, key: str, question: str) -> list[str]:
        raw = self.text(key, question, "")
        if isinstance(raw, list):
            return raw
        return [t for t in re.split(r"[,\s]+", raw) if t]


# ======================================================================= prompt

def md_table(header: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(c.replace("|", "\\|") for c in r) + " |" for r in rows]
    return "\n".join(out)


def build(ask: Asker, mods: dict[str, Module]) -> str:
    today = date.today().isoformat()
    print("System prompt builder: answer each question (Enter takes the default in brackets).")

    # ---- 1. identity
    name = ask.text("name", "System (top module) name, lower_snake_case:", "my_system")
    purpose = ask.text("purpose", "What does the system do? One or two sentences:", "TBD")
    target = ask.text("target", "Target device / board (or 'not selected'):", "not selected (technology independent)")
    location = ask.text("location", "Design directory (relative to digital_ip/):", f"image_processing/{name}")

    # ---- 2. features
    feats = ask.multi("features", "Which features does the system need?",
                      [(f.key, f.label) for f in FEATURES.values()], ["cpu", "debug_uart"])
    feats = [f for f in feats if f in FEATURES]
    custom = ask.names("custom_functions", "Other functions not in the list (comma-separated, empty for none):")

    needed: dict[str, list[str]] = {}                   # function -> features that need it
    for fk in feats:
        for fn in FEATURES[fk].functions:
            needed.setdefault(fn, []).append(FEATURES[fk].label)
    if any(k in feats for k in ("hdmi_out", "lvds_out", "dsi_out", "csi2_out", "dp_out", "mipi_camera", "hdmi_in")):
        needed.setdefault("pll", []).append("video clocks")
    if "cpu" in feats:
        needed.setdefault("bus_cdc", []).append("CPU and video in different clock domains")
    needed.setdefault("reset", []).append("every clock domain")
    for c in custom:
        key = "custom:" + c
        FUNCTIONS[key] = Function(key, c)
        needed[key] = ["user request"]

    # ---- 3. existing IP: proposed from the features, then user edits
    # One module per function (the first listed that exists); the others are alternatives.
    proposed: dict[str, str] = {}                       # module -> role
    alternatives: dict[str, list[str]] = {}             # module -> other options for the same function
    for fn, users in needed.items():
        f = FUNCTIONS[fn]
        have = [o for o in f.modules if option_exists(o, mods)]
        if have:
            for m in option_parts(have[0]):
                proposed.setdefault(m, f.label)
            first = option_parts(have[0])[0]
            for o in have[1:]:
                if o not in alternatives.setdefault(first, []):
                    alternatives[first].append(o)
    print("\nExisting IP proposed for these features (alternatives in brackets):")
    for m, role in proposed.items():
        alt = f"  [{', '.join(alternatives.get(m, []))}]" if alternatives.get(m) else ""
        print(f"  {m:24s} {mods[m].category:12s} {role}{alt}")
    add = ask.names("reuse_add", "Other existing modules to use, e.g. an alternative above (names, see --list; empty for none):")
    remove = ask.names("reuse_remove", "Proposed modules NOT to use (names; empty for none):")
    for m in add:
        if m in mods:
            proposed.setdefault(m, "requested by the user")
        else:
            print(f"  note: '{m}' is not in the library; it will be treated as a missing function")
            key = "custom:" + m
            FUNCTIONS[key] = Function(key, f"{m} (named by the user, not in the library)")
            needed[key] = ["user request"]
    for m in remove:
        proposed.pop(m, None)

    # ---- 4. missing functions and decisions
    missing_rows, decision_notes = [], []
    for fn, users in needed.items():
        f = FUNCTIONS[fn]
        have = [o for o in f.modules if all(m in proposed for m in option_parts(o))]
        if have and not f.external:
            continue
        default = "vendor" if f.external else "new"
        options = [(k, v) for k, v in DECISIONS.items()]
        unused = [o for o in f.modules if option_exists(o, mods)]
        options += [(f"existing:{o}", f"use existing {o.replace('+', ' + ')}") for o in unused]
        why = "external / analog function, never library RTL" if f.external else "no existing module provides it"
        hint = f" Hint: {f.hint}." if f.hint else ""
        d = ask.choose(f"decision.{fn}", f"Missing: {f.label} (needed by {', '.join(sorted(set(users)))}; {why}).{hint}\n"
                       "How should it be provided?", options, default)
        if d.startswith("existing:"):
            for m in option_parts(d.split(":", 1)[1]):
                proposed[m] = f.label
            continue
        detail_q = {"vendor": "Vendor IP name / configuration (e.g. 'Xilinx MIG DDR4, AXI4 512-bit'):",
                    "thirdparty": "Core name, source and licence:",
                    "new": "Key requirements for the new module (interfaces, performance), or empty:",
                    "stub": "What the stub must model, or empty:",
                    "drop": "Reason, or empty:"}[d]
        detail = ask.text(f"detail.{fn}", detail_q, f.hint if d == "new" else "")
        missing_rows.append([f.label, ", ".join(sorted(set(users))), d, detail or "-"])
        decision_notes.append((f.label, d, detail))

    # ---- 5. interfaces, performance, control
    iface_rows = []
    for fk in feats:
        for iface, std, direction, note in FEATURES[fk].interfaces:
            iface_rows.append([iface, std, direction, note or "-"])
    extra = ask.text("interfaces_extra", "Other external interfaces or pin constraints (free text, empty for none):", "")
    resolution = ask.text("resolution", "Video format(s), e.g. '1920x1080p60 RGB888' (or 'n/a'):",
                          "1920x1080p60, 24-bit RGB" if any(k in feats for k in ("hdmi_out", "lvds_out", "mipi_camera", "hdmi_in")) else "n/a")
    throughput = ask.text("throughput", "Throughput / latency requirements:", "real time, 1 pixel per clock, latency in lines not frames")
    clocks = ask.text("clocks", "Clock domains (name and frequency), or 'derive':", "derive from the interfaces")
    cpu = ask.text("cpu", "Control processor:", "py_soc (Python bytecode, boots from SPI flash)" if "cpu" in feats else "none (host writes registers)")
    firmware = ask.text("firmware", "Firmware / software deliverable:", "start-up firmware that configures every block and reports status"
                        if "cpu" in feats else "register programming sequence in the README")
    budget = ask.text("budget", "Resource budget (LUTs / DSP / BRAM) or 'none':", "none, report utilisation")
    speed = ask.text("speed", "Timing target:", "pixel clock of the chosen video format; logic depth ~10")
    verification = ask.choose("verification", "Verification depth:",
                              [("full", "system testbench with firmware, board models and end-to-end image checks"),
                               ("smoke", "smoke test of the top-level wiring only"),
                               ("none", "RTL only")], "full")
    notes = ask.text("notes", "Anything else the generator must know (empty for none):", "")

    # ---- prompt
    reuse_rows = [[m, mods[m].category, role, mods[m].description or "-",
                   ", ".join(a.replace("+", " + ") for a in alternatives.get(m, []) if a not in proposed) or "-",
                   str(mods[m].path.relative_to(REPO))] for m, role in proposed.items()]
    feature_list = "\n".join(f"- {FEATURES[f].label}" for f in feats) or "- (none selected)"
    custom_list = "\n".join(f"- {c}" for c in custom)
    decision_text = "\n".join(f"- **{label}** - {DECISIONS[d]}" + (f": {detail}" if detail else "") for label, d, detail in decision_notes) or "- none: every function is provided by existing IP"
    verif = {
        "full": textwrap.dedent("""\
            - A system testbench in `tb/` with board models (camera / link sources, display / link sinks that
              decode the real output, flash with the firmware image, I2C devices, ...).
            - Nothing is programmed by the testbench if there is a CPU: the firmware boots and configures the system.
            - End-to-end checks: every output compared with an independent reference model, pixel or byte exact
              (state any tolerance and why).
            - Run the test in every interface configuration (`define on and off).
            - Random gaps and back-pressure on internal streams where the models allow it.
            - Mutation check: break one connection or setting and show the test fails.
            - The library regressions of any IP you changed still pass."""),
        "smoke": "- A smoke testbench: reset release, register access to every block, one frame or packet end to end.",
        "none": "- No testbench; state what was not verified.",
    }[verification]

    return f"""# System generation prompt: {name}

*Generated by ip/scripts/make_system_prompt.py on {today}. Edit any section before use.*

Create a complete FPGA / ASIC system for the FPGA Cores 4 U digital IP library, built from the
existing library IP wherever possible.

## 1. Identity and goal

- Top module: `{name}`
- Location: `digital_ip/{location}/`
- Purpose: {purpose}
- Target: {target}

## 2. Features

{feature_list}
{custom_list}

## 3. External interfaces

{md_table(["Interface", "Standard / pins", "Direction", "Notes"], iface_rows) if iface_rows else "(none from the features)"}

{("Additional: " + extra) if extra else ""}

For every interface: the top-level ports, their clock, the `define that includes it, and which
module drives it. Analog / high-speed PHYs are vendor parts outside the technology-independent
top: expose their parallel (PPI / SerDes / PHY) interface as ports and document the board wrapper.

## 4. Existing IP to reuse

Use these modules unchanged where possible. If one must change, keep the change backward compatible
(default off, existing tests still pass) and report it.

{md_table(["Module", "Category", "Role in this system", "Description", "Alternatives", "Location"], reuse_rows) if reuse_rows else "(none)"}

## 5. Functions not in the library and how to provide them

{md_table(["Function", "Needed by", "Decision", "Details"], missing_rows) if missing_rows else "Every required function is provided by existing IP."}

{decision_text}

Rules: a **new** module follows ip/docs/MODULE_PROMPT_TEMPLATE.md and is delivered with its own
testbench before it is integrated; **vendor** and **third-party** blocks sit behind a wrapper
with the interface stated above, are black boxes in synthesis, and get a behavioural model for
simulation; **stub** blocks have the real interface and a behavioural model only, listed as open
work in the report.

If, while designing, you find another function that is needed and not in the library (or not in
the tables above), stop and ask which option to use (new / vendor / third-party / stub / drop)
before continuing.

## 6. Architecture

- Data path: draw the chain from inputs to outputs using the module names above, with the stream
  format (width, tuser / tlast meaning) on every arrow and where each clock-domain crossing is.
- Control plane: one AXI4-Lite register space ({cpu}). Propose an address map
  (one window per block, in a table) and the interrupt list.
- Every optional block or interface is selected by a `define in `src/configuration.sv` (compiled
  first); excluded blocks have no ports or logic; a BUILD_CFG register reports what was built.
- Frame / packet boundaries: configuration changes take effect at the next frame or packet start.
- State explicitly where data can be dropped (rate mismatch, overflow), how it is counted, and how
  the system recovers without a reset.

## 7. Clocks, resets and performance

- Clock domains: {clocks}. List every domain, its frequency and source.
- Resets: one `reset_sync` per domain from a single asynchronous reset input.
- Crossings only through library synchronisers (`async_fifo`, `axis_async_bridge`, `axi4_lite_cdc`,
  `pulse_sync`, `bit_sync`, `toggle_sync`).
- Video format: {resolution}
- Throughput / latency: {throughput}
- Timing target: {speed}
- Resource budget: {budget}

## 8. Control processor and firmware

- Processor: {cpu}
- Firmware: {firmware}
- The firmware brings the system up the way a product would (release external devices from reset,
  configure them over I2C / SPI, program every block, enable interrupts, report status on a GPIO /
  UART) and checks for errors.

## 9. Implementation constraints

- Synthesizable SystemVerilog-2012, technology independent; vendor primitives only inside wrappers.
- Must work in iverilog 12+ (-g2012), Verilator lint (-Wall, no combinational loops or latches) and
  Yosys (sv2v where needed). Respect the iverilog limits: declare before use, no enum ternaries
  without casts, no `break`, no `wait` on functions, no queues in arrays, no declarations inside
  nested loops of static initial blocks.
- AXI4-Stream everywhere for data, AXI4-Lite for control; honour back-pressure, valid never depends
  on ready; a block that cannot be stalled must be documented and protected (FIFO, admission control).
- Library file headers (Filename / Author: FPGA Cores 4 U / Description / Date) on every file.

## 10. Deliverables

```text
digital_ip/{location}/
  src/configuration.sv    `defines for every optional block and interface
  src/{name}.sv           top level (+ any glue modules)
  sw/                     firmware (if there is a CPU)
  scripts/build.f         RTL file list, configuration.sv first
  scripts/run_sim.sh      builds the firmware, runs the system test
  tb/                     system testbench + tb/scripts/build.f
  synth/run_yosys.sh      synthesis, reports utilisation
  constraints/            board constraints (placeholder until a board is chosen)
  docs/                   block diagram(s), every block labelled with its library module and instance name
  ci/run_checked.sh, Makefile (sim, lint, synth, diagram, ci), README.md, .gitignore
```

## 11. Verification

{verif}

## 12. Report back

Summarise: the files created, the block diagram, the address map, every change to existing IP
and why, the decisions taken for missing functions, test results (with the mutation check),
synthesis utilisation, and the known limits and open work.
{(chr(10) + "## 13. Notes" + chr(10) + chr(10) + notes + chr(10)) if notes else ""}"""


# ======================================================================= main

def main() -> None:
    ap = argparse.ArgumentParser(description="Build a system-generation prompt.", epilog=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--answers", type=Path, help="JSON file with answers")
    ap.add_argument("--defaults", action="store_true", help="use the default for every unanswered question")
    ap.add_argument("--list", action="store_true", help="list the existing IP and exit")
    ap.add_argument("--features", action="store_true", help="list the features and exit")
    ap.add_argument("-o", "--output", type=Path)
    ap.add_argument("--save-answers", type=Path)
    args = ap.parse_args()

    mods = discover()
    if args.list:
        cat = None
        for m in sorted(mods.values(), key=lambda m: (m.category, m.name)):
            if m.category != cat:
                cat = m.category
                print(f"\n[{cat}]")
            print(f"  {m.name:26s} {m.description}")
        print(f"\n{len(mods)} modules")
        return
    if args.features:
        for f in FEATURES.values():
            needs = []
            for fn in f.functions:
                fx = FUNCTIONS[fn]
                ok = (not fx.external) and any(option_exists(o, mods) for o in fx.modules)
                needs.append(f"{fn}{'' if ok else ('(vendor)' if fx.external else '(missing)')}")
            print(f"  {f.key:12s} {f.label:45s} {' '.join(needs)}")
        return

    answers = json.loads(args.answers.read_text()) if args.answers else {}
    ask = Asker(answers, args.defaults)
    prompt = build(ask, mods)
    name = ask.given.get("name", "system")
    out = args.output or Path(f"system_prompt_{name}.md")
    out.write_text(prompt, encoding="utf-8")
    print(f"\nwrote {out}")
    if args.save_answers:
        args.save_answers.write_text(json.dumps(ask.given, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {args.save_answers}")


if __name__ == "__main__":
    main()
