import Foundation
import RTCContracts
import RTCIngest
import RTCIPC

public enum RTCCLIError: Error, Equatable, Sendable { case usage(String), transport(String), remote(IPCWireError) }

public enum RTCCommand: Equatable, Sendable {
    case submit(repo: String, base: String, head: String, metadata: Data?, tour: Data?, wakeFile: String?, notify: Bool, json: Bool)
    case status(review: String, json: Bool)
    case poll(review: String, after: Int, timeoutMilliseconds: Int, full: Bool, json: Bool, conversation: Bool)
    case conversationReply(review: String, message: Data, json: Bool)
    case attachTour(review: String, file: String, json: Bool)
    case export(review: String, diagnostic: Bool, full: Bool, json: Bool)
    case close(review: String, json: Bool)
    case installSkill(scope: String?, json: Bool)
    case help
}

public struct RTCCLIParser: Sendable {
    public init() {}
    public func parse(_ args: [String]) throws -> RTCCommand {
        guard let command = args.first else { return .help }
        var p = Array(args.dropFirst())
        func flag(_ name: String) -> Bool { if let i = p.firstIndex(of: name) { p.remove(at: i); return true }; return false }
        func value(_ name: String, required: Bool = true) throws -> String? {
            guard let i = p.firstIndex(of: name) else { if required { throw RTCCLIError.usage("missing \(name)") }; return nil }
            guard i + 1 < p.count, !p[i + 1].hasPrefix("--") else { throw RTCCLIError.usage("missing value for \(name)") }
            let result = p[i + 1]; p.removeSubrange(i...(i + 1)); return result
        }
        let json = flag("--json")
        switch command {
        case "submit":
            guard let repo = try value("--repo"), let base = try value("--base"), let head = try value("--head") else { throw RTCCLIError.usage("submit requires --repo, --base, and --head") }
            let metadata = try value("--metadata", required: false).flatMap { $0.data(using: .utf8) }
            let tour = try value("--tour", required: false).flatMap { $0.data(using: .utf8) }
            return .submit(repo: repo, base: base, head: head, metadata: metadata, tour: tour, wakeFile: try value("--wake-file", required: false), notify: !flag("--no-notify"), json: json)
        case "status": return .status(review: try positional(&p), json: json)
        case "poll": return .poll(review: try positional(&p), after: try integer(value("--after")), timeoutMilliseconds: try duration(value("--timeout", required: false) ?? "2m"), full: flag("--full"), json: json, conversation: false)
        case "conversation":
            let sub = try positional(&p), review = try positional(&p)
            if sub == "poll" { return .poll(review: review, after: try integer(value("--after")), timeoutMilliseconds: try duration(value("--timeout", required: false) ?? "2m"), full: flag("--full"), json: json, conversation: true) }
            guard sub == "reply", let text = try value("--message"), let data = text.data(using: .utf8) else { throw RTCCLIError.usage("conversation reply requires --message") }
            return .conversationReply(review: review, message: data, json: json)
        case "tour":
            guard try positional(&p) == "attach" else { throw RTCCLIError.usage("expected tour attach") }
            guard let file = try value("--file") else { throw RTCCLIError.usage("tour attach requires --file") }
            return .attachTour(review: try positional(&p), file: file, json: json)
        case "export": return .export(review: try positional(&p), diagnostic: flag("--diagnostic"), full: flag("--full"), json: json)
        case "close": return .close(review: try positional(&p), json: json)
        case "install-skill": return .installSkill(scope: try value("--scope", required: false), json: json)
        case "help", "--help", "-h": return .help
        default: throw RTCCLIError.usage("unknown command \(command)")
        }
    }
    private func positional(_ p: inout [String]) throws -> String { guard let v = p.first, !v.hasPrefix("-") else { throw RTCCLIError.usage("missing positional argument") }; p.removeFirst(); return v }
    private func integer(_ value: String?) throws -> Int { guard let value, let n = Int(value), n >= 0 else { throw RTCCLIError.usage("expected non-negative integer") }; return n }
    private func duration(_ value: String) throws -> Int { if value.hasSuffix("m"), let n = Int(value.dropLast()), n >= 0, n <= 60 { return n * 60_000 }; let s = value.hasSuffix("s") ? value.dropLast() : Substring(value); guard let n = Int(s), n >= 0, n <= 3_600 else { throw RTCCLIError.usage("timeout must be up to 60m") }; return n * 1_000 }
}

public enum RTCCLIOutput {
    public static func render(_ value: Any, json: Bool) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: json ? [.sortedKeys] : [.sortedKeys]), let string = String(data: data, encoding: .utf8) { return string + "\n" }
        return "\(value)\n"
    }
    public static func error(_ error: Error) -> (text: String, exitCode: Int32) {
        if let e = error as? RTCCLIError, case .remote(let wire) = e { return ("\(wire.code): \(wire.message)\n", wire.retryable ? 75 : 1) }
        return ("\(error)\n", error is RTCCLIError ? 2 : 1)
    }
}

