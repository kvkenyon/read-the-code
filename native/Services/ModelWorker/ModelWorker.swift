import Foundation
import RTCContracts
import RTCModelAdapters

public struct ModelCapabilitySnapshot: Codable, Sendable, Equatable {
    public let kind: ModelAdapterKind, models: [BoundedString], structuredOutput: Bool, healthy: Bool
    public init(kind: ModelAdapterKind, models: [BoundedString], structuredOutput: Bool, healthy: Bool) {
        self.kind = kind; self.models = models; self.structuredOutput = structuredOutput; self.healthy = healthy
    }
}

public actor ModelWorkerService {
    private let adapter: any ModelAdapter
    public init(adapter: any ModelAdapter) { self.adapter = adapter }
    public func capabilities(kind: ModelAdapterKind) async -> ModelCapabilitySnapshot {
        do { let models = try await adapter.discoverModels(); return ModelCapabilitySnapshot(kind: kind, models: models, structuredOutput: true, healthy: (try? await adapter.health()) == true) }
        catch { return ModelCapabilitySnapshot(kind: kind, models: [], structuredOutput: false, healthy: false) }
    }
    public func generate(request: Data, schema: Data) async throws -> Data { try await adapter.generateStructured(request: request, schema: schema) }
    public func cancel() async { await adapter.cancel() }
}

public final class ModelWorkerClient: ModelAdapter, @unchecked Sendable {
    private let service: ModelWorkerService
    private let timeout: Duration
    public init(service: ModelWorkerService, timeout: Duration = .seconds(95)) { self.service = service; self.timeout = timeout }
    public func discoverModels() async throws -> [BoundedString] { try await withTimeout { try await self.service.adapterModels() } }
    public func health() async throws -> Bool { try await withTimeout { try await self.service.adapterHealth() } }
    public func generateStructured(request: Data, schema: Data) async throws -> Data { try await withTimeout { try await self.service.generate(request: request, schema: schema) } }
    public func cancel() async { await service.cancel() }
    private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: self.timeout); throw ModelAdapterError.timedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private extension ModelWorkerService {
    func adapterModels() async throws -> [BoundedString] { try await adapter.discoverModels() }
    func adapterHealth() async throws -> Bool { try await adapter.health() }
}
