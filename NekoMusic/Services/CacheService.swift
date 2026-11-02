import Foundation
import UIKit

/// 本地缓存统计与清理
enum CacheService {
    /// 可清理的缓存总量（字节）
    static func totalBytes() -> Int64 {
        var total = Int64(URLCache.shared.currentDiskUsage) + Int64(URLCache.shared.currentMemoryUsage)
        total += directorySize(FileManager.default.temporaryDirectory)
        return total
    }

    static func formattedSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalBytes(), countStyle: .file)
    }

    static func clear() {
        URLCache.shared.removeAllCachedResponses()
        RemoteImageCache.shared.clear()
        clearDirectory(FileManager.default.temporaryDirectory)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(into: Int64(0)) { sum, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sum += Int64(size)
        }
    }

    private static func clearDirectory(_ url: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
