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
│   ├── skills/                  # Custom skills (Anthropic Skills format)
│   │   ├── tdd/
│   │   │   ├── SKILL.md
│   │   │   └── references/tdd-patterns.md
│   │   ├── phase-check/
│   │   │   └── SKILL.md
│   │   └── compat-test/
│   │       ├── SKILL.md
│   │       └── references/edge-cases.md
│   └── agents/                  # Custom subagents
│       ├── security-reviewer.md
│       ├── compat-checker.md
│       ├── test-runner.md
│       ├── codebase-explorer.md
│       └── debugger.md
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

> Structure based on the Anthropic Skills Guide:
> - **YAML frontmatter**: `name` + `description` (with trigger conditions) + `metadata`
> - **Progressive Disclosure**: keep SKILL.md concise, move details to `references/`
> - **Folder structure**: `skills/<name>/SKILL.md` + `scripts/` + `references/`

### 4.1 TDD Skill

Folder structure:

```
.claude/skills/tdd/
├── SKILL.md
└── references/
    └── tdd-patterns.md    # Detailed explanation of Fake It / Triangulate / Obvious
```

SKILL.md:

```markdown
---
name: tdd
description: >
  t-wada style TDD cycle (Red-Green-Refactor) for implementing functions
  and modules. Use when user says "TDD で実装", "テスト駆動で", "write tests
  first", "Red-Green-Refactor", or asks to implement a function with tests.
  Do NOT use for adding tests to existing code without the full TDD cycle.
compatibility: Claude Code only. Requires zig build test.
metadata:
  author: clojurewasm
  version: 1.0.0
---
# TDD Skill

Implement $ARGUMENTS using the strict TDD cycle by t-wada (Takuto Wada).

## Steps

1. **Test list**: enumerate behaviors to implement as a test list
2. **Pick simplest**: choose the simplest one from the test list
3. **Red**: write a failing test. Confirm failure with `zig build test`
4. **Green**: write minimal code to pass. Fake implementation (return constant) is fine
5. **Confirm pass**: `zig build test`
6. **Refactor**: remove duplication, clean up code. Do not break tests
7. **Confirm pass**: `zig build test`
8. **Commit**: `git commit` (only when tests pass)
9. **Next**: return to test list, pick next case (go to 2)

## Key Patterns

See `references/tdd-patterns.md` for details:
- Fake It: pass first test with hardcoded constant
- Triangulate: second test forces generalization
- Obvious Implementation: implement directly when pattern is clear

## Rules

- Never add more than one test at a time
- Never write Green code without confirming Red first
- Never add tests during Refactor step
- Reference Beta code but never bring code in without tests
```

references/tdd-patterns.md:

```markdown
# TDD Patterns (t-wada)

## Fake It -> Triangulate -> Obvious Implementation

### Fake It
Return a hardcoded constant to make the first test pass.
This verifies the test infrastructure works and forces you
to write the assertion first.

Example:
- Test: `expect(add(1, 2) == 3)`
- Fake: `fn add(a, b) { return 3; }`

### Triangulate
Add a second test case that cannot pass with the fake.
This forces generalization.

Example:
- Test 2: `expect(add(3, 4) == 7)`
- Now you must implement: `fn add(a, b) { return a + b; }`

### Obvious Implementation
When the pattern is clear from the start, skip Fake It
and implement directly. Use when the logic is trivial.

## Anti-patterns
- Writing multiple tests before any Green
- Refactoring while a test is Red
- Importing Beta code without writing tests first
```

### 4.2 Phase Check Skill

Folder structure:

```
.claude/skills/phase-check/
└── SKILL.md
```

SKILL.md:

