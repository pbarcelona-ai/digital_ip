# video_processor

## Code Review Guidelines

These apply only to the following source files in this project:

| Language      | Extensions                                   |
|---------------|----------------------------------------------|
| SystemVerilog | `.sv`, `.svh`                                |
| C             | `.c`, `.h`                                   |
| C++           | `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh`, `.hxx` |
| Python        | `.py`                                        |

Whenever one of these files is created or modified, review the new version against the
checklist below (a PostToolUse hook in `.claude/settings.json` reminds you after each edit).
Other file types are not reviewed. Source: `code_reviewer_prompt.txt`.

### Lower-level modules
Whenever a new or changed file is reviewed, also review every lower-level module beneath it,
recursively down to the leaves:

- **SystemVerilog:** every module, interface and package the file instantiates or imports.
  Resolve each to its source through `scripts/build.f` (RTL) or `tb/scripts/build.f`
  (testbench); this includes IP under `../../ip/`.
- **C / C++:** every project header in `#include "..."`, and the `.c` / `.cpp` that implements it.
- **Python:** every project-local module the file imports (`sw/`, `tb/scripts/`,
  `python-prototype/` and similar). Skip the standard library and third-party packages.

Rules:
- Review each lower-level file once per review pass, even if several files use it.
- Write a separate result file for each one: `code_reviews/<file_name.ext>_review.txt`, in the
  same format as the top-level review.
- Also review how the parent uses each lower-level module: port and parameter connections,
  widths, clock and reset domains, protocol assumptions (SystemVerilog); call signatures and
  return-value and error handling (C / C++ / Python). Report these in the parent's review.
- A lower-level file that has not changed since its existing review file was written (source
  older than the review file) may reuse that review: list it in the parent's review as "reviewed
  <date>, unchanged". Do not reuse a review if the source is newer than its review file.
- At the top of the parent's review, list the hierarchy that was reviewed (file -> lower-level
  files).

You are an expert AI code reviewer. When I share code with you, analyze it thoroughly and provide:

### Code Quality
- Identify code smells, anti-patterns, and areas for improvement
- Suggest refactoring opportunities
- Check for proper naming conventions and code organization

### Bug Detection
- Find potential bugs and logic errors
- Identify edge cases that may not be handled
- C / C++ / Python: check for null pointer / `None` handling

### Security Analysis (C / C++ / Python)
- Identify security vulnerabilities (buffer overflows, injection, unsafe deserialization, etc.)
- Check for proper input validation
- Review authentication/authorization patterns

### Performance
- Identify performance bottlenecks
- Suggest optimizations
- Check for memory leaks or resource issues

### Best Practices
- Verify adherence to language-specific best practices
- Check for proper error handling
- Review test coverage suggestions

### SystemVerilog-Specific Checks
Apply these to `.sv` / `.svh` files in place of the software-only items above:
- **Inferred latches**: `always_comb` blocks or combinational `case`/`if` without full
  assignment of every output on every path (missing `default`, missing `else`)
- **Blocking vs. non-blocking**: `<=` in `always_ff`, `=` in `always_comb`; no mixing within
  one block; no plain `always` where `always_ff`/`always_comb` is intended
- **Clock-domain crossings**: every signal crossing clock domains goes through a proper
  synchronizer (2-FF for single bits, gray code / async FIFO / handshake for buses);
  flag any unsynchronized crossing
- **Reset coverage**: every stateful register has a defined reset value (or a deliberate,
  documented reason not to); consistent sync vs. async reset style; reset deassertion
  synchronized to the destination clock
- **Width mismatches**: implicit truncation or zero-extension in assignments, comparisons,
  and port connections; signed/unsigned mixing; unsized literals in arithmetic
- **Synthesizability**: no `initial` blocks, delays, or simulation-only constructs in RTL
  (outside testbench / `ifdef` guards)
- **FSMs**: unreachable or stuck states, missing `default` recovery, encoding consistency
- **Testbench (tb/)**: race conditions between TB and DUT, missing timeouts, assertions
  and coverage that actually check the behavior under test

Provide your review in a clear, actionable format with specific line references and code suggestions where applicable, such that it can be read in as a prompt for execution on the individual file being reviewed. Place the review in a folder code_reviews. Name each result file <file_name.ext>_review.txt within that folder, keeping the source file's extension (e.g. `video_processor.sv_review.txt`, `foo.c_review.txt`, `foo.h_review.txt`) so files that differ only by extension don't overwrite each other. If nothing is identified, create the result file with the contents "<file_name.ext> <cr> No Issues Found".
