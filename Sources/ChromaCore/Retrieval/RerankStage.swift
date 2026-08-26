import Foundation

/// Стадия 7 конвейера: модель переставляет то, что осталось.
///
/// Отдельным типом, а не методом конвейера, ради второго вызывающего.
/// Поиск сразу по нескольким коллекциям сливает списки рангами и обязан
/// спрашивать модель **один раз про всю слитую выдачу**, а не по разу
/// на коллекцию: иначе модель сравнивает кандидатов только с земляками,
/// и лучший ответ из маленькой коллекции проигрывает середняку из
/// большой не по существу, а по составу списка.
///
/// Внутри — ровно то, что делал конвейер, слово в слово: голова списка
/// уходит модели, хвост остаётся на месте, потому что о нём модель ничего
/// не говорила.
public struct RerankStage: Sendable {
    /// Чат-модель со схемой — режим `.chatSchema`.
    public let complete: RetrievalPipeline.ChatCompleter?
    /// Прямой вызов без шаблона чата — режим `.crossEncoder`.
    public let completePlain: RetrievalPipeline.PlainCompleter?
    /// Контекст, с которым **загружена** модель переранжирования.
    public let contextTokens: Int?
    /// Измеренное «символов на токен».
    public let charactersPerToken: Double?

    public init(
        complete: RetrievalPipeline.ChatCompleter? = nil,
        completePlain: RetrievalPipeline.PlainCompleter? = nil,
        contextTokens: Int? = nil,
        charactersPerToken: Double? = nil
    ) {
        self.complete = complete
        self.completePlain = completePlain
        self.contextTokens = contextTokens
        self.charactersPerToken = charactersPerToken
    }

    /// Настройки переранжирования одного профиля — чтобы сравнивать профили
    /// между собой.
    ///
    /// Нужны поиску по нескольким коллекциям: слитую выдачу переранжируют
    /// один раз, а профиль у каждой коллекции свой. Спрашивать модель
    /// настройками одной коллекции про документы другой — значит решать за
    /// человека, чей профиль главнее; поэтому стадия работает только когда
    /// все выбранные коллекции просят **одного и того же**.
    public struct Settings: Hashable, Sendable {
        public let enabled: Bool
        public let mode: RerankMode
        public let model: String
        public let candidates: Int
        public let instruction: String
        public let prompt: String

        public init(profile: SearchProfile) {
            enabled = profile.rerankEnabled && !profile.rerankModel.isEmpty
            mode = profile.rerankMode
            model = profile.rerankModel
            candidates = profile.rerankCandidates
            instruction = profile.rerankInstruction
            prompt = profile.rerankPrompt
        }
    }

    /// Есть ли чем переранжировать в этом режиме.
    ///
    /// Готовность зависит от режима: чат-схеме нужна чат-модель,
    /// переранжировщику — прямой вызов. Проверять только чат значило бы
    /// объявлять «модель не передана» там, где она и не нужна.
    public func isReady(for mode: RerankMode) -> Bool {
        mode == .crossEncoder ? completePlain != nil : complete != nil
    }

