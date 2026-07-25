import Foundation
import AVFoundation
import NaturalLanguage
import Observation

/// System TTS with reading-field preference (kana / pinyin / IPA) for disambiguation.
@MainActor
@Observable
final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()

    /// True when the system has at least one voice for `language` (e.g. `fr`, `fr-FR`).
    static func canSpeak(language: String?) -> Bool {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard !voices.isEmpty else { return false }
        guard let language, !language.isEmpty else { return true }
        let prefix = String(language.prefix(2)).lowercased()
        return voices.contains { $0.language.lowercased().hasPrefix(prefix) }
    }

    func speak(_ text: String, reading: String? = nil, language: String? = nil) {
        synthesizer.stopSpeaking(at: .immediate)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lang = resolveLanguage(text: trimmed, reading: reading, hint: language)
        let reading = reading?.trimmingCharacters(in: .whitespacesAndNewlines)

        let utterance: AVSpeechUtterance
        let voiceCode: String

        switch lang {
        case .japanese:
            voiceCode = "ja-JP"
            if let kana = reading, isMostlyKana(kana) {
                utterance = AVSpeechUtterance(string: kana)
            } else {
                utterance = AVSpeechUtterance(string: trimmed)
            }
        case .chinese:
            voiceCode = "zh-CN"
            utterance = AVSpeechUtterance(string: trimmed)
        case .english:
            voiceCode = "en-US"
            utterance = AVSpeechUtterance(string: trimmed)
        case .other(let code):
            voiceCode = code
            utterance = AVSpeechUtterance(string: trimmed)
        }

        if let voice = AVSpeechSynthesisVoice(language: voiceCode) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private enum SpeechLanguage {
        case japanese, chinese, english, other(String)
    }

    private func resolveLanguage(text: String, reading: String?, hint: String?) -> SpeechLanguage {
        if let base = hint?.lowercased() {
            if base.hasPrefix("ja") { return .japanese }
            if base.hasPrefix("zh") || base.hasPrefix("cmn") || base.hasPrefix("yue") { return .chinese }
            if base.hasPrefix("en") { return .english }
        }
        if let reading, isMostlyKana(reading) { return .japanese }
        if containsKana(text) { return .japanese }
        if containsHan(text) {
            if let reading, looksLikePinyin(reading) { return .chinese }
            return mapDetected(text) ?? .chinese
        }
        if let detected = mapDetected(text) { return detected }
        if let base = hint?.lowercased(), !base.isEmpty { return .other(base) }
        return .english
    }

    private func mapDetected(_ text: String) -> SpeechLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        switch lang {
        case .japanese: return .japanese
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .english: return .english
        default: return .other(lang.rawValue)
        }
    }

    private func containsKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || $0.value == 0x30FC }
    }

    private func containsHan(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }

    private func isMostlyKana(_ s: String) -> Bool {
        var kana = 0, letters = 0
        for u in s.unicodeScalars {
            if (0x3040...0x30FF).contains(u.value) || u.value == 0x30FC { kana += 1 }
            else if CharacterSet.letters.contains(u) { letters += 1 }
        }
        return kana > 0 && kana >= letters
    }

    private func looksLikePinyin(_ s: String) -> Bool {
        s.range(
            of: "[A-Za-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]",
            options: .regularExpression
        ) != nil
    }
}
