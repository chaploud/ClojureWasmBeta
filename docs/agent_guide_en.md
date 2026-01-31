# ClojureWasm Production: Coding Agent Development Guide

> Reference materials, prompt design, and management practices for building
> the production version from scratch using coding agents such as Claude Code,
> based on lessons from ClojureWasm Beta.
>
> Related: [future.md](./future.md) (production design document)

---

## 0. Prerequisites

- Agent: **Claude Code** (claude-code CLI)
- Host language: **Zig 0.15.2+**
- Reference implementation: **ClojureWasmBeta** (this repository)
- Development method: **TDD (t-wada style Red-Green-Refactor)** + Plan Mode

---

## 1. Reference Directories (`add-dir`)

Directories to add via Claude Code's `add-dir`.
Required references change by phase, so add them incrementally.

### Always Referenced (All Phases)

| Directory                    | Reason                             |
|------------------------------|------------------------------------|
| `<ClojureWasmBeta path>`     | Beta implementation (primary)      |
| `<clojure path>`             | Upstream Clojure (source of truth) |
| `<zig stdlib path>`          | Zig standard library               |

> Paths are environment-specific. Refer to Beta's CLAUDE.md for actual paths.

### Phase 1-2 (Reader + Analyzer)

| Directory                    | Reason                         |
|------------------------------|--------------------------------|
| `<tools.reader path>`       | Clojure Reader reference impl  |
| `<clojurescript path>`      | CLJS reader/analyzer reference |

### Phase 3+ (Builtins + Testing)

| Directory                    | Reason                  |
|------------------------------|-------------------------|
| `<sci path>`                | SCI builtin patterns    |
| `<babashka path>`           | Babashka test structure |

### Optional (As Needed)

| Directory                    | Reason                        |
|------------------------------|-------------------------------|
| `<nrepl path>`              | nREPL protocol implementation |
| `<cider-nrepl path>`       | CIDER nREPL middleware        |
| `<babashka.nrepl path>`    | Babashka nREPL implementation |

---

## 2. Project Structure and Management Files

### 2.1 Directory Layout

```
clojurewasm/
├── CLAUDE.md                    # Agent instructions (main)
├── CLAUDE.local.md              # Local-only settings (.gitignore)
├── .claude/
│   ├── settings.json            # Permissions & hook settings
│   ├── skills/                  # Custom skills
│   │   ├── tdd/SKILL.md
│   │   ├── phase-check/SKILL.md
│   │   └── compat-test/SKILL.md
│   └── agents/                  # Custom subagents
│       ├── security-reviewer.md
│       └── compat-checker.md
├── flake.nix                    # Toolchain definition
├── flake.lock
├── build.zig
├── build.zig.zon
├── src/
│   ├── api/                     # Public API (§17)
│   ├── common/                  # Shared code
│   ├── native/                  # Native route specific
│   └── wasm_rt/                 # wasm_rt route specific
├── core/
│   └── core.clj                 # AOT compilation target (§9.6)
├── test/
│   ├── unit/
│   ├── e2e/
│   └── imported/                # Upstream tests (§10)
├── plan/
│   ├── memo.md                  # Current state only (keep small)
│   ├── active/                  # Current phase plan+log (1 pair only)
│   │   ├── plan_0003_vm_bytecode.md
│   │   └── log_0003_vm_bytecode.md
│   └── archive/                 # Completed phase plans+logs (paired)
│       ├── plan_0001_tokenizer_reader.md
│       ├── log_0001_tokenizer_reader.md
│       ├── plan_0002_analyzer.md
│       └── log_0002_analyzer.md
├── status/
│   ├── vars.yaml                # Var implementation status
│   ├── bench.yaml               # Benchmarks
│   └── namespaces.yaml          # Namespace correspondence status
├── doc/
│   └── adr/                     # Architecture Decision Records
├── book/                        # mdBook documentation
├── bench/                       # Benchmark suite
├── scripts/                     # CI / quality gate scripts
└── examples/
```

