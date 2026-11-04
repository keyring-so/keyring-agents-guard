import Foundation

// Usage: bip39-check <vector.json>. Exit 0 only if words and seeds match the reference library.

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: bip39-check <vector.json>") }
guard
    let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let vectors = root["vectors"] as? [[String: Any]]
else { fail("could not read vector file") }

var passed = 0
for vector in vectors {
    guard
        let entropyHex = vector["entropyHex"] as? String,
        let entropy = Data(hex: entropyHex),
        let expectedWords = vector["words"] as? [String],
        let expectedSeed = vector["seedHex"] as? String
    else { fail("malformed vector") }

    do {
        let words = try Bip39.mnemonic(entropy: [UInt8](entropy))
        guard words == expectedWords else {
            fail("words differ for \(entropyHex)\n  app: \(words.joined(separator: " "))\n  ref: \(expectedWords.joined(separator: " "))")
        }
        let seed = Data(try Bip39.seed(mnemonic: words)).hex
        guard seed == expectedSeed else {
            fail("seed differs for \(entropyHex)\n  app: \(seed)\n  ref: \(expectedSeed)")
        }
        passed += 1
    } catch {
        fail("\(error)")
    }
}
print("PASS: \(passed)/\(vectors.count) vectors (words and seeds)")
