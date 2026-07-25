import Foundation

/// Physical Mac profile used to recommend MLX model size.
public struct MacHardwareProfile: Sendable, Equatable {
    public var totalMemoryBytes: UInt64
    public var isAppleSilicon: Bool
    public var chipName: String

    public var totalMemoryGB: Int {
        Int((Double(totalMemoryBytes) / 1_073_741_824.0).rounded())
    }

    public static func current() -> MacHardwareProfile {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)

        var brand = [CChar](repeating: 0, count: 256)
        var brandSize = brand.count
        sysctlbyname("machdep.cpu.brand_string", &brand, &brandSize, nil, 0)
        let chip = String(cString: brand)

        #if arch(arm64)
        let apple = true
        #else
        let apple = chip.localizedCaseInsensitiveContains("Apple")
        #endif

        return MacHardwareProfile(
            totalMemoryBytes: memSize,
            isAppleSilicon: apple,
            chipName: chip.isEmpty ? (apple ? "Apple Silicon" : "Intel") : chip
        )
    }
}

/// Curated Google Gemma (MLX) models with RAM guidance — shown in onboarding & Settings.
public struct GemmaMLXModel: Identifiable, Sendable, Hashable {
    public var id: String { huggingFaceID }
    public var huggingFaceID: String
    public var displayName: String
    public var blurb: String
    public var approxDiskGB: Double
    /// Comfortable unified-memory floor (GB) including OS headroom.
    public var minMemoryGB: Int
    public var qualityRank: Int

    public func fits(_ hardware: MacHardwareProfile) -> Bool {
        hardware.isAppleSilicon && hardware.totalMemoryGB >= minMemoryGB
    }
}

public enum GemmaModelCatalog {
    public static let all: [GemmaMLXModel] = [
        GemmaMLXModel(
            huggingFaceID: "mlx-community/gemma-3-1b-it-4bit",
            displayName: "Gemma 3 1B (4-bit)",
            blurb: "Lightest — great for 8 GB Macs and quick explanations.",
            approxDiskGB: 0.8,
            minMemoryGB: 8,
            qualityRank: 1
        ),
        GemmaMLXModel(
            huggingFaceID: "mlx-community/gemma-3-4b-it-4bit",
            displayName: "Gemma 3 4B (4-bit)",
            blurb: "Best balance of quality and speed for most MacBooks.",
            approxDiskGB: 2.6,
            minMemoryGB: 8,
            qualityRank: 2
        ),
        GemmaMLXModel(
            huggingFaceID: "mlx-community/gemma-3-12b-it-4bit",
            displayName: "Gemma 3 12B (4-bit)",
            blurb: "Stronger reasoning — needs 16 GB+ unified memory.",
            approxDiskGB: 7.0,
            minMemoryGB: 16,
            qualityRank: 3
        ),
        GemmaMLXModel(
            huggingFaceID: "mlx-community/gemma-3-27b-it-4bit",
            displayName: "Gemma 3 27B (4-bit)",
            blurb: "Highest quality local Gemma — for 32 GB+ machines.",
            approxDiskGB: 15.0,
            minMemoryGB: 32,
            qualityRank: 4
        ),
    ]

    /// Prefer the strongest model that still fits comfortably.
    public static func recommended(for hardware: MacHardwareProfile) -> GemmaMLXModel {
        let fitting = all.filter { $0.fits(hardware) }.sorted { $0.qualityRank > $1.qualityRank }
        return fitting.first ?? all[0]
    }

    public static func models(for hardware: MacHardwareProfile) -> [(model: GemmaMLXModel, recommended: Bool, fits: Bool)] {
        let rec = recommended(for: hardware)
        return all.map { model in
            (model, model.id == rec.id, model.fits(hardware))
        }
    }
}
