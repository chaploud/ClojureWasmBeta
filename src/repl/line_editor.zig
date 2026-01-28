//! 行エディタ — readline 風の行編集・履歴機能
//!
//! 機能:
//! - 左右矢印でカーソル移動
//! - Home/End (Ctrl-A/E)
//! - Ctrl-K (行末まで削除), Ctrl-U (行頭まで削除)
//! - Ctrl-W (前の単語を削除)
//! - Ctrl-D (EOF / カーソル位置の文字削除)
//! - Ctrl-L (画面クリア)
//! - Backspace / Delete
//! - 上下矢印で履歴ナビゲーション
//! - 履歴ファイル保存/読み込み

const std = @import("std");
const posix = std.posix;

/// 最大行長
const MAX_LINE = 4096;
/// 最大履歴エントリ数
const MAX_HISTORY = 500;
/// macOS cc indices
const VMIN = 16;
const VTIME = 17;

pub const LineEditor = struct {
    /// 行バッファ
    buf: [MAX_LINE]u8 = undefined,
    /// 現在の行長
    len: usize = 0,
    /// カーソル位置
    pos: usize = 0,
    /// 履歴
    history: std.ArrayListUnmanaged([]u8) = .empty,
    /// 履歴ナビゲーション位置 (-1 = 現在行)
    history_idx: isize = -1,
    /// 編集中の現在行 (履歴ナビ中に保存)
    saved_line: ?[]u8 = null,
    /// 元のターミナル設定
    orig_termios: ?posix.termios = null,
    /// stdin ファイルハンドル
    stdin_handle: posix.fd_t,
    /// stdout ファイルハンドル
    stdout_handle: posix.fd_t,
    /// TTY かどうか
    is_tty: bool,
    /// アロケータ
    allocator: std.mem.Allocator,
    /// 履歴ファイルパス
    history_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) LineEditor {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        return .{
            .stdin_handle = stdin.handle,
            .stdout_handle = stdout.handle,
            .is_tty = stdin.isTty(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        // 履歴エントリを解放
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        if (self.saved_line) |s| {
            self.allocator.free(s);
        }
        if (self.history_path) |p| {
            self.allocator.free(p);
        }
    }

    // ============================================================
    // Raw モード
    // ============================================================

    fn enableRawMode(self: *LineEditor) !void {
        if (!self.is_tty) return;
        if (self.orig_termios != null) return; // 既に raw

        var raw = try posix.tcgetattr(self.stdin_handle);
        self.orig_termios = raw;

        // raw モード設定
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // VMIN=1, VTIME=0: 1 バイト読むまでブロック
        raw.cc[VMIN] = 1;
        raw.cc[VTIME] = 0;

        try posix.tcsetattr(self.stdin_handle, .FLUSH, raw);
    }

    fn disableRawMode(self: *LineEditor) void {
        if (self.orig_termios) |orig| {
            posix.tcsetattr(self.stdin_handle, .FLUSH, orig) catch {};
            self.orig_termios = null;
        }
    }

    // ============================================================
    // 出力ヘルパー
    // ============================================================

    fn writeOut(self: *LineEditor, data: []const u8) void {
        _ = posix.write(self.stdout_handle, data) catch {};
    }

    fn writeOutByte(self: *LineEditor, byte: u8) void {
        const b = [1]u8{byte};
        self.writeOut(&b);
    }

    /// 現在行を再描画
    fn refreshLine(self: *LineEditor, prompt: []const u8) void {
        // カーソルを行頭に移動して行をクリア
        self.writeOut("\r"); // 行頭へ
        self.writeOut(prompt);
        self.writeOut(self.buf[0..self.len]);
        // カーソル以降をクリア
        self.writeOut("\x1b[K");
        // カーソル位置に移動
        if (self.pos < self.len) {
            // \r で行頭に戻って prompt + pos 分進む
            self.writeOut("\r");
            self.writeOut(prompt);
            self.writeOut(self.buf[0..self.pos]);
        }
    }

    // ============================================================
    // 1 バイト読み取り
    // ============================================================

    fn readByte(self: *LineEditor) !?u8 {
        var c: [1]u8 = undefined;
        const n = posix.read(self.stdin_handle, &c) catch |err| {
            switch (err) {
                error.WouldBlock => return null,
                else => return err,
            }
        };
        if (n == 0) return null; // EOF
        return c[0];
    }

    // ============================================================
    // 編集操作
    // ============================================================

    fn insertChar(self: *LineEditor, c: u8) void {
        if (self.len >= MAX_LINE - 1) return;
        // カーソル位置に挿入
        if (self.pos < self.len) {
            // 後ろにずらす
            var i: usize = self.len;
            while (i > self.pos) : (i -= 1) {
                self.buf[i] = self.buf[i - 1];
            }
        }
        self.buf[self.pos] = c;
        self.pos += 1;
        self.len += 1;
    }

    fn deleteCharAtCursor(self: *LineEditor) void {
        if (self.pos >= self.len) return;
        // 前にずらす
        var i = self.pos;
        while (i < self.len - 1) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
    }

    fn backspace(self: *LineEditor) void {
        if (self.pos == 0) return;
        self.pos -= 1;
        self.deleteCharAtCursor();
    }

    fn killToEnd(self: *LineEditor) void {
        self.len = self.pos;
    }

    fn killToStart(self: *LineEditor) void {
        if (self.pos == 0) return;
        const n = self.pos;
        var i: usize = 0;
        while (i < self.len - n) : (i += 1) {
            self.buf[i] = self.buf[i + n];
        }
        self.len -= n;
        self.pos = 0;
    }

    fn killPrevWord(self: *LineEditor) void {
        if (self.pos == 0) return;
        var old_pos = self.pos;
        // スペースをスキップ
        while (old_pos > 0 and self.buf[old_pos - 1] == ' ') {
            old_pos -= 1;
        }
        // 単語をスキップ
        while (old_pos > 0 and self.buf[old_pos - 1] != ' ') {
            old_pos -= 1;
        }
        const diff = self.pos - old_pos;
        var i: usize = old_pos;
        while (i < self.len - diff) : (i += 1) {
            self.buf[i] = self.buf[i + diff];
        }
        self.len -= diff;
        self.pos = old_pos;
    }

    // ============================================================
    // 履歴
    // ============================================================

    pub fn addHistory(self: *LineEditor, line: []const u8) !void {
        if (line.len == 0) return;
        // 直前と同じなら追加しない
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }
        // 最大数を超えたら古いものを削除
        if (self.history.items.len >= MAX_HISTORY) {
            self.allocator.free(self.history.items[0]);
            // 前にずらす
            var i: usize = 0;
            while (i < self.history.items.len - 1) : (i += 1) {
                self.history.items[i] = self.history.items[i + 1];
            }
            self.history.items.len -= 1;
        }
        const copy = try self.allocator.dupe(u8, line);
        try self.history.append(self.allocator, copy);
    }

    fn historyUp(self: *LineEditor) void {
        if (self.history.items.len == 0) return;
        const max_idx: isize = @intCast(self.history.items.len);

        if (self.history_idx == -1) {
            // 現在行を保存
            if (self.saved_line) |s| self.allocator.free(s);
            self.saved_line = self.allocator.dupe(u8, self.buf[0..self.len]) catch null;
            self.history_idx = max_idx - 1;
        } else if (self.history_idx > 0) {
            self.history_idx -= 1;
        } else {
            return; // 最古
        }

        const entry = self.history.items[@intCast(self.history_idx)];
        const copy_len = @min(entry.len, MAX_LINE - 1);
        @memcpy(self.buf[0..copy_len], entry[0..copy_len]);
        self.len = copy_len;
        self.pos = copy_len;
    }

    fn historyDown(self: *LineEditor) void {
        if (self.history_idx == -1) return;

        const max_idx: isize = @intCast(self.history.items.len);
        if (self.history_idx < max_idx - 1) {
            self.history_idx += 1;
            const entry = self.history.items[@intCast(self.history_idx)];
            const copy_len = @min(entry.len, MAX_LINE - 1);
            @memcpy(self.buf[0..copy_len], entry[0..copy_len]);
            self.len = copy_len;
            self.pos = copy_len;
        } else {
            // 現在行に戻る
            self.history_idx = -1;
            if (self.saved_line) |s| {
                const copy_len = @min(s.len, MAX_LINE - 1);
                @memcpy(self.buf[0..copy_len], s[0..copy_len]);
                self.len = copy_len;
                self.pos = copy_len;
                self.allocator.free(s);
                self.saved_line = null;
            } else {
                self.len = 0;
                self.pos = 0;
            }
        }
    }

    // ============================================================
    // 履歴ファイル
    // ============================================================

    pub fn setHistoryPath(self: *LineEditor, path: []const u8) !void {
        if (self.history_path) |p| self.allocator.free(p);
        self.history_path = try self.allocator.dupe(u8, path);
    }

    pub fn loadHistory(self: *LineEditor) void {
        const path = self.history_path orelse return;
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);
        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch break;
            if (line) |l| {
                self.addHistory(l) catch break;
            } else break;
        }
    }

    pub fn saveHistory(self: *LineEditor) void {
        const path = self.history_path orelse return;
        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();
        for (self.history.items) |entry| {
            _ = file.write(entry) catch return;
            _ = file.write("\n") catch return;
        }
    }

    // ============================================================
    // メインの行読み取り
    // ============================================================

    /// 1 行を読み取る。EOF なら null を返す。
    pub fn readLine(self: *LineEditor, prompt: []const u8) !?[]const u8 {
        if (!self.is_tty) {
            return self.readLineDumb();
        }

        try self.enableRawMode();
        defer self.disableRawMode();

        self.len = 0;
        self.pos = 0;
        self.history_idx = -1;

        // プロンプト表示
        self.writeOut(prompt);

        while (true) {
            const byte = try self.readByte() orelse {
                // EOF
                if (self.len == 0) {
                    self.writeOut("\r\n");
                    return null;
                }
                // 未確定の入力がある場合は返す
                break;
            };

            switch (byte) {
                '\r', '\n' => {
                    // Enter: 行を確定
                    self.writeOut("\r\n");
                    break;
                },
                4 => {
                    // Ctrl-D
                    if (self.len == 0) {
                        // 空行で Ctrl-D → EOF
                        self.writeOut("\r\n");
                        return null;
                    }
                    // 文字がある場合は Delete と同じ
                    self.deleteCharAtCursor();
                    self.refreshLine(prompt);
                },
                1 => {
                    // Ctrl-A: 行頭
                    self.pos = 0;
                    self.refreshLine(prompt);
                },
                5 => {
                    // Ctrl-E: 行末
                    self.pos = self.len;
                    self.refreshLine(prompt);
                },
                2 => {
                    // Ctrl-B: 左
                    if (self.pos > 0) {
                        self.pos -= 1;
                        self.refreshLine(prompt);
                    }
                },
                6 => {
                    // Ctrl-F: 右
                    if (self.pos < self.len) {
                        self.pos += 1;
                        self.refreshLine(prompt);
                    }
                },
                11 => {
                    // Ctrl-K: 行末まで削除
                    self.killToEnd();
                    self.refreshLine(prompt);
                },
                21 => {
                    // Ctrl-U: 行頭まで削除
                    self.killToStart();
                    self.refreshLine(prompt);
                },
                23 => {
                    // Ctrl-W: 前の単語を削除
                    self.killPrevWord();
                    self.refreshLine(prompt);
                },
                12 => {
                    // Ctrl-L: 画面クリア
                    self.writeOut("\x1b[H\x1b[2J");
                    self.refreshLine(prompt);
                },
                8, 127 => {
                    // Backspace / Ctrl-H
                    self.backspace();
                    self.refreshLine(prompt);
                },
                27 => {
                    // ESC シーケンス
                    const seq1 = try self.readByte() orelse continue;
                    if (seq1 == '[') {
                        const seq2 = try self.readByte() orelse continue;
                        switch (seq2) {
                            'A' => {
                                // 上矢印: 履歴を遡る
                                self.historyUp();
                                self.refreshLine(prompt);
                            },
                            'B' => {
                                // 下矢印: 履歴を進む
                                self.historyDown();
                                self.refreshLine(prompt);
                            },
                            'C' => {
                                // 右矢印
                                if (self.pos < self.len) {
                                    self.pos += 1;
                                    self.refreshLine(prompt);
                                }
                            },
                            'D' => {
                                // 左矢印
                                if (self.pos > 0) {
                                    self.pos -= 1;
                                    self.refreshLine(prompt);
                                }
                            },
                            'H' => {
                                // Home
                                self.pos = 0;
                                self.refreshLine(prompt);
                            },
                            'F' => {
                                // End
                                self.pos = self.len;
                                self.refreshLine(prompt);
                            },
                            '3' => {
                                // Delete key: ESC [ 3 ~
                                const seq3 = try self.readByte() orelse continue;
                                if (seq3 == '~') {
                                    self.deleteCharAtCursor();
                                    self.refreshLine(prompt);
                                }
                            },
                            '1' => {
                                // Home: ESC [ 1 ~
                                const seq3 = try self.readByte() orelse continue;
                                if (seq3 == '~') {
                                    self.pos = 0;
                                    self.refreshLine(prompt);
                                }
                            },
                            '4' => {
                                // End: ESC [ 4 ~
                                const seq3 = try self.readByte() orelse continue;
                                if (seq3 == '~') {
                                    self.pos = self.len;
                                    self.refreshLine(prompt);
                                }
                            },
                            else => {},
                        }
                    } else if (seq1 == 'O') {
                        const seq2 = try self.readByte() orelse continue;
                        switch (seq2) {
                            'H' => {
                                // Home
                                self.pos = 0;
                                self.refreshLine(prompt);
                            },
                            'F' => {
                                // End
                                self.pos = self.len;
                                self.refreshLine(prompt);
                            },
                            else => {},
                        }
                    }
                },
                else => {
                    // 通常文字
                    if (byte >= 32) {
                        self.insertChar(byte);
                        self.refreshLine(prompt);
                    }
                },
            }
        }

        return self.buf[0..self.len];
    }

    /// 非 TTY 用: 単純な行読み取り
    fn readLineDumb(self: *LineEditor) !?[]const u8 {
        self.len = 0;
        while (true) {
            const byte = try self.readByte() orelse {
                if (self.len == 0) return null;
                break;
            };
            if (byte == '\n' or byte == '\r') break;
            if (self.len < MAX_LINE - 1) {
                self.buf[self.len] = byte;
                self.len += 1;
            }
        }
        return self.buf[0..self.len];
    }
};