```markdown
---
name: phase-check
description: >
  Check current development phase progress, pending tasks, and blockers.
  Use when user says "progress", "status", "what's next", "phase check",
  or at the start of a session to orient.
  Do NOT use for running tests only (use zig build test directly).
compatibility: Claude Code only. Requires plan/ directory structure.
metadata:
  author: clojurewasm
  version: 1.0.0
---
# Phase Check

Check progress of the current development phase.

## Steps

1. Read `plan/memo.md` — identify current phase and position
2. Read active plan file in `plan/active/` — check task completion
3. Run `zig build test` — report pass/fail counts
4. Aggregate `status/vars.yaml` — implementation coverage
5. List pending tasks and recommend next action
6. Report blockers if any
7. Show latest entry from the active log file in `plan/active/`

## Output Format

Summarize as:
- Current phase: Phase N — [name]
- Tasks: X/Y completed
- Tests: N passed, M failed
- Next: [recommended task]
- Blockers: [if any]
```

### 4.3 Compatibility Test Skill

Folder structure:

```
.claude/skills/compat-test/
├── SKILL.md
└── references/
    └── edge-cases.md      # Edge case checklist
```

SKILL.md:

```markdown
---
name: compat-test
description: >
  Test compatibility of a specific function/macro against upstream Clojure.
  Use when user says "compatibility check", "compare with Clojure",
  "test against upstream", or names a specific clojure.core function to verify.
  Do NOT use for general test writing (use tdd skill instead).
compatibility: Claude Code only. Requires nREPL connection to upstream Clojure.
metadata:
  author: clojurewasm
  version: 1.0.0
---
# Compatibility Test

Test $ARGUMENTS against upstream Clojure.

## Steps

1. **Find upstream definition**: search in upstream Clojure source
   (path configured in CLAUDE.md)
2. **Verify upstream behavior**: `clj-nrepl-eval -p <port> "(fn args)"`
3. **Compare with ClojureWasm**: `clj-wasm -e "(fn args)"`
4. **Report differences** and add test cases
5. **Check edge cases**: see `references/edge-cases.md`
   - nil, empty collections, negative numbers, large values
   - type coercion boundaries, arity variations

## Output Format

| Expression       | Upstream  | ClojureWasm | Match |
|------------------|-----------|-------------|-------|
| (fn arg1)        | result    | result      | ✅/❌  |
```

references/edge-cases.md:

```markdown
# Edge Cases Checklist

## Universal Edge Cases
- nil as argument
- Empty collection: (), [], {}, #{}
- Single-element collection
- Negative numbers, zero, MAX_INT
- Empty string, very long string
- Nested structures (depth 3+)

## Type Coercion
- int vs float: (fn 1) vs (fn 1.0)
- char vs string: (fn \a) vs (fn "a")
- keyword vs symbol: (fn :a) vs (fn 'a)

## Arity
- Minimum arity
- Maximum arity (if variadic)
- Wrong arity (should throw ArityException)
```

---

## 5. Subagent Definitions

> Subagents are a Claude Code specific feature (separate from Skills).
> Each subagent runs in an independent context window and returns a summary on completion.
>
> **Key configuration fields**:
> - `tools` / `disallowedTools`: tool allowlist / denylist
> - `model`: `haiku` (fast, low-cost) / `sonnet` (balanced) / `opus` / `inherit`
> - `permissionMode`: `default` / `acceptEdits` / `dontAsk` / `bypassPermissions` / `plan`
> - `skills`: skills to inject into context at startup (parent skills are not inherited)
> - `hooks`: lifecycle hooks active only within this subagent
>
> **Usage patterns** (detailed in §5.6):
> - Verbose output isolation (test runs, log processing)
> - Parallel research (simultaneous investigation of independent modules)
> - Subagent chaining (review -> fix in sequence)
> - Resume (continue with previous work context preserved)

### 5.1 Security Reviewer

