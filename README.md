# fpctools

A fast structural auditor and navigation/editor for FreePascal / Object Pascal source (`.pas`, `.inc`, `.pp`, `.lpr`, `.dpr`). It parses source, recursively follows `{$I}`/`{$INCLUDE}` directives, resolves units, and exposes a navigable block/statement tree with bitmask diagnostics and safe, semantic edit commands.

`fpctools` is a **structural front-end**, not a compiler. Use `fpc`/`lazbuild` and your test suite for final correctness.

Current identity: **fpctools 2.9.3 (parser 2)**, JSON report schema `1`.

---

## Why use it

Editing Pascal safely is hard because line numbers go stale after every write, one physical line can hold several statements, and includes/units mean a single edit may belong to a different file than the one you opened. `fpctools` addresses those problems directly:

- **Semantic addressing.** Navigate and edit by routine/block/statement handles (`GSTest.p.if.1`) rather than line numbers. These survive reformatting and line insertion.
- **Origin-aware writes.** An edit to code inside an `{$I}` include or a resolved unit is written back to the file that actually contains it.
- **Safe edit previews.** `--diff`, `--dry-run`, and `--verify` let you preview and parse-check an edit before applying it.
- **Structure you can query.** A container tree (`HEAD`, `DECL`, `TDEF`, `ROUT`, `COND`, `LOOP`, `CASE`, `EXCP`, `WITH`, `ASM_`, `BODY`, `INIT`, `FWRD`, `GAP_`), callers/orphans analysis, token-aware search, and statement-level enumeration.
- **Machine-readable output.** JSON and SARIF reports, plus a JSON statement map (`--json -gsline`).
- **Self-hosting.** The tool is maintained with itself; every change is validated with a strict self-check and a regression suite.

If you use an AI agent to edit Pascal, the single most important rule is: **never derive an edit target from `grep`/`Select-String` line numbers — resolve a semantic handle first.** The skill and `AGENTS.md` snippet below enforce that.

---

## Build and install

```sh
fpc -O2 -Mobjfpc -Sh fpctools.pas
```

This produces `fpctools.exe` (Windows) or `fpctools` (Unix). No external dependencies beyond the FPC RTL.

Run the regression suite:

```cmd
test\run_regression.cmd
```
Expected ending: `RESULT: PASS`.

---

## CLI conventions

```
fpctools [command] [--flags] <source_file.pas>
```

- **Commands** (root actions) use `-` or `/`: `-check`, `/delete`.
- **Flags** (modifiers) use `--`: `--strict`, `--diff`, `--verify`, `--json`.
- Legacy `--command` forms are accepted for compatibility.
- `-Fi<dir>` adds include search paths; `-Fu<dir>` adds unit paths and enables unit resolution; `--units` resolves units from the source dir + cwd.
- `--no-cache` bypasses the cache; `--clear-cache` rebuilds `.fpaudit.cache`.

---

## Quick start

### 1. Gate a file

```sh
fpctools -check --strict --clear-cache --no-cache main.pas
```

Exit status is a bitmask: `0` clean, `1` syntax/CLI, `2` structural, `4` unimplemented decl, `8` include error, `16` warning. Reports lead with a GSLine note, then the audit header and diagnostics:

```
GSLine paths are the primary statement handles (use -gsline); -glines is deprecated.
================================================================
FPCTOOLS AUDIT REPORT (fpctools 2.9.3, parser 2)
Files parsed: 1 | Types: 57 | Routines: 220 | Syntax issues: 0 | Unimplemented decls: 0 | ExitMask: 0
================================================================
=== SYNTAX & STRUCTURAL DIAGNOSTICS ===
No syntax or structural errors detected.
```

Diagnostics carry a GS handle: `[GS Demo.p.3] [ERROR bit=2] ... line 12, Col 1 - ...`. Statements under inactive `{$IFDEF}` branches are marked `(inactive)`.

### 2. Explore structure

```sh
fpctools -block-tree --no-vars --max-depth 2 main.pas
```

Each node has a `[#id]`, span, and a hint that now leads with a GS path:

```
+- [ROUT #3] procedure P (Lines 4..13, 10 lines) [hint: --gsline GSTest.p.1; --find "#3" --give-block 1]
```

### 3. Find a statement

```sh
fpctools -gsline main.pas            # whole statement map
fpctools -gsline 5-11 main.pas       # GS range
fpctools -gsline GSTest.p.if.1 main.pas
```

