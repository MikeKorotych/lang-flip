import Foundation

// Mapping by physical key position. Each row has the same length across layouts —
// chars at the same index live on the same physical key.
//
// Reference: macOS built-in "ABC" (US), "Ukrainian" and "Russian — PC" layouts.

enum Layout: String, CaseIterable {
    case en, uk, ru
}

private let rows: [Layout: [String]] = [
    .en: [
        "`1234567890-=",
        "qwertyuiop[]\\",
        "asdfghjkl;'",
        "zxcvbnm,./"
    ],
    .uk: [
        "'1234567890-=",
        "йцукенгшщзхї\\",
        "фівапролджє",
        "ячсмитьбю."
    ],
    .ru: [
        "ё1234567890-=",
        "йцукенгшщзхъ\\",
        "фывапролджэ",
        "ячсмитьбю."
    ]
]

private let shiftedRows: [Layout: [String]] = [
    .en: [
        "~!@#$%^&*()_+",
        "QWERTYUIOP{}|",
        "ASDFGHJKL:\"",
        "ZXCVBNM<>?"
    ],
    .uk: [
        "~!\"№;%:?*()_+",
        "ЙЦУКЕНГШЩЗХЇ/",
        "ФІВАПРОЛДЖЄ",
        "ЯЧСМИТЬБЮ,"
    ],
    .ru: [
        "Ё!\"№;%:?*()_+",
        "ЙЦУКЕНГШЩЗХЪ/",
        "ФЫВАПРОЛДЖЭ",
        "ЯЧСМИТЬБЮ,"
    ]
]

/// Returns the dictionary that maps each character of `from` to the character
/// at the same physical key in `to`. Both upper- and lower-case are included.
func charMap(from: Layout, to: Layout) -> [Character: Character] {
    var result: [Character: Character] = [:]
    for (rowsTable) in [rows, shiftedRows] {
        guard let src = rowsTable[from], let dst = rowsTable[to] else { continue }
        for (rowIdx, srcRow) in src.enumerated() {
            let dstRow = dst[rowIdx]
            let srcChars = Array(srcRow)
            let dstChars = Array(dstRow)
            for (i, ch) in srcChars.enumerated() where i < dstChars.count {
                result[ch] = dstChars[i]
            }
        }
    }
    return result
}

/// Detects which layout a string was most likely typed in, by counting how
/// many of its alphabetic characters belong to each layout's alphabet.
func detectLayout(_ s: String) -> Layout? {
    var counts: [Layout: Int] = [:]
    let alphabets: [Layout: Set<Character>] = [
        .en: Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        .uk: Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюяАБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯ'"),
        .ru: Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
    ]
    for ch in s {
        for (lang, alpha) in alphabets where alpha.contains(ch) {
            counts[lang, default: 0] += 1
        }
    }
    return counts.max(by: { $0.value < $1.value })?.key
}

/// Convert a string from one layout to another, character-by-character.
func convert(_ s: String, from: Layout, to: Layout) -> String {
    let map = charMap(from: from, to: to)
    return String(s.map { map[$0] ?? $0 })
}
