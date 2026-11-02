import Foundation

/// LRC 解析，供歌词页与系统「正在播放」共用。
enum LyricsParser {
    static func parse(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []
        let lines = lrc.components(separatedBy: "\n")

        for line in lines {
            let pattern = "\\[(\\d{2}):(\\d{2})\\.?(\\d{0,3})\\](.*)$"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                continue
            }

            guard let minRange = Range(match.range(at: 1), in: line),
                  let secRange = Range(match.range(at: 2), in: line) else { continue }

            let min = Double(line[minRange]) ?? 0
            let sec = Double(line[secRange]) ?? 0

            var ms: Double = 0
            let msRange = match.range(at: 3)
            if msRange.location != NSNotFound, let range = Range(msRange, in: line) {
                let msStr = String(line[range])
                if !msStr.isEmpty {
                    ms = (Double(msStr) ?? 0) / (msStr.count == 2 ? 100 : 1000)
                }
            }

            let time = min * 60 + sec + ms

            var text = ""
            let textRange = match.range(at: 4)
            if textRange.location != NSNotFound, let range = Range(textRange, in: line) {
                text = String(line[range]).trimmingCharacters(in: .whitespaces)
            }

            if !text.isEmpty {
                result.append((time, text))
            }
        }

        return result.sorted { $0.0 < $1.0 }
    }

    /// 当前时间对应的歌词行下标，没有则返回 -1
    static func index(at position: TimeInterval, in lines: [(time: TimeInterval, text: String)]) -> Int {
        guard !lines.isEmpty else { return -1 }
        var index = -1
        for (i, line) in lines.enumerated() where position >= line.time {
            index = i
        }
        return index
    }
}
