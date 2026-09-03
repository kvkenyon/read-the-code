import Foundation
import RTCContracts
public enum RTCFixture { public static func revision() throws -> RevisionIdentity { try RevisionIdentity(repositoryPath: "/tmp/repo", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40)) } }
