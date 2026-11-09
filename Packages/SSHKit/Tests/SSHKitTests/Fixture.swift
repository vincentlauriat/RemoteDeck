import Foundation
import Testing

/// The text of a key generated with ssh-keygen for these tests (`Fixtures/`).
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}
