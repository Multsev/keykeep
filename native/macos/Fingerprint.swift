import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Only the enrolled Secure Enclave key can unwrap this local credential.
struct Fingerprint {
    let file: URL
    var enabled: Bool { FileManager.default.fileExists(atPath: file.path) }
    var available: Bool {
        let context = LAContext()
        return SecureEnclave.isAvailable && context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && context.biometryType == .touchID
    }

    private struct Envelope: Codable {
        let protectedKey: Data
        let publicKey: Data
        let sealed: Data
    }

    private func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("KeyKeep Touch ID v1".utf8), sharedInfo: Data(), outputByteCount: 32)
    }

    func enroll(pin: String, context: LAContext) throws {
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage,.biometryCurrentSet], nil) else { throw PlatformFailure() }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: acl, authenticationContext: context)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let wrap = wrappingKey(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey))
        let encrypted = try AES.GCM.seal(Data(pin.utf8), using: wrap)
        guard let sealed = encrypted.combined else { throw PlatformFailure() }
        let envelope = Envelope(protectedKey: key.dataRepresentation, publicKey: ephemeral.publicKey.rawRepresentation, sealed: sealed)
        try JSONEncoder().encode(envelope).write(to: file, options: .atomic)
    }

    func recover(context: LAContext) throws -> String {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.protectedKey, authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: envelope.publicKey)
        let wrap = wrappingKey(try key.sharedSecretFromKeyAgreement(with: peer))
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: wrap)
        guard let pin = String(data: clear, encoding: .utf8) else { throw PlatformFailure() }
        return pin
    }

    func disable() throws {
        if enabled { try FileManager.default.removeItem(at: file) }
    }
}
