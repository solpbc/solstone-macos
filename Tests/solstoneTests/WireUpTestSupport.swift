// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

func readWireUpSource(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func wireUpContains(_ source: String, _ reference: String) -> Bool {
    source.filter { !$0.isWhitespace }.contains(reference.filter { !$0.isWhitespace })
}
