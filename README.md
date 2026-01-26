# ClojureWasmBeta

Clojure implementation in Zig, targeting WebAssembly.

## Goals

- Behavioral compatibility with Clojure (black-box)
- No JavaInterOp reimplementation
- Fast execution via bytecode VM
- Runs on WebAssembly (future)

## Status

Phase 8.16 complete. Dual-backend evaluation (TreeWalk + VM) with 141 implemented core vars including:
- Special forms, control flow, closures, multi-arity functions
- Destructuring bindings (sequential and map)
- Sequence operations (map, filter, take, drop, etc.)
- Exception handling (try/catch/finally)
- Atoms (atom, deref, reset!, swap!)
- Multimethods (defmulti, defmethod)
- Protocols (defprotocol, extend-type, extend-protocol)
- Threading macros, utility functions, higher-order functions

See `status/vars.yaml` for detailed implementation tracking.

## Build

```bash
zig build
zig build test
```

## Usage

```bash
# Evaluate expression
./zig-out/bin/ClojureWasmBeta -e "(+ 1 2)"

# VM backend
./zig-out/bin/ClojureWasmBeta --backend=vm -e "(+ 1 2)"

# Compare both backends
./zig-out/bin/ClojureWasmBeta --compare -e "(+ 1 2)"
```

## License

TBD
