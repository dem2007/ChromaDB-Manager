import XCTest
@testable import ChromaCore

// MARK: - G5: empty means «not sent»

final class ChatGenerationRequestTests: XCTestCase {
    /// The rule of A1.4, applied to generation: a field nobody filled in must
    /// be absent from the body, not sent as our guess at the server's default.
    func testEmptyExtendedFieldsAreAbsentFromTheRequest() {
        let fields = ChatGenerationSettings().requestFields()
        for key in ["top_p", "top_k", "min_p", "repeat_penalty", "frequency_penalty", "max_tokens"] {
            XCTAssertNil(fields[key], "\(key) не должен попадать в тело запроса, пока поле пустое")
        }
        XCTAssertEqual(fields["temperature"] as? Double, 0, "temperature передаётся всегда")
        XCTAssertEqual(fields["seed"] as? Int, ChatGenerationSettings.defaultSeed, "seed зафиксирован по умолчанию")
    }

    func testFilledFieldsDoReachTheRequest() {
        var settings = ChatGenerationSettings()
        settings.topP = 0.9
        settings.topK = 40
        settings.minP = 0.05
        settings.repeatPenalty = 1.1
        settings.frequencyPenalty = 0.5
        settings.maxTokens = 1500
        let fields = settings.requestFields()
        XCTAssertEqual(fields["top_p"] as? Double, 0.9)
        XCTAssertEqual(fields["top_k"] as? Int, 40)
        XCTAssertEqual(fields["min_p"] as? Double, 0.05)
        XCTAssertEqual(fields["repeat_penalty"] as? Double, 1.1)
        XCTAssertEqual(fields["frequency_penalty"] as? Double, 0.5)
        XCTAssertEqual(fields["max_tokens"] as? Int, 1500)
    }

    /// G1 found `presence_penalty` accepted with 200 and then ignored. A
    /// setting that pretends to work is worse than a missing one, so it must
    /// not exist anywhere in the request — nor in the UI.
    func testPresencePenaltyIsNotSentAtAll() {
        var settings = ChatGenerationSettings()
        settings.topP = 0.5
        XCTAssertNil(settings.requestFields()["presence_penalty"])
    }

    /// «Not sent» and «sent as zero» must never collide in the digest.
    func testAbsentAndZeroAreDifferentInTheSignature() {
        var absent = ChatGenerationSettings()
        absent.topP = nil
        var zero = ChatGenerationSettings()
        zero.topP = 0
        XCTAssertNotEqual(absent.signature, zero.signature)
    }

    func testUnfixingTheSeedRemovesItFromTheRequest() {
        var settings = ChatGenerationSettings()
        settings.seed = nil
        XCTAssertNil(settings.requestFields()["seed"])
    }
}

// MARK: - The picker must not disagree with the form around it

final class ModelPickerOptionsTests: XCTestCase {
    /// Found by clicking through the form: on a fresh launch the list of chat
    /// models is empty until «Проверить соединение», so a source configured
    /// earlier drew an empty picker — while the indicator under it had already
    /// probed the saved model and reported on it.
    func testTheConfiguredModelSurvivesAnEmptyList() {
        XCTAssertEqual(ModelPickerOptions.merging(configured: "chat-a", into: []), ["chat-a"])
    }

    func testTheConfiguredModelIsNotDuplicatedWhenTheListArrives() {
        let options = ModelPickerOptions.merging(configured: "chat-a", into: ["chat-a", "chat-b"])
        XCTAssertEqual(options, ["chat-a", "chat-b"])
    }

    func testNothingIsAddedWhenNoModelIsConfigured() {
        XCTAssertEqual(ModelPickerOptions.merging(configured: nil, into: ["chat-a"]), ["chat-a"])
        XCTAssertEqual(ModelPickerOptions.merging(configured: "", into: ["chat-a"]), ["chat-a"])
    }
}

// MARK: - G2 / G6: schema shape and collection identity

final class StructuredOutputParsingTests: XCTestCase {
    /// The shape the schema of G2 produces.
    func testParsesTheStructuredObjectShape() {
        let answer = #"{"chunks": ["первый фрагмент", "второй фрагмент"]}"#
        XCTAssertEqual(LLMChunker.parse(answer), ["первый фрагмент", "второй фрагмент"])
    }

