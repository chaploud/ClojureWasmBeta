# ClojureWasmBeta

Clojure implementation in Zig, targeting WebAssembly.

## Goals

- Behavioral compatibility with Clojure (black-box)
- No JavaInterOp reimplementation
- Fast execution via bytecode VM
- Runs on WebAssembly (future)

## Status

- **Tests**: 1036 pass / 1 fail (intentional)
- **Core vars**: 545 done / 169 skip
- **Dual backend**: TreeWalk (correctness) + BytecodeVM (performance)
- **GC**: Semi-space Arena Mark-Sweep at expression boundary
- **Wasm**: zware integration (10 API functions)
- **nREPL**: CIDER/Calva/Conjure compatible server
- **Standard namespaces**: string, set, walk, edn, math, repl, data, stacktrace, template, zip, test

### Features

- Special forms, control flow, closures, multi-arity functions
- Destructuring bindings (sequential and map)
- Lazy sequences (map, filter, concat, range, iterate, repeat, cycle)
- Exception handling (try/catch/finally)
- Atoms, Delay, Promise, Volatile, Reduced, Transient
- Multimethods (defmulti, defmethod) with hierarchy
- Protocols (defprotocol, extend-type, extend-protocol)
- Namespaces (require, use, refer, alias, in-ns)
- Regular expressions (full scratch Zig implementation)
- Dynamic bindings (binding, with-redefs)
- REPL with readline, history, doc/dir/find-doc/apropos
- Wasm module loading, function invocation, memory I/O, host functions, WASI

See `status/vars.yaml` for detailed implementation tracking.

## Build

```bash
zig build
zig build test
```

## Usage

```bash
# Evaluate expression
clj-wasm -e "(+ 1 2)"

# Run a script file
clj-wasm script.clj

# Compare both backends
clj-wasm --compare -e "(+ 1 2)"

# Bytecode dump (debugging)
clj-wasm --dump-bytecode -e "(defn f [x] (+ x 1))"

# GC statistics
clj-wasm --gc-stats -e '(dotimes [_ 1000] (vec (range 100)))'

# Start REPL (no arguments)
clj-wasm

# Start nREPL server
clj-wasm --nrepl-server --port=7888
```

## License

TBD
