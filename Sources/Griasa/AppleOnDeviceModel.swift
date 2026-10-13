import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's built-in model, for short English light jobs only (see
/// `LocalRouting`). Absent below macOS 26, on Macs without Apple
/// Intelligence, and while Apple is still downloading it.
enum AppleOnDeviceModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func complete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw NSError(domain: "Griasa", code: 20, userInfo: [NSLocalizedDescriptionKey: "Apple's on-device model is not available."])
    }
}