```markdown
# .claude/agents/security-reviewer.md
---
name: security-reviewer
description: >
  Read-only agent that detects security issues in Zig code.
  Use proactively when reviewing new modules, after implementing unsafe
  operations, or before phase completion. Focuses on memory safety,
  GC interactions, and input validation.
  Does not modify code — detection and reporting only.
tools: Read, Grep, Glob, Bash
disallowedTools: Edit, Write
model: sonnet
permissionMode: plan
---
Detect security issues in Zig code:

## Check Categories

1. **Memory safety**
   - Buffer overflow (missing bounds checks)
   - Use-after-free (GC interaction — values moved during collection)
   - Double-free
2. **Input validation**
   - Unvalidated external input (Reader input, file I/O)
   - Unbounded recursion (deeply nested forms)
3. **Unsafe operations**
   - @ptrCast / @intToPtr misuse
   - Integer overflow in arithmetic
   - NaN boxing bit manipulation errors
4. **GC correctness**
   - Roots not registered before allocation
   - Pointers held across GC safe points

## Output

For each issue found, provide:
- File path and line number
- Severity: Critical / High / Medium / Low
- Description of the vulnerability
- Suggested fix
```

### 5.2 Compatibility Checker

```markdown
# .claude/agents/compat-checker.md
---
name: compat-checker
description: >
  Detect behavioral differences from upstream Clojure. Use proactively
  when adding new builtins, after bulk implementation, or to audit a
  namespace. Compares docstrings, arglists, and runtime behavior.
  Do not use for general test writing (use tdd skill instead).
tools: Read, Grep, Glob, Bash
model: sonnet
skills:
  - compat-test
---
Verify compatibility of specified functions against upstream Clojure.

> The compat-test skill content (including edge-cases.md) is auto-injected.

## Steps

1. Find definition in upstream `core.clj` (path from CLAUDE.md)
2. Extract: docstring, arglists, :added metadata
3. Compare with ClojureWasm implementation
4. Run upstream via nREPL, ClojureWasm via CLI
5. Propose test cases for any differences

## Focus Areas

- Arity handling (especially variadic)
- Return type consistency
- Error messages and exception types
- nil propagation behavior
- Lazy vs eager evaluation differences

## Output

Summary table of compatibility status per function,
followed by proposed test cases for any ❌ items.
```

### 5.3 Test Runner

Isolates verbose test output from the main context.
One of the most effective subagent patterns: isolate operations that produce
large output and return only the relevant summary to the main conversation.

```markdown
# .claude/agents/test-runner.md
---
name: test-runner
description: >
  Run the test suite and return a summary of results only.
  Use proactively when running tests, when user says "run tests",
  "check test results". Isolates verbose test output from the main context.
  For debugging individual test failures, use the debugger subagent instead.
tools: Bash, Read, Grep, Glob
disallowedTools: Edit, Write
model: haiku
permissionMode: dontAsk
---
Run the test suite and summarize results concisely.

## Steps

1. Run `zig build test`
2. Parse output: extract pass/fail counts, failing test names, error messages
3. Omit verbose stack traces and compilation output; report essentials only
4. If there are failures, return the list of failing tests with error summary

## Output Format

- Test results: N pass / M fail
- Failing tests (if any):
  - Test name: error message (1 line)
- Recommended action: [identify files to fix / all passing]
```

### 5.4 Codebase Explorer

Read-only agent using Haiku model for fast, low-cost codebase exploration.
Particularly effective when launching parallel research across multiple modules.

```markdown
# .claude/agents/codebase-explorer.md
---
name: codebase-explorer
description: >
  Read-only agent for investigating codebase structure and patterns.
  Use when user says "investigate how X works", "where is X used",
  "analyze the structure of X". Can run multiple instances in parallel.
  Does not modify code — investigation and reporting only.
tools: Read, Grep, Glob
disallowedTools: Edit, Write, Bash
model: haiku
permissionMode: plan
---
Explore the codebase and investigate structure, patterns, and dependencies.

## Use Cases

- Understanding inter-module dependencies
- Finding all usage sites of a specific type or function
- Comparing structure between Beta and production
- Analyzing file organization and directory patterns

## Output Format

- Summary of what was investigated
- Findings as bullet points (with file_path:line_number)
- List of related files
- Recommendations (if any)
```

### 5.5 Debugger

Agent that analyzes root causes of test failures and build errors, and implements fixes.
Unlike security-reviewer (read-only), this has Edit access.

