# ClojureWasmBeta

Clojure implementation in Zig, targeting WebAssembly.

## Goals

- Behavioral compatibility with Clojure (black-box)
- No JavaInterOp reimplementation
- Fast execution via bytecode VM (future)
- Runs on WebAssembly

## Status

Planning phase. See `plan/` directory for design documents.

## Build

```bash
zig build
zig build test
zig build run
```

## License

TBD
