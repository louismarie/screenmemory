import Foundation
import CoreML

/// Runs the MiniLM CoreML model on the Apple Neural Engine.
/// computeUnits = .cpuAndNeuralEngine (the bench showed ALL mistakenly picks the GPU).
final class Embedder {
    private let model: MLModel
    private let tokenizer: BertTokenizer
    private let seqLen = 128
    let dim = 512   // distiluse-base-multilingual-cased-v2

    init() throws {
        guard let mlpkg = Bundle.module.url(forResource: "Embed", withExtension: "mlpackage"),
              let vocab = Bundle.module.url(forResource: "vocab", withExtension: "txt")
        else { throw Err.resource }

        let compiled = try MLModel.compileModel(at: mlpkg)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: compiled, configuration: cfg)
        self.tokenizer = try BertTokenizer(vocabURL: vocab, maxLen: seqLen, lowercase: false)
    }

    func embed(_ text: String) throws -> [Float] {
        let (ids, mask) = tokenizer.encode(text)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": try multiArray(ids),
            "attention_mask": try multiArray(mask),
        ])
        let out = try model.prediction(from: input)
        guard let name = out.featureNames.first(where: { $0 != "input_ids" && $0 != "attention_mask" }),
              let arr = out.featureValue(for: name)?.multiArrayValue
        else { throw Err.output }
        var vec = [Float](repeating: 0, count: arr.count)
        for i in 0..<arr.count { vec[i] = arr[i].floatValue }
        return vec
    }

    private func multiArray(_ values: [Int32]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let p = a.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in 0..<values.count { p[i] = values[i] }
        return a
    }

    enum Err: Error { case resource, output }
}
