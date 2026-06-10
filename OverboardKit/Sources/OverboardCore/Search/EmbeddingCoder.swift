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

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0 ..< a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
