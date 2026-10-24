import Foundation

/// A lenient view of a JSON object from the server, read the way the Android app reads it:
/// missing or mistyped values fall back to a default instead of failing the whole response.
/// The server writes most ids as strings and amounts sometimes as strings, sometimes as numbers.
struct JSONObject {
    let raw: [String: Any]

    init(_ value: Any?) {
        raw = value as? [String: Any] ?? [:]
    }

    /// Parses UTF-8 JSON text whose top level is an object; anything else gives an empty object.
    static func parse(_ text: String) -> JSONObject {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return JSONObject(nil)
        }

        return JSONObject(value)
    }

    func has(_ key: String) -> Bool {
        guard let value = raw[key] else {
            return false
        }

        return !(value is NSNull)
    }

    func string(_ key: String, _ fallback: String = "") -> String {
        switch raw[key] {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return fallback
        }
    }

    func int64(_ key: String, _ fallback: Int64 = 0) -> Int64 {
        switch raw[key] {
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            return Int64(text.trimmingCharacters(in: .whitespaces)) ?? fallback
        default:
            return fallback
        }
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        Int(int64(key, Int64(fallback)))
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        switch raw[key] {
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            return text == "true" || text == "1"
        default:
            return fallback
        }
    }

    func object(_ key: String) -> JSONObject? {
        guard let value = raw[key] as? [String: Any] else {
            return nil
        }

        return JSONObject(value)
    }

    func array(_ key: String) -> [Any]? {
        raw[key] as? [Any]
    }

    /// The objects in an array value, skipping anything that isn't an object.
    func objects(_ key: String) -> [JSONObject] {
        JSONObject.objects(in: raw[key])
    }

    static func objects(in value: Any?) -> [JSONObject] {
        guard let array = value as? [Any] else {
            return []
        }

        return array.compactMap { item in
            (item as? [String: Any]).map { JSONObject($0) }
        }
    }

    /// The object as JSON text, for keeping it as it came (for example the signed-in user).
    func jsonText() -> String? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
