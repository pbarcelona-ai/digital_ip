#!/usr/bin/env python3
"""PostToolUse hook: after Claude writes a SystemVerilog, C, C++ or Python
file, tell Claude to review the new version using the guidelines in CLAUDE.md."""
import json
import sys

REVIEW_EXTS = (
    ".sv", ".svh",                                   # SystemVerilog
    ".c", ".h",                                      # C
    ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx",    # C++
    ".py",                                           # Python
)

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool_input = payload.get("tool_input") or {}
tool_response = payload.get("tool_response") or {}
path = tool_input.get("file_path") or tool_response.get("filePath") or ""

if not path.endswith(REVIEW_EXTS):
    sys.exit(0)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": (
            f"AUTO-REVIEW: {path} was just updated. Once you have finished "
            "editing this file for the current task, review its new version "
            "following the 'Code Review Guidelines' in CLAUDE.md, including "
            "every lower-level module beneath it ('Lower-level modules'). Focus "
            "on the changed regions and anything they affect, and report "
            "findings with line references. Review each file once per task, "
            "not after every individual edit."
        ),
    }
}))