### 2.2 plan/ Operation Flow

```
Phase start:
  1. Create plan_NNNN_title.md in plan/active/ (goals & task list)
  2. Update memo.md (current phase number & active file name)

During implementation:
  3. Agent appends to log_NNNN_title.md on each task completion
  4. If plans change, update plan file and record reason in log
  5. Update "Next task" in memo.md

Phase completion:
  6. Move plan + log to archive/
  7. Create next phase plan in active/
  8. Update memo.md
```

**Naming convention**: `plan_NNNN_short_title.md` / `log_NNNN_short_title.md`
- Titles in English snake_case (per language policy)
- 4-digit sequential numbering (avoids insertion problems; Beta had S, G, P... proliferation)
- Numbers are creation order. If insertions occur, just use the next number
- active/ always contains exactly one pair (plan + log)

### 2.3 memo.md Structure

memo.md records **current state only**. Keep it small.
Task details go in the active/ plan file.

```markdown
# ClojureWasm Development Memo

## Current State

- Current phase: plan/active/plan_0003_vm_bytecode.md
- Last completed: Basic node generation in Analyzer
- Next task: OpCode definition and stack machine foundation
- Blockers: none

## Completed Phases

| #    | Title              | Period             | Tests |
|------|--------------------|--------------------| ------|
| 0001 | tokenizer_reader   | 2026-02 -- 2026-03 | 312   |
| 0002 | analyzer           | 2026-03 -- 2026-04 | 198   |
```

### 2.4 Plan File Structure

```markdown
# plan_0003_vm_bytecode.md

## Goal
Build BytecodeVM foundation: constant, arithmetic, and comparison opcodes operational.

## References
- Beta: src/compiler/emit.zig, src/vm/vm.zig, src/compiler/bytecode.zig
- Beta lessons: docs/reference/vm_design.md (stack contract importance)
- Design: docs/future.md §9.1 (compiler-VM contract)

## Tasks

| # | Task                                  | Status      | Notes                    |
|---|---------------------------------------|-------------|--------------------------|
| 1 | OpCode enum definition                | done        |                          |
| 2 | Chunk (bytecode sequence) struct      | done        |                          |
| 3 | VM stack machine foundation           | in-progress | Beta's stack_top pattern |
| 4 | Constant load (op_const)              | pending     |                          |
| 5 | Arithmetic opcodes (+, -, *, /)       | pending     | NaN boxing assumed       |

## Design Notes
- Difference from Beta: VM is instantiated (no threadlocal)
- NaN boxing introduced in Phase 0003 (not tagged union as in Beta)
```

### 2.5 Log File Structure

```markdown
# log_0003_vm_bytecode.md

## 2026-04-10
- Defined OpCode enum (24 opcodes)
- Used enum(u8) instead of Beta's plain u8 (type safety)

## 2026-04-11
- Implemented Chunk struct. Same ArrayList(u8) base as Beta
- PLAN CHANGE: moved constant table inside Chunk
  (Beta used external table, but incompatible with VM instantiation)
  -> updated task 4 in plan

## 2026-04-12
- VM stack machine foundation: 10 tests pass
- Finding: Beta's stack_top pointer approach works well with NaN boxing
- Lesson: should include stack overflow check from the start
  (Beta added it later, caused 3 bugs)
```

---

## 3. CLAUDE.md Template

Place this CLAUDE.md at the project root.
**Keep it concise per Claude Code Best Practice**.
Do not write things Claude can infer on its own.

````markdown
# ClojureWasm

Full-scratch Clojure implementation in Zig. Targeting behavioral compatibility (black-box).

Reference implementation: <Beta path> (via add-dir)

Current state: see plan/memo.md
Design details: see docs/future.md

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, PR descriptions
- No non-English text in source code or version control history
- Zig 0.15.2 conventions apply (see docs/reference/zig_guide.md)
- Agent response language is a personal preference — configure in `~/.claude/CLAUDE.md`

