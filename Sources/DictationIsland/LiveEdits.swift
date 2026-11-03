import Foundation

/// One word of the transcript as the island draws it. With live edits on, a word the recognizer
/// (or the clean-up) changed shows green for a moment, and a word it dropped stays put, struck
/// through in red, before it fades out.
struct LiveWord: Identifiable, Equatable {
    enum Mark: Equatable {
        case plain
        /// New text that replaced something: a revision, a Words-list fix, the tidy-up.
        case fixed
        /// Text that was taken out; drawn struck through until it expires.
        case dropped
    }

    let id: Int
    var text: String
    var mark: Mark
    /// When a fixed word turns plain again, or a dropped one goes away.
    var until: Date?
}

/// The island's words, kept in step with the transcript by diffing each new version against
/// what's on screen. Words that stay keep their identity, so they never re-animate.
struct LiveWordTrack {
    private(set) var words: [LiveWord] = []
    private var nextID = 0

    static let fixedFor: TimeInterval = 1.4
    static let droppedFor: TimeInterval = 1.1

    /// The text without the dropped words, as it reads now.
    var text: [String] { words.filter { $0.mark != .dropped }.map(\.text) }

    var hasMarks: Bool { words.contains { $0.mark != .plain } }

    /// The soonest time a mark changes, for scheduling `prune`.
    var nextExpiry: Date? { words.compactMap(\.until).min() }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Moves the words to `newWords`.
    /// - mark: show what changed. Off, it simply resets (no colours, no struck-out words).
    /// - corrections: words in `newWords` a Words-list rule wrote, with the heard words they
    ///   replaced (see `corrections(raw:corrected:)`); they show as fixed even at the very end,
    ///   where new words otherwise just appear.
    mutating func update(to newWords: [String], mark: Bool, corrections: Corrections = .none, now: Date = Date()) {
        var live: [LiveWord] = []
        // Dropped words still on screen, each kept just before the live word that followed it.
        var ghostsBefore: [[LiveWord]] = [[]]
        for word in words {
            if word.mark == .dropped {
                ghostsBefore[live.count].append(word)
            } else {
                live.append(word)
                ghostsBefore.append([])
            }
        }
        // Matched ignoring case and punctuation, so "now" becoming "Now." is the same word,
        // refined, rather than one struck out and another added.
        let ops = WordDiff.ops(live.map { Self.key($0.text) }, newWords.map(Self.key))
        // Words added after the last old word are just the next words spoken, except as many as
        // the words dropped right there, which they replace.
        let lastSame = ops.lastIndex { if case .same = $0 { return true } else { return false } }
        let tailStart = (lastSame ?? -1) + 1
        var tailReplacements = ops[tailStart...].filter { if case .removed = $0 { return true } else { return false } }.count

        var result: [LiveWord] = []
        for (n, op) in ops.enumerated() {
            switch op {
            case .same(let i, let j):
                if mark { result += ghostsBefore[i] }
                var word = live[i]
                if !mark {
                    word.mark = .plain
                    word.until = nil
                } else if word.text != newWords[j] {
                    word.mark = .fixed
                    word.until = now + Self.fixedFor
                }
                word.text = newWords[j]
                result.append(word)
            case .removed(let i):
                if mark {
                    result += ghostsBefore[i]
                    var word = live[i]
                    word.mark = .dropped
                    word.until = now + Self.droppedFor
                    result.append(word)
                }
            case .added(let j):
                var fixed = n < tailStart || corrections.written.contains(j)
                if n >= tailStart, tailReplacements > 0 {
                    fixed = true
                    tailReplacements -= 1
                }
                fixed = fixed && mark
                // A word that went away and came straight back: no need to show it struck out.
                if mark, let back = result.lastIndex(where: { $0.mark == .dropped && Self.key($0.text) == Self.key(newWords[j]) }),
                   result[back...].allSatisfy({ $0.mark == .dropped }) {
                    result.remove(at: back)
                }
                if mark, let heard = corrections.heard[j] {
                    // Show what was misheard, struck out, right before the fix.
                    for text in heard {
                        result.append(LiveWord(id: makeID(), text: text, mark: .dropped, until: now + Self.droppedFor))
                    }
                }
                result.append(LiveWord(id: makeID(), text: newWords[j], mark: fixed ? .fixed : .plain, until: fixed ? now + Self.fixedFor : nil))
            }
        }
        if mark { result += ghostsBefore[live.count] }
        words = result
    }

    /// Expires marks whose time is up. Returns whether anything changed.
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        var changed = false
        words = words.compactMap { word in
            guard let until = word.until, until <= now else { return word }
            changed = true
            if word.mark == .dropped { return nil }
            var word = word
            word.mark = .plain
            word.until = nil
            return word
        }
        return changed
    }

    /// How words are matched: lower case, without surrounding punctuation.
    static func key(_ word: String) -> String {
        let trimmed = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return trimmed.isEmpty ? word : trimmed
    }

    private mutating func makeID() -> Int {
        nextID += 1
        return nextID
    }

    /// What a Words-list pass changed in a partial: indices into the corrected words, and for
    /// the first word of each fix, the heard words it replaced.
    struct Corrections {
        var written: Set<Int> = []
        var heard: [Int: [String]] = [:]
        static let none = Corrections()
    }

    static func corrections(raw: [String], corrected: [String]) -> Corrections {
        guard raw != corrected else { return .none }
        var result = Corrections()
        var pendingHeard: [String] = []
        for op in WordDiff.ops(raw.map(key), corrected.map(key)) {
            switch op {
            case .removed(let i): pendingHeard.append(raw[i])
            case .added(let j):
                result.written.insert(j)
                if !pendingHeard.isEmpty {
                    result.heard[j] = pendingHeard
                    pendingHeard = []
                }
            case .same: pendingHeard = []
            }
        }
        return result
    }
}

/// Word-level diff: the longest common subsequence, with the common start and end trimmed off
/// first so the usual case (a few words changed near the end) stays linear.
enum WordDiff {
    enum Op: Equatable {
        case same(Int, Int)
        case removed(Int)
        case added(Int)
    }

    static func ops(_ a: [String], _ b: [String]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        var result = (0..<prefix).map { Op.same($0, $0) }
        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        result += middle(aMid, bMid).map { op in
            switch op {
            case .same(let i, let j): return .same(i + prefix, j + prefix)
            case .removed(let i): return .removed(i + prefix)
            case .added(let j): return .added(j + prefix)
            }
        }
        result += (0..<suffix).map { .same(a.count - suffix + $0, b.count - suffix + $0) }
        return result
    }

    /// Within one changed stretch, removals come before the additions that replace them.
    private static func middle(_ a: [String], _ b: [String]) -> [Op] {
        if a.isEmpty { return b.indices.map { .added($0) } }
        if b.isEmpty { return a.indices.map { .removed($0) } }
        // A huge rewrite isn't worth the table: show it as replaced wholesale.
        guard a.count * b.count <= 250_000 else {
            return a.indices.map { .removed($0) } + b.indices.map { .added($0) }
        }
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                ops.append(.same(i, j))
                i += 1
                j += 1
            } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                ops.append(.removed(i))
                i += 1
            } else {
                ops.append(.added(j))
                j += 1
            }
        }
        return ops
    }
}
