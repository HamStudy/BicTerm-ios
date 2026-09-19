import BicTermCore
import Foundation
import Security
import SwiftUI
import UIKit

#if DEBUG
/// Presents `KeyManagementView` directly over the app root when UI tests launch
/// with `-uitest-keys-entry`. The current app shell (T6) renders no navigation
/// chrome, so the Settings entry is not reachable from the connection list yet;
/// tests use this seam until the shell gains a NavigationStack.
struct UITestKeyManagementOverlay: ViewModifier {
    @State private var isPresented = false
    /// iOS unloads the presenting view under a fullScreenCover and refires
    /// `onAppear` when that cover dismisses: without this latch, dismissing
    /// the keys entry (keys-done) immediately RE-presented it over whatever
    /// the test opened next, swallowing the next tap (the covered connection
    /// list stays AX-visible but unhittable).
    @MainActor private static var didAutoPresent = false

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            KeyManagementView()
        }
        .onAppear {
            guard UITestArguments.isKeysEntryActive, !Self.didAutoPresent else { return }
            Self.didAutoPresent = true
            isPresented = true
        }
    }
}

/// Launch arguments prefixed `-uitest` are UI-test seams. They are compiled out
/// of Release builds (`#if DEBUG`), so a production binary never reads them.
enum UITestArguments {
    static var isResetKeysActive: Bool { arguments.contains("-uitest-reset-keys") }
    static var isSeedPasteboardActive: Bool { arguments.contains("-uitest-seed-pasteboard") }
    static var isSeedSecureEnclaveKeyActive: Bool { arguments.contains("-uitest-seed-se-key") }
    static var isSeedConnectionActive: Bool { arguments.contains("-uitest-seed-connection") }
    static var isBiometricsBypassActive: Bool { arguments.contains("-uitest-biometrics-bypass") }
    static var isKeysEntryActive: Bool { arguments.contains("-uitest-keys-entry") }

    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var seedPasteboardFilePath: String? {
        guard let flag = arguments.firstIndex(of: "-uitest-seed-pasteboard") else { return nil }
        let valueIndex = flag + 1
        guard valueIndex < arguments.count else { return nil }
        return arguments[valueIndex]
    }
}

@MainActor
enum UITestSupport {
    static var seededSecureEnclaveReference: String?
    private static var activated = false

    static func activate() {
        guard !activated else { return }
        activated = true
        guard argumentsContainUITestFlag else { return }
        if UITestArguments.isResetKeysActive { resetAllKeys() }
        if UITestArguments.isSeedSecureEnclaveKeyActive { seedSecureEnclaveKey() }
        if UITestArguments.arguments.contains("-uitest-seed-disabled-key") { seedDisabledKey() }
        if UITestArguments.arguments.contains("-uitest-seed-offer-warning") {
            for index in 1...3 {
                let metadata = KeyMetadata(
                    reference: "uitest-warning-\(index)", label: "Warning Fixture \(index)",
                    algorithm: .ed25519, fingerprint: "SHA256:UITESTWARNING\(index)",
                    publicKeyBlob: Data(repeating: UInt8(index), count: 32), requiresBiometry: false
                )
                try? KeychainItemQuery.addItem(service: KeyStore.ed25519Service, metadata: metadata)
            }
        }
        if UITestArguments.isSeedPasteboardActive { seedPasteboard() }
    }

    static func seedConnectionIfNeeded() {
        guard argumentsContainUITestFlag, UITestArguments.isSeedConnectionActive else { return }
        guard let reference = seededSecureEnclaveReference else { return }
        Task.detached {
            guard let store = try? PersistenceStoreFactory.makeConfigurationStore(),
                  let connection = try? Connection(
                    name: "Fixture Jump Host",
                    type: .ssh,
                    host: "127.0.0.1",
                    port: 12222,
                    username: "fixture",
            customKeys: [reference]
                  ) else { return }
            try? await store.save(connection)
        }
    }

    private static var argumentsContainUITestFlag: Bool {
        UITestArguments.arguments.contains { $0.hasPrefix("-uitest") }
    }

    private static func resetAllKeys() {
        for service in [KeyStore.ed25519Service, KeyStore.secureEnclaveService] {
            guard let items = try? KeychainItemQuery.listItems(service: service) else { continue }
            for item in items {
                try? KeychainItemQuery.deleteItem(service: service, reference: item.reference)
            }
        }
    }

    private static func seedSecureEnclaveKey() {
        let metadata = KeyMetadata(
            reference: UUID().uuidString,
            label: "SE Test Key",
            algorithm: .ecdsaP256,
            fingerprint: "SHA256:UITESTSEEDUITESTSEEDUITESTSEEDUITEST",
            publicKeyBlob: Data([0x04]) + Data(repeating: 0xAB, count: 64),
            requiresBiometry: true
        )
        if (try? KeychainItemQuery.addItem(service: KeyStore.secureEnclaveService, metadata: metadata)) != nil {
            seededSecureEnclaveReference = metadata.reference
        }
    }

    private static func seedDisabledKey() {
        let reference = "uitest-disabled-fixture"
        try? KeychainItemQuery.deleteItem(service: KeyStore.ed25519Service, reference: reference)
        let metadata = KeyMetadata(
            reference: reference,
            label: "Disabled Fixture",
            algorithm: .ed25519,
            fingerprint: "SHA256:UITESTDISABLEDFIXTURE",
            publicKeyBlob: Data(repeating: 0xAB, count: 32),
            requiresBiometry: false,
            enabledByDefault: false
        )
        try? KeychainItemQuery.addItem(service: KeyStore.ed25519Service, metadata: metadata)
    }

    private static func seedPasteboard() {
        guard let path = UITestArguments.seedPasteboardFilePath,
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }
}
#endif
