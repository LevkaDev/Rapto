//
//  LossyDecoding.swift
//  Rapto
//

import Foundation

/// Decodes one entry of a saved list; an entry from another app version decodes to nil
/// instead of failing the whole list
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
