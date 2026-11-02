import Foundation

class FavoriteService {
    static let shared = FavoriteService()
    private let network = NetworkService.shared
    
    private init() {}
    
    func getFavorites(token: String) async throws -> [FavoriteMusic] {
        let response: FavoriteListResponse = try await network.get(
            url: APIConfig.favoritesURL(),
            token: token
        )
        if response.success {
            return response.favorites
        }
        return []
    }
    
    func addFavorite(token: String, musicId: Int) async throws -> FavoriteResponse {
        struct AddFavoriteRequest: Codable {
            let musicId: Int
        }
        
        let body = AddFavoriteRequest(musicId: musicId)
        let response: FavoriteResponse = try await network.post(
            url: APIConfig.favoritesURL(),
            body: body,
            token: token
        )
        return response
    }
    
    func removeFavorite(token: String, musicId: Int) async throws -> FavoriteResponse {
        let response: FavoriteResponse = try await network.delete(
            url: APIConfig.removeFavoriteURL(musicId: musicId),
            token: token
        )
        return response
    }
    
    func isFavorited(token: String, musicId: Int) async -> Bool {
        do {
            let favorites = try await getFavorites(token: token)
            return favorites.contains { $0.id == musicId }
        } catch {
            return false
        }
    }
}
