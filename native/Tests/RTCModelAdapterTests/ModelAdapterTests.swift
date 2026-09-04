import XCTest
import RTCContracts
@testable import RTCModelAdapters

final class ModelAdapterTests: XCTestCase {
    func testOnlyLoopbackIPLiteralEndpointsAreAccepted() throws {
        XCTAssertNoThrow(try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!))
        XCTAssertNoThrow(try LoopbackEndpoint(URL(string: "http://[::1]:8080")!))
        XCTAssertNoThrow(try LoopbackEndpoint(URL(string: "http://[0:0:0:0:0:0:0:1]:8080")!))
        XCTAssertThrowsError(try LoopbackEndpoint(URL(string: "http://localhost:11434")!))
        XCTAssertThrowsError(try LoopbackEndpoint(URL(string: "http://192.168.1.2:11434")!))
        XCTAssertThrowsError(try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434?leak=token")!))
        for host in ["127.256.0.1", "127.999.999.999", "127.-1.-1.-1", "localhost"] {
            XCTAssertThrowsError(try LoopbackEndpoint(URL(string: "http://\(host):11434")!))
        }
    }

    func testTransportRevalidatesCompleteDestination() async {
        let transport = URLSessionModelTransport()
        for url in ["http://127.256.0.1:11434", "http://token@127.0.0.1:11434", "http://127.0.0.1:11434?token=secret"] {
            do { _ = try await transport.send(URLRequest(url: URL(string: url)!), limits: .init()); XCTFail("accepted \(url)") }
            catch let error as ModelAdapterError { XCTAssertEqual(error, .invalidEndpoint("destination changed")) }
            catch { XCTFail("unexpected error \(error)") }
        }
    }

    func testOllamaFragmentedStreamIsReassembledAndBounded() async throws {
        let transport = StubTransport(chunks: [Data("{\"response\":\"{\\\"ok\\\":\"".utf8), Data("yes\\\"}\",\"done\":false}\n".utf8), Data("{\"response\":\"\",\"done\":true}\n".utf8)])
        let adapter = OllamaAdapter(endpoint: try LoopbackEndpoint(URL(string: "http://127.0.0.1:11434")!), model: "test", transport: transport)
        let result = try await adapter.generateStructured(request: Data("hello".utf8), schema: Data("{}".utf8))
        XCTAssertEqual(String(data: result, encoding: .utf8), "{\"ok\":\"yes\"}")
    }

    func testCredentialIsOnlyAddedToOpenAIRequest() async throws {
        let transport = StubTransport(chunks: [Data("{\"data\":[{\"id\":\"local\"}]}".utf8)])
        let credentials = StubCredentials(value: "secret")
        let adapter = OpenAICompatibleAdapter(endpoint: try LoopbackEndpoint(URL(string: "http://127.0.0.1:8080")!), model: "local", credentials: credentials, transport: transport)
        XCTAssertEqual(try await adapter.discoverModels().first?.value, "local")
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
}

private struct StubCredentials: ModelCredentialLookup {
    let value: String
    func credential(for key: String) async throws -> String? { value }
}

private final class StubTransport: ModelHTTPTransport, @unchecked Sendable {
    let chunks: [Data]; private(set) var lastRequest: URLRequest?
    init(chunks: [Data]) { self.chunks = chunks }
    func send(_ request: URLRequest, limits: ModelLimits) async throws -> AsyncThrowingStream<Data, Error> {
        lastRequest = request
        return AsyncThrowingStream { continuation in
            chunks.forEach { continuation.yield($0) }; continuation.finish()
        }
    }
}