```
Path                                     GS#   Line          Container                 Statement
GSTest.p.3                               GS5    L 7.1          P -> procedure P         L := 1; H := 2; G := L + H;
GSTest.p.6                               GS8    L 8-12         P -> procedure P         if G > 0 then
GSTest.p.if.1                            GS9    L 10.1         P -> if G>0              L := L - 1;
```

The path is built from the unit/program name and the block hierarchy. Program `begin..end.` is `GSTest.begin.1`. Overloaded routines get `foo[1]`, `foo[2]`.

### 4. Convert a compiler line number

```sh
fpctools -gline-to-gsline 12 main.pas    # alias: -gline2gs
```

Returns the GSLine(s) whose statement span covers that line — use the returned path for the edit.

### 5. Edit safely

```sh
# preview first
fpctools -stmt-replace GSTest.p.3 'L := 99;' --diff --no-cache main.pas

# apply with parse-check
fpctools -stmt-replace GSTest.p.3 'L := 99;' --verify --no-cache main.pas

# change part of a line, preserving everything else
fpctools -replace-fragment GSTest.var.1 Beta Gamma --verify --no-cache main.pas
#   var Alpha, Beta: Integer;   ->   var Alpha, Gamma: Integer;
```

`-insert` and `-replace` take literal text; `-insert-file` and `-replace-file` take a file path. Passing a path-like string to `-insert`/`-replace` is rejected with a message pointing at the correct command.

### 6. Machine-readable output

```sh
fpctools --json --no-cache -check main.pas
fpctools --json --no-cache -gsline 1-20 main.pas
fpctools --format:sarif --no-cache -check main.pas
```

`-gsline --json` emits `schema_version`, `tool_version`, `parser_version`, `selector`, `count`, and a `statements` array with `path`, `gs`, `file`, `global_line`, `line_ordinal`, `start/end_line/col`, `block_id`, `block_label`, `context`, `text`, and `inactive`.

### 7. Includes and units

```sh
fpctools -check -Fiinc --no-cache main.pas
fpctools -check --units -Fu./src --no-cache main.pas
fpctools -get-block all --units --no-cache main.pas > single.pas
```

With unit resolution, `-get-block all` can emit a monolithic compilable program: unit headers are stripped, bodies inserted at the `uses` point, initialization/finalization relocated. Compile-time `Unit not found: "SysUtils"` warnings are expected unless the FPC RTL source dir is on `-Fu`.

---

## AI agent workflow: with and without fpctools

The following is the same real task — *fix a corrupted assignment inside a nested loop, in a unit that is included by a program, then verify* — done two ways.

### Without fpctools (the fragile path)

1. Search the source with `Select-String`/`grep` for `Total` → get a line number, e.g. `203`.
2. Read a window of lines (`sed -n '185,220p'`) to figure out which `Total` is the bad one. Several assignment candidates exist; the agent guesses from context.
3. Apply a patch by line number or raw text replacement. The text is one line of a file that may actually be an `{$I}` include — but the agent assumes the root file.
4. The edit shifts every later line by ±N. The agent's next command still uses the old line number `211`, so it patches a different statement — silently corrupting a declaration or a `uses` clause.
5. The compiler reports an error at line `212`. The agent re-greps, re-counts, edits again, shifts again.
6. A multi-statement line (`Alpha := 1; Beta := 2;`) gets replaced wholesale, deleting the neighbour.
7. Verification is an afterthought: the agent runs the compiler late, or trusts the edit tool's `Written:` output — which merely echoes the source and is not proof of a write.
8. Large file windows are read repeatedly, consuming context and attention.

Typical result: the agent spends most of its effort managing coordinates and re-reading source, and the failure mode is a *clean-looking but wrong* edit.

### With fpctools (the same task)