> **Note for contributors**: to receive agent responses in your preferred language,
> add a directive to your personal `~/.claude/CLAUDE.md` (not committed to the repo).
> Example: `Respond in Japanese.` or `Respond in Korean.`

## Development Method: TDD (t-wada style)

IMPORTANT: Strictly follow the TDD approach recommended by t-wada (Takuto Wada).

1. **Red**: Write exactly one failing test first
2. **Green**: Write the minimum code to make it pass
3. **Refactor**: Improve code while keeping tests green

- Never write production code before a test
- Never add multiple tests at once (1 test -> 1 impl -> verify cycle)
- Always confirm the test is Red before moving to Green
- Progress: "Fake It" -> "Triangulate" -> "Obvious Implementation"
- Refactoring must not change behavior (revert immediately if tests break)

## Session Workflow

### On Start
1. Read plan/memo.md (identify current phase and next task)
2. Check plan/active/ plan file for task details

### During Development
1. Implement via TDD cycle (above)
2. Reference Beta code, but redesign from understanding — no copy-paste
3. Commit frequently when tests pass
4. Append discoveries, completions, and plan changes to plan/active/ log file

### On Task Completion
1. Update the task status to "done" in plan/active/ plan file
2. Update "Next task" in memo.md
3. Git commit at meaningful boundaries
4. Automatically proceed to next pending task

### On Phase Completion
1. Move plan + log to plan/archive/
2. Add entry to "Completed Phases" table in memo.md
3. Create next phase plan in plan/active/ (use Plan Mode)

## Build & Test

```bash
# Enter dev shell (all tools on PATH)
nix develop

# Build
zig build

# Run tests
zig build test

# Specific test only
zig build test -- "Reader basics"

# Benchmark
bash bench/run_bench.sh --quick
```

## Differences from Beta

Production version is a full redesign from Beta. Key changes:
- Instantiated VM (no threadlocal) -> future.md §15.5
- GcStrategy trait for GC abstraction -> future.md §5
- BuiltinDef with metadata (doc, arglists, added) -> future.md §10
- core.clj AOT compilation -> future.md §9.6
- Design decisions recorded as ADRs in doc/adr/
````

---

## 4. Skill Definitions

### 4.1 TDD Skill

```markdown
# .claude/skills/tdd/SKILL.md
---
name: tdd
description: Execute t-wada style TDD cycle
---
Strictly follow the TDD cycle recommended by t-wada (Takuto Wada)
to implement $ARGUMENTS.

## Steps

1. **Create test list**: enumerate behaviors to implement as a test list
2. **Pick the simplest case**: choose one from the test list
3. **Red**: write a failing test. Confirm failure with `zig build test`
4. **Green**: write minimal code to pass. Fake implementation (return constant) is fine
5. **Confirm success with `zig build test`**
6. **Refactor**: remove duplication, clean up. Do not break tests
7. **Confirm success with `zig build test`**
8. **Commit**: `git commit` (only when tests pass)
9. **Return to test list, pick next case** (go to 2)

## Fake It -> Triangulate -> Obvious Implementation

- Fake It: pass first test with hardcoded constant
- Triangulate: second test forces generalization
- Obvious Implementation: implement directly when pattern is clear

## Rules

- Never add more than one test at a time
- Never write Green code without confirming Red first
- Never add tests during Refactor step
- Reference Beta code but never bring code in without tests
```

### 4.2 Phase Check Skill

```markdown
# .claude/skills/phase-check/SKILL.md
---
name: phase-check
description: Check current development phase progress
---
Check progress of the current development phase.

1. Read plan/memo.md to identify current phase
2. Read plan/active/ plan file and check task completion status
3. Run `zig build test` and report pass/fail counts
4. Aggregate implementation status from status/vars.yaml
5. List pending tasks and identify what to do next
6. Report blockers if any
7. Show latest entry from plan/active/ log file
```

### 4.3 Compatibility Test Skill

