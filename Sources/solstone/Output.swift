// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin

/// Unbuffered stdout output
public enum Stdout {
    /// Configure stdout for unbuffered output (call once at startup)
    public static func setUnbuffered() {
        setbuf(stdout, nil)
    }

    /// Print a line to stdout (with newline, flushed immediately)
    public static func print(_ message: String) {
        fputs(message + "\n", stdout)
    }
}

/// Unbuffered stderr output
public enum Stderr {
    /// Configure stderr for unbuffered output (call once at startup)
    public static func setUnbuffered() {
        setbuf(stderr, nil)
    }

    /// Print a line to stderr (with newline)
    public static func print(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