    /// The fallback path: a model without schema support answers with a bare
    /// array, often wrapped in prose and fences.
    func testStillParsesABareArrayFromAChattyAnswer() {
        let answer = """
        Конечно! Вот фрагменты:
        ```json
        ["первый", "второй"]
        ```
        """
        XCTAssertEqual(LLMChunker.parse(answer), ["первый", "второй"])
    }

    func testTruncatedJSONDoesNotParse() {
        // What a `finish_reason: length` answer actually looks like.
        XCTAssertNil(LLMChunker.parse(#"{"chunks": ["Кошка спи"#))
    }
}

final class GenerationInsideTheStrategyHashTests: XCTestCase {
    private func llm(_ change: (inout ChunkingConfiguration) -> Void = { _ in }) -> ChunkingConfiguration {
        var c = ChunkingConfiguration(strategy: .llmBased, chatModel: "chat", promptTemplate: "Раздели.")
        change(&c)
        return c
    }

    /// these shape the boundaries, so they are part of the collection's
    /// identity — changing one has to be visible as heterogeneity.
    func testSeedAndTokenLimitAndExtendedFieldsAllMoveTheDigest() {
        let base = llm()
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.seed = 999 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.maxTokens = 500 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.topP = 0.5 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.topK = 20 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.minP = 0.1 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.repeatPenalty = 1.2 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.generation.frequencyPenalty = 0.3 }))
        XCTAssertNotEqual(StrategyParamsHash.of(base), StrategyParamsHash.of(llm { $0.useStructuredOutput = false }))
    }

    /// The counterpart from G6: a strategy that never calls a chat model must
    /// not have its identity moved by generation settings.
    func testGenerationDoesNotTouchTheDigestOfANonLLMStrategy() {
        var fixed = ChunkingConfiguration(strategy: .fixed, chunkSize: 500, sizeUnit: .characters)
        let before = StrategyParamsHash.of(fixed)
        fixed.generation.seed = 12345
        fixed.generation.topP = 0.4
        XCTAssertEqual(before, StrategyParamsHash.of(fixed))
    }

    /// Widening the digest is a migration, not a formula edit: without the
    /// version bump every existing collection would call itself heterogeneous
    /// at once and ask for a re-index that changes nothing.
    func testTheSchemaVersionWasBumpedForTheWiderDigest() {
        XCTAssertEqual(StrategyParamsHash.currentSchemaVersion, 2)
        let old = StrategyParamsHash(schemaVersion: 1, digest: "whatever")
        let now = StrategyParamsHash.of(llm())
        XCTAssertEqual(
            StrategyParamsHash.compare(stored: old, current: now), .migrate,
            "коллекция со старой версией пересчитывается молча, а не объявляется неоднородной"
        )
    }
}

// MARK: - G4: an older configuration keeps its recipe

final class ChunkingConfigurationMigrationTests: XCTestCase {
    /// A source configured before part G stored a flat `temperature` and no
    /// generation block. Losing it would silently re-chunk that source with
    /// different settings than it was set up with.
    func testAPreGConfigurationKeepsItsTemperature() throws {
        let json = #"{"strategy":"llmBased","temperature":0.7,"chatModel":"chat"}"#
        let decoded = try JSONDecoder().decode(ChunkingConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.temperature, 0.7, accuracy: 0.0001)
        XCTAssertEqual(decoded.generation.temperature, 0.7, accuracy: 0.0001)
        XCTAssertEqual(decoded.generation.seed, ChatGenerationSettings.defaultSeed,
                       "остальные поля берут документированные значения по умолчанию")
    }

    func testAPostGConfigurationRoundTrips() throws {
        var original = ChunkingConfiguration(strategy: .llmBased, chatModel: "chat")
        original.generation.seed = 4242
        original.generation.topK = 7
        original.generation.maxTokens = 900
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChunkingConfiguration.self, from: data)
        XCTAssertEqual(decoded.generation.seed, 4242)
        XCTAssertEqual(decoded.generation.topK, 7)
        XCTAssertEqual(decoded.generation.maxTokens, 900)
        XCTAssertEqual(StrategyParamsHash.of(original), StrategyParamsHash.of(decoded))
    }

    func testSeedIsFixedByDefault() {
        // a re-run of the same file must produce the same boundaries.
        XCTAssertNotNil(ChunkingConfiguration(strategy: .llmBased).generation.seed)
    }
}
