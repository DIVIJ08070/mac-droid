import Foundation

struct Packet {
    let type: String
    let body: [String: Any]

    init(type: String, body: [String: Any] = [:]) {
        self.type = type
        self.body = body
    }

    /// Raw JSON bytes (no trailing newline) — used before framing/encryption.
    func jsonData() -> Data? {
        let dict: [String: Any] = [
            "id": Int(Date().timeIntervalSince1970 * 1000),
            "type": type,
            "body": body,
        ]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    func encode() -> Data? {
        guard var data = jsonData() else { return nil }
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> Packet? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = obj["type"] as? String
        else { return nil }
        return Packet(type: type, body: obj["body"] as? [String: Any] ?? [:])
    }
}