public struct ProcessAppActivator: AppActivator, Sendable {
    public let bundleIdentifier: String
    public init(bundleIdentifier: String = "com.readthecode.app") { self.bundleIdentifier = bundleIdentifier }

    public func activate() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }
}

public struct RTCCLIExecutor: Sendable {
    private let paths: RTCInstallationPaths
    private let activator: any AppActivator
    private let retryDuration: Duration

    public init(
        paths: RTCInstallationPaths,
        activator: any AppActivator = ProcessAppActivator(),
        retryDuration: Duration = .seconds(8)
    ) {
        self.paths = paths
        self.activator = activator
        self.retryDuration = retryDuration
    }

    public init(
        activator: any AppActivator = ProcessAppActivator(),
        retryDuration: Duration = .seconds(8)
    ) throws {
        self.init(
            paths: try RTCInstallationPaths.applicationSupport(),
            activator: activator,
            retryDuration: retryDuration
        )
    }

    public func run(_ command: RTCCommand) async throws -> String {
        switch command {
        case let .submit(repo, base, head, metadata, tour, _, notify, _):
            if let tour, tour.count > IPCConstants.maxTourBytes {
                throw RTCCLIError.usage("tour exceeds the 1 MiB limit")
            }
            let title = try Self.metadataTitle(metadata)
            let submission = ReviewSubmission(
                repositoryPath: repo,
                base: SubmittedRef(label: base, expectedSHA: Self.fullSHA(base)),
                head: SubmittedRef(label: head, expectedSHA: Self.fullSHA(head)),
                title: title,
                notify: notify
            )
            return try await request(operation: "submitReview", body: RTCCanonicalJSON.encode(submission), durable: true)
        case let .status(review, _):
            return try await lookup(operation: "status", review: review)
        case let .poll(review, after, _, _, _, conversation):
            guard !conversation else { throw RTCCLIError.usage("conversation polling is not available") }
            return try await lookup(operation: "pollReviewEvents", review: review, after: after)
        case let .close(review, _):
            return try await lookup(operation: "closeReview", review: review)
        case .help:
            return "rtc submit | status | poll | conversation | tour attach | export | close | install-skill\n"
        default:
            throw RTCCLIError.usage("operation is not available in this build")
        }
    }

    private func lookup(operation: String, review: String, after: Int? = nil) async throws -> String {
        let id = try ReviewID(review)
        return try await request(
            operation: operation,
            body: RTCCanonicalJSON.encode(ReviewLookup(reviewID: id, after: after)),
            durable: false
        )
    }

    private func request(operation: String, body: Data, durable: Bool) async throws -> String {
        let capability: String
        do { capability = try paths.prepare(createCapability: false) }
        catch { throw RTCCLIError.remote(IPCWireError(code: "APP_UNAVAILABLE", message: "Read the Code is not installed", retryable: true)) }
        let envelope = IPCEnvelope(operation: operation, capability: capability, body: body)
        let client = IPCClient(socketPath: paths.socket.path)
        if let response = try? client.send(envelope, timeout: 0.5) { return try decode(response) }

        if durable {
            let spool = try SpoolTransport(directory: paths.spool)
            _ = try spool.write(IPCFrameCodec.encode(envelope), id: envelope.requestID)
        }
        _ = await activator.activate()
        let deadline = ContinuousClock.now.advanced(by: retryDuration)
        while ContinuousClock.now < deadline {
            if let response = try? client.send(envelope, timeout: 0.5) { return try decode(response) }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw RTCCLIError.remote(IPCWireError(
            code: "APP_UNAVAILABLE",
            message: durable ? "Submission was saved, but the app is unavailable" : "The app is unavailable",
            retryable: true
        ))
    }

    private func decode(_ response: IPCEnvelopeResponse) throws -> String {
        guard response.ok else { throw RTCCLIError.remote(response.error ?? IPCWireError(code: "INTERNAL_ERROR", message: "The operation failed")) }
        return String(data: response.body ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func fullSHA(_ value: String) -> String? {
        value.count == 40 && value.allSatisfy(\.isHexDigit) ? value.lowercased() : nil
    }

    private static func metadataTitle(_ data: Data?) throws -> String {
        guard let data else { return "Code review" }
        guard data.count <= RTCConstants.maxRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RTCCLIError.usage("metadata must be a bounded JSON object") }
        guard let value = object["title"] else { return "Code review" }
        guard let title = value as? String else { throw RTCCLIError.usage("metadata title must be a string") }
        return title
    }
}
