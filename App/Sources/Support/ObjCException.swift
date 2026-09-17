import Foundation

/// Swift face of `AVObjCTry`: runs `body` and rethrows any Objective-C
/// exception as a Swift error instead of letting it take the process down.
enum ObjCException {
    struct Raised: LocalizedError {
        let name: String
        let reason: String
        var errorDescription: String? { reason }
    }

    static func catching(_ body: () -> Void) throws {
        var error: NSError?
        guard AVObjCTry(body, &error) else {
            let info = error?.userInfo ?? [:]
            throw Raised(
                name: info["exceptionName"] as? String ?? "NSException",
                reason: error?.localizedDescription ?? "An internal audio error occurred."
            )
        }
    }
}
