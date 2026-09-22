import CryptoKit
import Foundation

// Verify against the public key shipped in the app, not merely the CI private key.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("Usage: verify_update.swift archive public-key-file signature") }
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let keyText = try String(contentsOfFile: arguments[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let keyData = Data(base64Encoded: keyText),
      let signature = Data(base64Encoded: arguments[3]) else {
    fail("Invalid public key or signature encoding")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
guard key.isValidSignature(signature, for: archive) else {
    fail("Update signature does not match the public key embedded in Jot")
}
print("Update signature matches Jot's public key")
