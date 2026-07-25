import SwiftUI

/// Eight+ immersive study modes under the Study section.
enum StudyDestination: String, CaseIterable, Identifiable, Hashable {
    case review
    case context
    case collocations
    case production
    case challenge
    case recognizeText
    case miniDialogue
    case contextMix
    case voiceMix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: "Review"
        case .context: "Context"
        case .collocations: "Collocations"
        case .production: "Produce"
        case .challenge: "Challenge"
        case .recognizeText: "Recognize text"
        case .miniDialogue: "Mini-dialogue"
        case .contextMix: "Context mix"
        case .voiceMix: "Voice mix"
        }
    }

    /// Localized short label for study hub tiles (matches reference design languages).
    var localizedTitle: String {
        switch AppL10n.code {
        case "ru":
            switch self {
            case .review: return "Повторение"
            case .context: return "Контекст"
            case .collocations: return "Коллокации"
            case .production: return "Продукция"
            case .challenge: return "Челлендж"
            case .recognizeText: return "Распознать текст"
            case .miniDialogue: return "Мини-диалог"
            case .contextMix: return "Контекст-микс"
            case .voiceMix: return "Голосовой микс"
            }
        case "zh":
            switch self {
            case .review: return "复习"
            case .context: return "语境"
            case .collocations: return "搭配"
            case .production: return "产出"
            case .challenge: return "挑战"
            case .recognizeText: return "识别文字"
            case .miniDialogue: return "迷你对话"
            case .contextMix: return "语境混合"
            case .voiceMix: return "语音混合"
            }
        case "ja":
            switch self {
            case .review: return "復習"
            case .context: return "文脈"
            case .collocations: return "コロケーション"
            case .production: return "産出"
            case .challenge: return "チャレンジ"
            case .recognizeText: return "テキスト認識"
            case .miniDialogue: return "ミニ対話"
            case .contextMix: return "文脈ミックス"
            case .voiceMix: return "ボイスミックス"
            }
        case "ko":
            switch self {
            case .review: return "복습"
            case .context: return "문맥"
            case .collocations: return "연어"
            case .production: return "산출"
            case .challenge: return "챌린지"
            case .recognizeText: return "텍스트 인식"
            case .miniDialogue: return "미니 대화"
            case .contextMix: return "문맥 믹스"
            case .voiceMix: return "음성 믹스"
            }
        default:
            return title
        }
    }

    var subtitle: String {
        switch self {
        case .review: AppL10n.t("study.mode.review.sub")
        case .context: AppL10n.t("study.mode.context.sub")
        case .collocations: AppL10n.t("study.mode.collocations.sub")
        case .production: AppL10n.t("study.mode.production.sub")
        case .challenge: AppL10n.t("study.mode.challenge.sub")
        case .recognizeText: AppL10n.t("study.mode.recognizeText.sub")
        case .miniDialogue: AppL10n.t("study.mode.miniDialogue.sub")
        case .contextMix: AppL10n.t("study.mode.contextMix.sub")
        case .voiceMix: AppL10n.t("study.mode.voiceMix.sub")
        }
    }

    var systemImage: String {
        switch self {
        case .review: "arrow.triangle.2.circlepath"
        case .context: "arrow.uturn.backward"
        case .collocations: "link"
        case .production: "pencil.line"
        case .challenge: "bolt.fill"
        case .recognizeText: "viewfinder"
        case .miniDialogue: "bubble.left.and.bubble.right.fill"
        case .contextMix: "square.stack.3d.up.fill"
        case .voiceMix: "waveform.circle.fill"
        }
    }
}
