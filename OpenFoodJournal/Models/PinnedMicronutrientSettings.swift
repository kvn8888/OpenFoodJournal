import Foundation

/// Persisted History-chip pins. IDs stay in pin order so the dedicated
/// pinned row does not reshuffle when the full micronutrient list is sorted.
enum PinnedMicronutrientSettings {
    static let idsKey = "history.pinnedMicronutrientIDs"

    static func ids(in defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.string(forKey: idsKey) ?? "")
    }

    static func decode(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let data = trimmed.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return normalized(ids)
        }
        return normalized(trimmed.split(separator: ",", omittingEmptySubsequences: true).map(String.init))
    }

    static func encode(_ ids: [String]) -> String {
        let values = normalized(ids)
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func pin(_ id: String, in ids: [String]) -> [String] {
        guard !id.isEmpty else { return normalized(ids) }
        var next = normalized(ids)
        next.removeAll { $0 == id }
        next.append(id)
        return next
    }

    static func unpin(_ id: String, from ids: [String]) -> [String] {
        normalized(ids).filter { $0 != id }
    }

    static func isPinned(_ id: String, in ids: [String]) -> Bool {
        normalized(ids).contains(id)
    }

    static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id in
            let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }
}