    /// Sends the head of the list to a chat model and applies its order.
    ///
    /// Only the head: twenty is the cap the section fixes, and a longer prompt
    /// is both slower and worse. The tail keeps its place — it was never shown
    /// to the model, so nothing has been said about it.
    ///
    /// The text sent is the result's own, without the context attached in stage
    /// 6: ranking by the surroundings would rank by the surroundings.
    public func run(
        _ hits: [RetrievalHit], profile: SearchProfile, query: String
    ) async throws -> (hits: [RetrievalHit], note: String) {
        guard !profile.rerankModel.isEmpty else { throw RerankError.noModelChosen }
        // Сколько показать — из профиля, а не из константы.
        let head = Array(hits.prefix(Reranker.candidateCount(profile.rerankCandidates)))
        let tail = Array(hits.dropFirst(head.count))
        guard head.count > 1 else {
            return (hits, String(localized: "переранжировать нечего: кандидат один"))
        }

        switch profile.rerankMode {
        case .chatSchema:
            guard let complete else { throw RerankError.noModelChosen }
            // Промпт укладывается в контекст **до** отправки. Иначе один движок
            // отвечает 400, а другой молча обрезает список — и ранжирование
            // выходит по обрубку, о чём никто не узнаёт.
            let fitted = Reranker.fit(
                documents: head.map { $0.document ?? "" },
                query: query, template: profile.rerankPrompt,
                contextTokens: contextTokens,
                charactersPerToken: charactersPerToken
                    ?? TokenEstimator.pessimisticCharactersPerToken,
                ratioWasMeasured: charactersPerToken != nil
            )
            guard !fitted.documents.isEmpty else {
                throw RerankError.contextTooSmall(tokens: contextTokens ?? 0)
            }
            // Отброшенные хвостом кандидаты остаются на своих местах, как всё,
            // о чём модель не высказалась.
            let asked = Array(head.prefix(fitted.documents.count))
            let unasked = Array(head.dropFirst(asked.count))
            let prompt = Reranker.prompt(
                template: profile.rerankPrompt, query: query, documents: fitted.documents
            )
            let answer = try await complete(prompt, profile.rerankModel, Reranker.schema)
            let verdicts = try Reranker.verdicts(from: answer, count: asked.count)
            return (
                Reranker.reordered(asked, by: verdicts) + unasked + tail,
                String(localized: "модель \(profile.rerankModel), кандидатов \(asked.count), один вызов по схеме")
                    + (fitted.note.map { ", \($0)" } ?? "")
            )

        case .crossEncoder:
            guard let completePlain else { throw RerankError.noPlainCompleter }
            let plainRatio = charactersPerToken ?? TokenEstimator.pessimisticCharactersPerToken
            guard CrossEncoderReranker.documentLimit(
                contextTokens: contextTokens, charactersPerToken: plainRatio
            ) > 0 else {
                throw RerankError.contextTooSmall(tokens: contextTokens ?? 0)
            }
            // По вызову на фрагмент — так устроены переранжировщики. Дороже
            // одного вызова, зато это единственный способ, которым такая
            // модель вообще умеет отвечать.
            let instruction = CrossEncoderReranker.instruction(from: profile.rerankInstruction)
            var scores: [Double?] = []
            for hit in head {
                let answer = try await completePlain(
                    CrossEncoderReranker.prompt(
                        query: query, document: hit.document ?? "", instruction: instruction,
                        contextTokens: contextTokens, charactersPerToken: plainRatio
                    ),
                    profile.rerankModel,
                    CrossEncoderReranker.answerTokens
                )
                scores.append(CrossEncoderReranker.score(answer))
            }
            guard scores.contains(where: { $0 != nil }) else { throw RerankError.nothingUsable }
            let understood = scores.compactMap { $0 }
            let unclear = scores.count - understood.count
            // Заметка говорит про шкалу, а не про «подошло»: у «да/нет» это
            // 1 и 0, у балльной модели — 5 и 1, и одно слово «подошло» на обе
            // не годится.
            let range = understood.isEmpty
                ? ""
                : String(localized: ", баллы от \(Self.plain(understood.min() ?? 0)) до \(Self.plain(understood.max() ?? 0))")
            return (
                CrossEncoderReranker.reordered(head, scores: scores) + tail,
                String(localized: "переранжировщик \(profile.rerankModel): вызовов \(head.count)")
                    + range
                    + (unclear > 0 ? String(localized: ", не понят ответ по \(unclear)") : "")
            )
        }
    }

    /// Балл в заметке — без хвоста «.0»: шкала бывает целой («5») и дробной
    /// («0.87»), и показывать «5.0» значит выдумывать точность.
    static func plain(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}