```markdown
# .claude/skills/compat-test/SKILL.md
---
name: compat-test
description: Test compatibility with upstream Clojure
---
Test compatibility of $ARGUMENTS function/macro against upstream Clojure.

1. Check upstream source:
   find definition in `~/Documents/OSS/clojure/src/clj/clojure/core.clj`
2. Verify upstream behavior via nREPL:
   `clj-nrepl-eval -p <port> "(fn args)"` to get actual output
3. Evaluate same expression in ClojureWasm:
   `clj-wasm -e "(fn args)"` and compare output
4. Report differences and add test cases
5. Check edge cases (nil, empty collections, negative numbers, etc.)
```

---

## 5. Subagent Definitions

### 5.1 Security Reviewer

```markdown
# .claude/agents/security-reviewer.md
---
name: security-reviewer
description: Detect security issues in Zig code
tools: Read, Grep, Glob
model: sonnet
---
Detect security issues in Zig code:
- Buffer overflow (missing bounds checks)
- Use-after-free (GC interaction)
- Unvalidated external input (Reader input)
- Integer overflow
- Unsafe @ptrCast / @intToPtr usage
Provide specific line numbers and fix suggestions.
```

### 5.2 Compatibility Checker

```markdown
# .claude/agents/compat-checker.md
---
name: compat-checker
description: Detect behavioral differences from upstream Clojure
tools: Read, Grep, Glob, Bash
model: sonnet
---
Verify compatibility of specified functions against upstream Clojure.
1. Check definition in upstream core.clj
2. Extract upstream docstring, arglists, :added
3. Compare with ClojureWasm implementation
4. Propose test cases
Pay special attention to edge cases (nil, empty, large values).
```

---

## 6. Hook Definitions

```jsonc
// .claude/settings.json (excerpt)
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "zig build test 2>&1 | tail -5"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'editing...'"
          }
        ]
      }
    ]
  }
}
```

