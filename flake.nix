{
  description = "ClojureWasmBeta - Zig で Clojure 処理系をフルスクラッチ実装";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Zig 公式オーバーレイ (最新リリースを追跡)
    zig-overlay.url = "github:ziglang/zig/0.15.2";
    zig-overlay.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Zig 0.15.2 バイナリ (builtins.fetchTarball で評価時展開 → サンドボックス回避)
        zigSrc = builtins.fetchTarball {
          url =
            if system == "aarch64-darwin" then
              "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
            else if system == "x86_64-darwin" then
              "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz"
            else if system == "x86_64-linux" then
              "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz"
            else if system == "aarch64-linux" then
              "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz"
            else throw "Unsupported system: ${system}";
          sha256 = "1csy5ch8aym67w06ffmlwamrzkfq8zwv4kcl6bcpc5vn1cbhd31g";
        };

        # パスラッパー: nix store 内の展開済みディレクトリを PATH に載せる
        zigBin = pkgs.runCommand "zig-0.15.2-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "clojure-wasm-beta";

          buildInputs = with pkgs; [
            # === コンパイラ・ランタイム ===
            zigBin                    # Zig 0.15.2 (メインコンパイラ)
            wasmtime                  # Wasm ランタイム

            # === ベンチマーク・計測 ===
            hyperfine                 # 高精度ベンチマーク
            yq-go                     # YAML 処理 (mikefarah/yq)
            jq                        # JSON 処理

            # === ベンチマーク比較言語 ===
            clojure                   # Clojure CLI
            jdk21                     # OpenJDK 21 (Clojure 用)
            babashka                  # Babashka
            python3                   # Python

            # === ユーティリティ ===
            gnused                    # GNU sed (macOS 互換)
            coreutils                 # GNU coreutils
          ];

          shellHook = ''
            echo "ClojureWasmBeta 開発環境"
            echo "  Zig:       $(zig version 2>/dev/null || echo 'loading...')"
            echo "  wasmtime:  $(wasmtime --version 2>/dev/null || echo 'N/A')"
            echo "  Clojure:   $(clojure --version 2>/dev/null || echo 'N/A')"
            echo "  Java:      $(java -version 2>&1 | head -1)"
            echo "  Babashka:  $(bb --version 2>/dev/null || echo 'N/A')"
            echo "  Python:    $(python3 --version 2>/dev/null)"
            echo "  hyperfine: $(hyperfine --version 2>/dev/null)"
            echo "  yq:        $(yq --version 2>/dev/null)"
          '';
        };
      }
    );
}
