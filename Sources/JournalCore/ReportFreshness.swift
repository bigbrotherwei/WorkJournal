import Foundation
import CryptoKit

public enum ReportFreshness {
    public static func fingerprint(day: String, entries: [Entry]) -> String {
        // These are exactly the fields used in the prompt; timestamps and manual flags
        // do not change report facts. Arrays make serialization order deterministic.
        let rows = entries.filter { $0.day == day && $0.inReport }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { [$0.id.uuidString, $0.text, $0.category, $0.status.rawValue] }
        let payload = [ [day] ] + rows
        let data = try! JSONEncoder().encode(payload) // [[String]] has no failing Encodable values.
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
public struct ReportDraft: Codable {
    public var text: String
    public var sourceFingerprint: String?
    public init(text: String, sourceFingerprint: String?) { self.text = text; self.sourceFingerprint = sourceFingerprint }
}
