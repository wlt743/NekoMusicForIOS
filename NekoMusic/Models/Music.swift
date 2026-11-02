import Foundation

struct Music: Identifiable, Equatable, Hashable, Encodable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let duration: Int
    let filePath: String?
    let coverFilePath: String?
    let uploadUserId: Int?
    let createdAt: String?
    let playCount: Int?
    let lrc: Bool?
    
    var coverUrl: String {
        if let cover = coverFilePath, !cover.isEmpty {
            return cover
        }
        return "/api/music/cover/\(id)"
    }
    
    static func == (lhs: Music, rhs: Music) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    /// Parse a Music object from a JSON dictionary
    static func fromJSON(_ dict: [String: Any]) -> Music? {
        guard let id = dict["id"] as? Int else { return nil }
        
        let title = dict["title"] as? String ?? "未知歌曲"
        let artist = dict["artist"] as? String ?? "未知歌手"
        let album = dict["album"] as? String ?? ""
        
        let duration: Int
        if let d = dict["duration"] as? Int {
            duration = d
        } else if let d = dict["duration"] as? Double {
            duration = Int(d)
        } else if let d = dict["duration"] as? String, let parsed = Int(d) {
            duration = parsed
        } else {
            duration = 0
        }
        
        let filePath = dict["filePath"] as? String
        
        // Cover: try coverFilePath, then coverPath, then coverUrl
        let coverFilePath: String?
        if let cfp = dict["coverFilePath"] as? String, !cfp.isEmpty {
            coverFilePath = cfp
        } else if let cp = dict["coverPath"] as? String, !cp.isEmpty {
            coverFilePath = cp
        } else if let cu = dict["coverUrl"] as? String, !cu.isEmpty {
            coverFilePath = cu
        } else {
            coverFilePath = nil
        }
        
        let uploadUserId = dict["uploadUserId"] as? Int
        let createdAt = dict["createdAt"] as? String
        let playCount = dict["playCount"] as? Int
        
        let lrc: Bool?
        if let b = dict["lrc"] as? Bool {
            lrc = b
        } else if let i = dict["lrc"] as? Int {
            lrc = i != 0
        } else {
            lrc = nil
        }
        
        return Music(
            id: id, title: title, artist: artist, album: album, duration: duration,
            filePath: filePath, coverFilePath: coverFilePath, uploadUserId: uploadUserId,
            createdAt: createdAt, playCount: playCount, lrc: lrc
        )
    }
    
    /// Parse an array of Music from a JSON array of dictionaries
    static func fromJSONArray(_ array: [[String: Any]]) -> [Music] {
        return array.compactMap { fromJSON($0) }
    }
    
    /// Parse an array of Music from raw Data
    static func parseArray(from data: Data) -> [Music] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return fromJSONArray(array)
    }
}

struct SearchRequest: Encodable {
    let query: String
}

struct SearchItem: Encodable {
    let title: String
    let artist: String
}

struct BatchSearchRequest: Encodable {
    let items: [SearchItem]
}