```markdown
# .claude/agents/debugger.md
---
name: debugger
description: >
  Analyze root causes of test failures and build errors, then fix them.
  Use proactively when encountering "test failures", "build errors",
  "fix the bug". Handles end-to-end from error analysis to code fix.
  For security reviews, use security-reviewer instead.
tools: Read, Edit, Bash, Grep, Glob
model: inherit
permissionMode: acceptEdits
---
Analyze root causes of test failures and build errors, and implement fixes.

## Steps

1. Capture error messages and stack traces
2. Identify reproduction steps
3. Isolate the failure location
4. Implement minimal fix
5. Verify fix works (`zig build test`)

## Debugging Process

- Analyze error messages and logs
- Check recent code changes (`git diff`)
- Form and test hypotheses
- Add strategic debug logging when needed
- Inspect variable states

## Output

For each issue:
- Root cause explanation
- Evidence supporting the diagnosis
- Specific code fix
- Testing approach
- Prevention recommendations

Focus on fixing the underlying issue, not the symptoms.
```

### 5.6 Subagent Usage Patterns

Usage patterns based on the Anthropic Subagent Guide.

#### Main Conversation vs Subagent

| Situation                                          | Recommended      |
|----------------------------------------------------|------------------|
| Frequent interaction or iterative refinement       | Main conversation |
| Multiple phases sharing important context          | Main conversation |
| Quick, targeted changes                            | Main conversation |
| Task producing verbose output (test runs, etc.)    | Subagent         |
| Task requiring specific tool restrictions          | Subagent         |
| Self-contained task that can return a summary      | Subagent         |
| Multiple independent investigations in parallel    | Subagent (parallel) |

#### Pattern 1: Verbose Output Isolation

Delegate test execution or log processing to test-runner, keeping main context clean.

```
Run the tests and tell me just the results
-> test-runner subagent executes zig build test
-> Main conversation receives only "42 pass / 1 fail: test_lazy_seq_gc - assertion error"
```

#### Pattern 2: Parallel Research

Run independent module investigations simultaneously. Each subagent explores
independently, and Claude synthesizes the results.

```
Investigate the Reader, VM, and GC modules in parallel using subagents
-> 3 codebase-explorer instances launch simultaneously
-> Each module summary returns, Claude generates a consolidated report
```

#### Pattern 3: Subagent Chaining

Sequential workflow where previous subagent results feed into the next.

```
Find security issues with security-reviewer, then fix them with debugger
-> security-reviewer returns issue list
-> Claude passes issue list to debugger for fixes
```

#### Pattern 4: Resume

Subagents retain their context after completion and can be resumed.
Effective for follow-up work building on previous investigation results.

```
[compat-checker verifies map, filter, reduce]
-> Complete

Resume that compatibility check and also verify take and drop
-> Resumes with full context (map, filter, reduce results) preserved
```

> **Note**: Subagents cannot spawn other subagents.
> For nested workflows, chain subagents from the main conversation.

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
- Delegate test runs to test-runner (isolate verbose output from main context)
- Launch multiple codebase-explorer instances in parallel for multi-module research
- Use Ctrl+B to move running tasks to background
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

Can also be done within a single session using subagent chaining:

```
"Implement Value type via TDD. When done,
 use security-reviewer to check GC interactions"
-> Main conversation implements -> auto-delegates to security-reviewer -> returns results
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
  - Verbose output isolation (test runs) is the most effective pattern
  - Use Haiku model for fast, low-cost exploration tasks
  - `skills` field pre-injects skill content into subagent context
  - Subagents can be resumed (previous context preserved)
- Hooks guarantee deterministic behavior (CLAUDE.md instructions are advisory)
- Skills load domain knowledge only when needed
- Use Writer/Reviewer pattern with parallel sessions

### Sources

- [Claude Code Best Practices (Anthropic official)](https://code.claude.com/docs/en/best-practices)
- [t-wada: TDD in the AI Agent Era (Agile Journey)](https://agilejourney.uzabase.com/entry/2025/08/29/103000)
- [Name+Technique List for Claude (t-wada TDD)](https://memory-lovers.blog/entry/2025/06/27/102550)
