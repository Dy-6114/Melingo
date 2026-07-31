import Foundation
import Testing
@testable import MLXAdapter
import Domain
import AIKit

@Suite("MLXProvider")
struct MLXProviderTests {
    @Test("unconfigured provider reports unavailable")
    func unconfigured() async {
        MLXConfigStorage.save(MLXConfigStorage.Config())
        MLXProvider.sharedEngine = nil
        let provider = MLXProvider()
        #expect(!provider.isReady)
        await #expect(throws: LanguageModelError.providerUnavailable) {
            _ = try await provider.translate(
                TextSegment(documentID: UUID(), order: 0, text: "hello"),
                to: "en"
            )
        }
    }
}

@Suite("MLXModelDownloader reuse", .serialized)
struct MLXModelDownloaderReuseTests {
    private func tempModelsRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXReuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCompleteModel(at dest: URL, weightsName: String = "model.safetensors") throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dest.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: dest.appendingPathComponent(weightsName))
    }

    @Test("incomplete folder missing weights is not complete")
    func incompleteOnlyConfig() throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("org__model", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dest.appendingPathComponent("config.json"))
        #expect(!MLXModelDownloader.isCompleteModelDirectory(dest))
    }

    @Test("complete folder with model.safetensors is complete")
    func completeSingleFile() throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("org__model", isDirectory: true)
        try writeCompleteModel(at: dest)
        #expect(MLXModelDownloader.isCompleteModelDirectory(dest))
    }

    @Test("complete when all index shards present")
    func completeSharded() throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("org__model", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dest.appendingPathComponent("config.json"))
        let index: [String: Any] = [
            "weight_map": [
                "a.weight": "model-00001-of-00002.safetensors",
                "b.weight": "model-00002-of-00002.safetensors",
            ]
        ]
        let indexData = try JSONSerialization.data(withJSONObject: index)
        try indexData.write(to: dest.appendingPathComponent("model.safetensors.index.json"))
        try Data("1".utf8).write(to: dest.appendingPathComponent("model-00001-of-00002.safetensors"))
        try Data("2".utf8).write(to: dest.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(MLXModelDownloader.isCompleteModelDirectory(dest))
        let shards = MLXModelDownloader.shardFileNames(
            inIndexAt: dest.appendingPathComponent("model.safetensors.index.json")
        )
        #expect(Set(shards) == [
            "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
        ])
    }

    @Test("sharded incomplete when a shard is missing")
    func incompleteMissingShard() throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("org__model", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dest.appendingPathComponent("config.json"))
        let index: [String: Any] = [
            "weight_map": [
                "a.weight": "model-00001-of-00002.safetensors",
                "b.weight": "model-00002-of-00002.safetensors",
            ]
        ]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: dest.appendingPathComponent("model.safetensors.index.json"))
        try Data("1".utf8).write(to: dest.appendingPathComponent("model-00001-of-00002.safetensors"))
        #expect(!MLXModelDownloader.isCompleteModelDirectory(dest))
    }

    @Test("adoptIfPresent registers config without network")
    func adoptRegisters() throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        MLXConfigStorage.save(MLXConfigStorage.Config())
        let modelID = "mlx-community/test-gemma"
        let dest = root.appendingPathComponent(
            MLXModelDownloader.folderName(for: modelID),
            isDirectory: true
        )
        try writeCompleteModel(at: dest)

        let folder = MLXModelDownloader.adoptIfPresent(modelID: modelID, modelsRoot: root)
        #expect(folder == "mlx-community__test-gemma")
        let cfg = MLXConfigStorage.load()
        #expect(cfg.modelID == modelID)
        #expect(cfg.localRelativePath == folder)
        #expect(cfg.isConfigured)
    }

    @Test("download on complete folder reports Already on disk and does not overwrite")
    func downloadSkipsExisting() async throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        MLXConfigStorage.save(MLXConfigStorage.Config())
        let modelID = "org/reuse-me"
        let dest = root.appendingPathComponent(
            MLXModelDownloader.folderName(for: modelID),
            isDirectory: true
        )
        try writeCompleteModel(at: dest)
        let weightsURL = dest.appendingPathComponent("model.safetensors")
        let before = try FileManager.default.attributesOfItem(atPath: weightsURL.path)
        let beforeSize = before[.size] as? NSNumber
        let beforeMod = before[.modificationDate] as? Date

        final class DetailBox: @unchecked Sendable {
            var values: [String] = []
        }
        let box = DetailBox()
        let folder = try await MLXModelDownloader.download(
            modelID: modelID,
            modelsRoot: root
        ) { progress in
            box.values.append(progress.detail)
        }

        #expect(folder == "org__reuse-me")
        #expect(box.values.contains("Already on disk"))
        let after = try FileManager.default.attributesOfItem(atPath: weightsURL.path)
        #expect(after[.size] as? NSNumber == beforeSize)
        #expect(after[.modificationDate] as? Date == beforeMod)
        #expect(MLXConfigStorage.load().modelID == modelID)
    }

    @Test("adoptExistingIfUnconfigured picks sole complete folder")
    func adoptSoleFolder() throws {
        let root = try tempModelsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        MLXConfigStorage.save(MLXConfigStorage.Config())
        let dest = root.appendingPathComponent("solo__model", isDirectory: true)
        try writeCompleteModel(at: dest)

        let adopted = MLXModelDownloader.adoptExistingIfUnconfigured(modelsRoot: root)
        #expect(adopted == "solo/model")
        #expect(MLXConfigStorage.load().localRelativePath == "solo__model")
    }
}
