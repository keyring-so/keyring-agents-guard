import Foundation

// Usage: near-tx-check <vector.json>. Exit 0 only if the app's bytes and digest match the SDK's.

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: near-tx-check <vector.json>") }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let data = try? Data(contentsOf: url),
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let inputs = root["inputs"] as? [String: Any],
    let expectedUnsigned = root["expectedUnsignedHex"] as? String,
    let expectedDigest = root["expectedDigestHex"] as? String,
    let nonceText = inputs["nonce"] as? String,
    let nonce = UInt64(nonceText),
    let gas = inputs["gasTGas"] as? Int,
    let id = inputs["id"] as? String
else { fail("could not read vector") }

do {
    let tx = NearFunctionCallTx(
        signerId: inputs["signerId"] as? String ?? "",
        publicKeyHex: inputs["publicKeyHex"] as? String ?? "",
        nonce: nonce,
        receiverId: inputs["receiverId"] as? String ?? "",
        blockHashHex: inputs["blockHashHex"] as? String ?? "",
        methodName: inputs["methodName"] as? String ?? "",
        argsJSON: try NearFunctionCallTx.args(forId: id),
        gasTGas: UInt64(gas),
        depositYocto: inputs["depositYocto"] as? String ?? "0"
    )

    let unsigned = try tx.unsignedBytes().hex
    let digest = try tx.digest().hex

    guard unsigned == expectedUnsigned else {
        fail("unsigned bytes differ\n  app: \(unsigned)\n  sdk: \(expectedUnsigned)")
    }
    guard digest == expectedDigest else {
        fail("digest differs\n  app: \(digest)\n  sdk: \(expectedDigest)")
    }
    guard
        let addKeyRoot = root["addKey"] as? [String: Any],
        let addKeyInputs = addKeyRoot["inputs"] as? [String: Any],
        let addKeyUnsignedExpected = addKeyRoot["expectedUnsignedHex"] as? String,
        let addKeyDigestExpected = addKeyRoot["expectedDigestHex"] as? String,
        let addKeyNonceText = addKeyInputs["nonce"] as? String,
        let addKeyNonce = UInt64(addKeyNonceText),
        let methods = addKeyInputs["methods"] as? [String]
    else { fail("could not read addKey vector") }

    let addKeyTx = NearAddKeyTx(
        signerId: addKeyInputs["signerId"] as? String ?? "",
        publicKeyHex: addKeyInputs["publicKeyHex"] as? String ?? "",
        nonce: addKeyNonce,
        receiverId: addKeyInputs["receiverId"] as? String ?? "",
        blockHashHex: addKeyInputs["blockHashHex"] as? String ?? "",
        newPublicKeyHex: addKeyInputs["agentKeyHex"] as? String ?? "",
        allowanceYocto: addKeyInputs["allowanceYocto"] as? String ?? "0",
        contractId: addKeyInputs["contractId"] as? String ?? "",
        methods: methods
    )
    let addKeyUnsigned = try addKeyTx.unsignedBytes().hex
    let addKeyDigest = try addKeyTx.digest().hex
    guard addKeyUnsigned == addKeyUnsignedExpected else {
        fail("addKey unsigned bytes differ\n  app: \(addKeyUnsigned)\n  sdk: \(addKeyUnsignedExpected)")
    }
    guard addKeyDigest == addKeyDigestExpected else {
        fail("addKey digest differs\n  app: \(addKeyDigest)\n  sdk: \(addKeyDigestExpected)")
    }

    print("PASS: call \(unsigned.count / 2) bytes, addKey \(addKeyUnsigned.count / 2) bytes")
} catch {
    fail(error.localizedDescription)
}
