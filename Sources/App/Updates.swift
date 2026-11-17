import Foundation

func availableUpdate(stored: Any?, running: String) -> String? {
    guard let stored = stored as? String else { return nil }
    let version = stored.hasPrefix("v") ? String(stored.dropFirst()) : stored
    let parts = version.components(separatedBy: ".")
    guard (1...3).contains(parts.count), parts.allSatisfy({
        !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
    }) else { return nil }
    let current = running.components(separatedBy: ".")
    for index in 0..<3 {
        let left = index < parts.count ? parts[index] : "0"
        let right = index < current.count ? current[index] : "0"
        let comparison = left.compare(right, options: .numeric)
        if comparison != .orderedSame { return comparison == .orderedDescending ? version : nil }
    }
    return nil
}
