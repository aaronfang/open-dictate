import Foundation
import CoreML

final class SenseVoiceCoreMLProvider {
    struct Config {
        /// `SenseVoicePreprocessor.mlmodelc` directory path
        var preprocessorModelURL: URL
        /// `SenseVoiceSmall.mlmodelc` directory path
        var encoderModelURL: URL
        /// `vocab.json` path (SentencePiece token array)
        var vocabURL: URL
    }

    private let cfg: Config
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let vocab: [String]

    init(cfg: Config) throws {
        self.cfg = cfg

        let preCfg = MLModelConfiguration()
        preCfg.computeUnits = .cpuOnly
        preprocessor = try MLModel(contentsOf: cfg.preprocessorModelURL, configuration: preCfg)

        let encCfg = MLModelConfiguration()
        encCfg.computeUnits = .cpuAndNeuralEngine
        encoder = try MLModel(contentsOf: cfg.encoderModelURL, configuration: encCfg)

        let data = try Data(contentsOf: cfg.vocabURL)
        vocab = try JSONDecoder().decode([String].self, from: data)
    }

    /// 说明：SenseVoiceSmall 的推荐流水线为：
    /// waveform -> Preprocessor(FP32/CPU) -> features -> Encoder+CTC(FP16/ANE) -> logits -> greedy CTC decode -> text
    ///
    /// 参考：
    /// - `https://huggingface.co/FluidInference/sensevoice-small-coreml`
    /// - `https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/SenseVoice.md`
    ///
    /// MVP：先把模型加载与解码框架落地；后续把输入输出的具体 feature/logits key 与 shape bucket padding 补齐。
    func transcribe(waveformFloat32: [Float], sampleRate: Int = 16_000) throws -> String {
        guard sampleRate == 16_000 else {
            throw NSError(domain: "SenseVoiceCoreMLProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "SenseVoice expects 16kHz waveform"])
        }

        // 1) Preprocess
        // NOTE: 这里需要按模型的输入名构造 MLMultiArray/MLFeatureValue。
        // 由于不同转换版本的输入输出 key 可能不同，先用占位逻辑，确保整体结构可编译。
        _ = preprocessor
        _ = encoder
        _ = vocab

        // TODO(stt-sensevoice-spike): 补齐以下内容
        // - 构造 waveform 输入（shape 通常是 [n] 或 [1,n]）
        // - 读取 preprocessor 输出 features（560-d LFR）
        // - padding 到 enumerated bucket（128/256/512/1024/1800）
        // - 送入 encoder 得到 ctc_logits
        // - greedy CTC decode：collapse repeats，drop blank(0)，token->string，清理 <|...|> tags

        return ""
    }
}