> **Note**: Claude Code hooks are `PreToolUse`, `PostToolUse`, and `Stop`.
> Use `matcher` to filter by tool name. `postEdit`/`preCommit` do not exist.
> See: [Claude Code Hooks](https://code.claude.com/docs/en/hooks)

---

## 7. Toolchain Requirements (Nix Flake)

```nix
# flake.nix
{
  description = "ClojureWasm development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # === Compiler ===
            zigpkgs."0.15.2"        # Zig compiler (version pinned)

            # === Wasm Runtime ===
            wasmtime                 # Wasm execution & testing

            # === Clojure (compatibility testing) ===
            clojure                  # Upstream Clojure (behavior reference)
            jdk21                    # Required for Clojure
            babashka                 # Scripting

            # === Benchmarking ===
            hyperfine                # CLI benchmark tool
            valgrind                 # Memory profiling (Linux)

            # === Data Processing ===
            yq-go                    # YAML processing (vars.yaml etc.)
            jq                       # JSON processing

            # === Documentation ===
            mdbook                   # mdBook build

            # === Dev Tools ===
            python3                  # Scripts & test generation
            nodePackages.prettier    # Markdown formatter

            # === VCS ===
            git
            gh                       # GitHub CLI
          ];

          shellHook = ''
            echo "ClojureWasm dev shell (Zig $(zig version))"
            echo "Tools: clojure, wasmtime, hyperfine, yq, mdbook"
          '';
        };
      });
}
```

### Tool Roles

| Tool      | Purpose                            | Claude Code Usage                        |
|-----------|------------------------------------|------------------------------------------|
| zig       | Compile, test, build               | Always                                   |
| wasmtime  | Wasm binary execution testing      | wasm_rt route testing                    |
| clojure   | Verify upstream behavior           | Compatibility testing (`clj-nrepl-eval`) |
| babashka  | Test generation scripts            | Upstream test conversion                 |
| hyperfine | Precise benchmark measurement      | Performance improvement                  |
| yq        | Query/update vars.yaml, bench.yaml | Status checks                            |
| mdbook    | Documentation build & preview      | Documentation updates                    |
| gh        | Issue/PR creation, CI status       | PR creation                              |

---

## 8. Phase-Specific Agent Instructions

Instruction patterns for Claude Code at each phase.
Keep CLAUDE.md concise and shared across all phases;
provide phase-specific instructions via **Plan Mode prompts**.

### Phase 0: Project Initialization

```
Execute the following in Plan Mode:

1. Set up toolchain with flake.nix (verify with nix develop)
2. Create build.zig scaffold (zig build / zig build test must pass)
3. Create src/ directory structure per docs/future.md §17
4. Create initial versions of CLAUDE.md, plan/memo.md, status/vars.yaml
5. Create scaffold for doc/adr/0001-nan-boxing.md
6. git init && initial commit
```

### Phase 1: Reader + Analyzer

```
Implement the Reader via TDD, following Phase 1 tasks in plan/memo.md.

References:
- Beta's src/reader/reader.zig (reference structure, but redesign — no copy)
- Upstream tools.reader: ~/Documents/OSS/tools.reader
- Zig stdlib: std.fmt, std.unicode

Notes:
- Beta's Reader grew to 2,800 lines in a single file. Split in production
- NaN/Infinity number parsing is a Beta lesson (docs/reference/lessons_learned.md)
- Error messages must include line and column numbers
- Reader input validation (depth limit, size limit) per §14 security design
```

### Phase 2: Native Route VM

```
Implement the VM via TDD, following Phase 2 tasks in plan/memo.md.

References:
- Beta's src/runtime/ (value.zig, evaluator.zig, vm/vm.zig)
- Beta's docs/reference/vm_design.md (stack contract)
- Beta's docs/reference/gc_design.md (semi-space GC)

Design changes (differences from Beta):
- Value uses NaN Boxing (future.md §5)
- VM is instantiated (no threadlocal, future.md §15.5)
- GcStrategy trait for GC abstraction (future.md §5)
- Compiler-VM contract expressed in types (future.md §9.1)

Test strategy:
- At least 3 tests per opcode (happy path, edge case, error case)
- Re-implement Beta's --compare pattern (TreeWalk reference impl vs VM)
```

### Phase 3: Builtin Functions + core.clj AOT

```
Implement builtin functions following Phase 3 tasks in plan/memo.md.

Two implementation paths:
1. Zig builtins (vm_intrinsic + runtime_fn):
   - TDD: test first, then implement
   - Always include doc, arglists, added metadata in BuiltinDef
   - Use upstream core.clj docstrings verbatim (for compatibility)

2. core.clj AOT (core_fn + core_macro):
   - Define in Clojure in core/core.clj
   - Build AOT pipeline at build time (future.md §9.6)
   - Reference upstream bootstrap order

Compatibility testing:
- Test that each function returns the same output as upstream
- Verify upstream behavior with clj-nrepl-eval before writing tests
- Record kind, ns, added in status/vars.yaml
```

### Phase 4+: Optimization & Test Expansion

```
Always measure with benchmarks before performance improvements.

Procedure:
1. Measure baseline with bench/run_bench.sh --quick
2. Identify bottleneck via profiling
3. Implement optimization (TDD: confirm tests still pass)
4. bench/run_bench.sh --quick --record --version="optimization name"
5. If improvement confirmed, commit; otherwise revert

Upstream test import:
- SCI tests -> Tier 1 conversion (future.md §10)
- ClojureScript tests -> Tier 1 conversion
- Upstream tests -> Tier 2/3 conversion
```

---

## 9. Session Management Patterns

Session management based on Claude Code Best Practice.

### 9.1 Context Management

```
- Run /clear between tasks (prevent context pollution)
- Principle: 1 session = 1 task (one line in memo.md)
- For long sessions, use /compact "retain list of implemented functions and test results"
- Delegate investigation to subagents ("investigate Reader structure with subagent")
```

### 9.2 Writer/Reviewer Pattern

```
Split large changes into two sessions:

Session A (Writer):
  "Implement Phase 2 Value type via TDD"

Session B (Reviewer):
  "Review src/runtime/value.zig.
   Focus on edge cases, GC interaction, and design differences from Beta"
```

### 9.3 Error Recovery

```
- If tests fail twice in a row, /rewind to checkpoint
- If same fix fails twice, /clear and try a fresh approach
- If build errors persist:
  1. Check LSP errors with getDiagnostics
  2. Reference equivalent Beta code
  3. Check docs/reference/zig_guide.md for pitfalls
```

### 9.4 Parallel Session Usage

```bash
# Fan-out: batch conversion of upstream tests
for file in $(cat test/imported/pending.txt); do
  claude -p "Convert test/imported/$file for ClojureWasm.\
    Follow Tier 1 rules (future.md §10).\
    Save converted file to test/imported/converted/" \
    --allowedTools "Read,Write,Bash(zig build test *)"
done
```

---

## 10. Quality Gates & CI

### 10.1 Local Quality Gates (Pre-Commit)

```bash
#!/bin/bash
# scripts/pre-commit-check.sh
set -e

echo "=== zig build test ==="
zig build test

echo "=== vars.yaml consistency check ==="
# Verify kind field contains valid enum values
yq '.vars.clojure_core | to_entries | map(select(.value.kind != null))
    | map(select(.value.kind |
      test("^(special_form|vm_intrinsic|runtime_fn|core_fn|core_macro)$") | not))
    | length' status/vars.yaml | grep -q '^0$'

echo "=== namespace correspondence check ==="
# Verify ns field is set for all done vars
yq '.vars.clojure_core | to_entries
    | map(select(.value.status == "done" and .value.ns == null))
    | length' status/vars.yaml | grep -q '^0$'

echo "All checks passed."
```

### 10.2 CI Pipeline (GitHub Actions)

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command zig build test

  compat:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command bash scripts/compat-check.sh

  bench:
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command bash bench/run_bench.sh --quick
```

---

## 11. ADR Template

```markdown
# doc/adr/0000-template.md

# ADR-NNNN: Title

## Status
Proposed / Accepted / Deprecated / Superseded by ADR-XXXX

## Context
Why this decision is needed. Background and constraints.

## Decision
What was decided.

## Rationale
Why this option was chosen. Alternatives considered.

## Consequences
What changes as a result. Trade-offs.

## Lessons from Beta
(If applicable) How lessons from Beta influenced this decision.
```

---

## 12. References

### TDD

- Takuto Wada (t-wada): leading practitioner of test-driven development
  - Translator of Kent Beck's "Test-Driven Development By Example" (Japanese edition)
  - Advocates strict adherence to the Red-Green-Refactor cycle
  - Gradual generalization: "Fake It" -> "Triangulate" -> "Obvious Implementation"
  - In the AI agent era, TDD is being re-evaluated as a "guardrail"
- Including t-wada's name in Claude instructions tends to produce stricter TDD adherence
  compared to generic "TDD" instructions (anchoring effect that prevents semantic diffusion)

### Claude Code Best Practice

- Keep CLAUDE.md concise (do not write what Claude can infer on its own)
- Providing testing and verification tools is the highest-impact measure
- Use Plan Mode to separate into 4 phases: investigate -> plan -> implement -> commit
- Context window is the most important resource. Use /clear aggressively
- Delegate investigation to subagents to avoid polluting main context
- Hooks guarantee deterministic behavior (CLAUDE.md instructions are advisory)
- Skills load domain knowledge only when needed
- Use Writer/Reviewer pattern with parallel sessions

### Sources

- [Claude Code Best Practices (Anthropic official)](https://code.claude.com/docs/en/best-practices)
- [t-wada: TDD in the AI Agent Era (Agile Journey)](https://agilejourney.uzabase.com/entry/2025/08/29/103000)
- [Name+Technique List for Claude (t-wada TDD)](https://memory-lovers.blog/entry/2025/06/27/102550)
