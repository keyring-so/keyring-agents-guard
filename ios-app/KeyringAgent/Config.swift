import Foundation

enum AppConfig {
    /// Default API server. Changed at runtime in Settings → API server.
    static let apiBaseURL = URL(string: "http://127.0.0.1:8787")!

    /// Set this when the API server is started with API_TOKEN.
    static let apiToken = ""

    /// The policy contract lives on this account.
    static let account = "keyring-spike-1023.testnet"
    static let rpcURL = URL(string: "https://test.rpc.fastnear.com")!
    static let explorerBase = URL(string: "https://testnet.nearblocks.io/txns/")!

    /// Test CA public key (uncompressed P-256, 65 bytes) from the applet's TestCA.
    /// Replace this with the production CA public key before using a production-personalized card.
    static let cardCAPublicKeyHex =
        "041517863a74907f5ed3b25a9072d0d34e8b869ea7a021bb40ad29dd8aa10e49ce57043ceb813a51cd9a00d7460c25dd4f343346d45666c5605bf7db2396701dbe"

    /// m/44'/397'/0'/0/0 — the same path the NEAR spike signed with.
    static let cardPath: [UInt32] = [0x8000002C, 0x8000018D, 0x80000000, 0, 0]
    static let cardPINLength = 6

    static let urlScheme = "keyring-agent"
}