```sh
# 1. Resolve the symbol to a semantic handle (no line numbers)
fpctools -gsline main.pas          # scan the statement map for the Total assignment
#   uc3archive.addfiles.for.2   GS137  L 203.1  ArchiveAddFiles -> for I := 1 to N  Total := Total + I;

# 2. Preview exactly that statement
fpctools -stmt-replace uc3archive.addfiles.for.2 'Total := Total + I + 1;' --diff --no-cache main.pas

# 3. Apply with a parse-check; origin-aware write-back sends it to the real file
fpctools -stmt-replace uc3archive.addfiles.for.2 'Total := Total + I + 1;' --verify --no-cache main.pas
#   Verify OK: resulting source is clean
#   Written: F:\Code\Vibe\Uc2_source\fpc\uc3archive.pas     <- the include/unit, not main.pas

# 4. Convert a compiler diagnostic line back to a handle if needed
fpctools -gline-to-gsline 212 main.pas
#   uc3archive.addfiles.if.1   GS141  L 212.1  ...

# 5. Re-query the same path after the edit — the path still resolves; the line did not
fpctools -gsline uc3archive.addfiles.for.2 --no-cache main.pas

# 6. Gate the result
fpctools -check --strict --clear-cache --no-cache main.pas
fpc -B -Mobjfpc -Sh main.pas
```

For a partial-line change, use `-replace-fragment` instead; for a whole line, `-edit-block ... --match ... --with ...`.

### Why this is more practical

| Concern | Without fpctools | With fpctools |
|---|---|---|
| Target identity | Line number that shifts after every write | Semantic path (`uc3archive.addfiles.for.2`) that still resolves |
| Multiple statements on one line | Whole line replaced, neighbours lost | Statement/fragment span only; separators preserved |
| Includes and units | Edit applied to the wrong file | Origin-aware write-back to the owning file |
| Verification | Late compiler run, or trust in `Written:` | `--diff` preview and `--verify` parse-check before write |
| Compiler diagnostics | Agent re-greps and re-counts | `-gline-to-gsline` converts a line to a handle |
| Context cost | Repeated file windows and re-reads | One map row, one diff, one report section |
| Failure mode | Clean-looking but wrong edit | Explicit bitmask/verify failure, re-inspect the block |

The deeper benefit is **clarified agent work**: the agent reasons about *routines, blocks and statements* rather than coordinates. The mandatory `AGENTS.md` rule below removes the tempting fallback ("just grep for the line") and gives one predictable decision chain: locate semantically → choose the edit by scope → preview → verify → gate. That turns editing from a coordinate-management problem into a small, auditable sequence.

---

## Editing without line numbers (the important part)

Resolve a semantic handle first, then pick the edit command by scope:

| Want | Command |
|---|---|
| List statements / find a handle | `-gsline`, `-stmts`, `-find`, `-block-tree`, `-edit-plan` |
| Replace a whole statement | `-stmt-replace <path> '<new text>'` |
| Change part of a line | `-replace-fragment <container> <fragment> <text>` |
| Replace a whole line / container | `-edit-block <target> --match <fragment> --with <text>` |
| Convert a compiler line | `-gline-to-gsline <n>` |

Never use `-edit-gline`, `-delete-gline`, numeric `start-end` targets, or text-search-derived line numbers. They are deprecated and shift after every write. Always preview with `--diff` and apply with `--verify`.

---

## Help reference

```
INFORMATION COMMANDS
  -h, --help, -?, /?       Display help and exit
  -version                 Print version and exit
  -schema-version          Print JSON schema version and exit

REPORT / QUERY COMMANDS
  -check                   Diagnostics-only check with bitmask exit code
  -filter <symbol>         Matching symbols with enclosing block chain
  -find <q>                Filter symbols or locate block ("fn:var", "#12")
  -callers <name>          Routines calling <name>
  -orphans                 Routines potentially unreachable from entry points
  -show <name>             Routine details + numbered source lines
  -lines <file:a-b>        Numbered source lines from a file
  -search <pattern>        Pascal-aware token search
  -read-full <mode> <line> Full statement/block/line at a line number
  -edit-plan <query>       Resolve a block and print an edit plan
  -gsline [selector]       Statement map: none=all, a-b=range, GS#/path=one
  -gslines <a-b>           Compatibility alias for -gsline <a-b>
  -decode-gsline <n|path>  Print the edit path for one statement
  -gline-to-gsline <n>     GSLine(s) covering a global line (alias -gline2gs)

EDIT COMMANDS
  -insert <target> <text>       Insert inline text before target
  -insert-before/-after <t> <text>
  -insert-file <target> <path>   Insert file contents before target
  -insert-file-before/-after <t> <path>
  -replace <target> <text>      Replace whole block/range
  -replace-file <t> <path>      Replace with file contents
  -delete <target>              Delete block/range
  -edit-block <t> --match <fragment> --with <text>
  -edit-global / -delete-global --match <fragment> [--with <text>]
  -replace-fragment <block> <fragment> <text>   Replace only matched token

STATEMENT COMMANDS
  -stmts <target>                    List statements in a block
  -stmt-replace/-delete <t> <i> <s>  Statement edits by index (or GS path)
  -stmt-insert-before/-after <t> <i> <s>

FORWARD COMMANDS
  -check-forward / -fix-forward / -fix-all

KEY FLAGS
  --strict --diff --dry-run --verify --json --format:json --format:sarif
  --report=<sections> --in <target> --match <f> --with <text>
  --units -Fu<dir> -Fi<dir> --lazarus <project>
  --no-cache --clear-cache --give-block --widen --max-depth
  --add-forward --add-include --add-block --outinsert --output-raw
```

