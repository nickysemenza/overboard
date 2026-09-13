import Accelerate
import Foundation

/// Packs embedding vectors into compact Float32 blobs and scores them.
public enum EmbeddingCoder {
    public static func encode(_ vector: [Double]) -> Data {
        var floats = vector.map(Float.init)
        return floats.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// NLEmbedding's sentence vectors aren't stored pre-normalized (their
    /// magnitude varies), so this still computes both norms rather than
    /// assuming a unit-length input — but via vDSP instead of a scalar loop,
    /// which matters once `semanticSearch`/`relatedItems` score hundreds of
    /// candidates per query.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b)
        let normA = sqrt(vDSP.sumOfSquares(a))
        let normB = sqrt(vDSP.sumOfSquares(b))
        let denominator = normA * normB
        return denominator > 0 ? dot / denominator : 0
    }
}
