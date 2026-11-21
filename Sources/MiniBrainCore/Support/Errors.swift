import Foundation

public enum MiniBrainError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidTag(String)
    case unsupportedPayload
    case emptyPayload
    case invalidQuery(String)
    case blobMissing(String)
    case enrichmentFailed(String)
    case modelUnavailable(String)
    case invalidModelOutput(String)
}