Full authoritative list: `fpctools -h`.

---

## Using fpctools from an AI agent (skill + AGENTS.md)

Install the skill globally so every project can use it:

```
~/.config/opencode/skills/fpctools/SKILL.md
```

For a project-local setup, place the same file at `<project>/.opencode/skills/fpctools/SKILL.md`. Do not keep multiple stale copies — OpenCode resolves skills by ID and a later source overrides an earlier one, so duplicate copies are the main cause of version/help drift.

Add this to your project or global `AGENTS.md`:

```markdown
## Mandatory Code Editing Workflow
- **ALWAYS** use `fpctools` when inserting or modifying code in Pascal source files (`.pas`, `.inc`, `.pp`, `.lpr`, `.dpr`).
- **NEVER** use built-in file editing or write tools to patch existing Pascal source files directly.
- If you have not loaded the `fpctools` skill yet—or if the session was recently compacted—call `skill("fpctools")` before making any code changes.
- When reporting locations or proposing edits, lead with GSLine semantic paths (`Demo.accumulate.3`) and never propose line-number edits; `-glines`/`-gline` are deprecated, and compiler line numbers should be converted with `-gline-to-gsline <n>`.
- **NEVER** use `Select-String`/`grep`/`findstr` to derive a Pascal edit target. Use `-gsline`/`-find`/`-block-tree` to locate, `-stmt-replace <path>` for whole statements, and `-replace-fragment <container> <fragment> <text>` to change part of a line without disturbing the rest.
```

The skill itself contains the detailed progressive-disclosure workflow, edit recipes, self-hosting checklist, and all CLI notes.

---

## Self-hosting workflow

When editing fpctools itself:

1. Work on `fpctools_work.pas`; keep it byte-identical to canonical only after promotion. Compile a known-good binary from the current canonical source and use *that* binary to apply edits (the binary under repair may have a broken edit path).
2. Inspect targets with `-find ... --give-block`, `-block-tree`, `-lines`, `-edit-plan`.
3. Apply one edit per invocation, bottom-up (descending line/range), with `--diff` then `--verify`.
4. Confirm writes with a raw diff/line count — tool output echoing `Written:` is not proof.
5. `fpc -O2 -Mobjfpc -Sh fpctools_work.pas`
6. `fpctools -check --strict --clear-cache --no-cache fpctools_work.pas` → ExitMask 0
7. `test\run_regression.cmd` → `RESULT: PASS`
8. Promote to `fpctools.pas`, rebuild `fpctools.exe`, re-run all gates. Never delete `FPCAudit_v20.pas`.

---

## Known limitations / Still to do

- `{$IFDEF}` branches are evaluated for activity marking, but code is never filtered out of navigation — both branches remain addressable.
- The statement collector is heuristic, though it handles generics, attributes, class `var` sections, `begin..end` and single-statement branch bodies, `try`/`case` bodies, and calling conventions.
- Strict unresolved-call checks are closed-world/heuristic; unresolved qualified names are skipped conservatively.
- `fpctools` is a structural front-end — trust `fpc` and tests for semantic correctness.

---

## Exit codes

| Bit | Meaning |
|----:|---------|
| 0 | Clean |
| 1 | Syntax / lex / CLI error |
| 2 | Structural error (unmatched begin/end, etc.) |
| 4 | Unimplemented declaration |
| 8 | Include error (missing/circular) |
| 16 | Warning (heuristic, e.g. unresolved calls) |

Composite codes are ORed (e.g. `22 = 16 + 4 + 2`).


