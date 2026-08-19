import XCTest
@testable import ChromaCore

/// Текстовая половина гибридного поиска не должна исчезать при включённом
/// разнообразии.
///
/// Живой замер на базе пользователя, запрос «ФНС сервера»: текстовый поиск
/// нашёл 200 документов, слияние дало 377 кандидатов — и выдача совпала
/// с той, где текстового поиска не было вовсе, до последнего идентификатора.
/// Причина: `$contains` отдаёт документы **без векторов**, MMR сравнивать их
/// не может и сваливал в хвост, а усечение до `n_results` выбрасывало весь
/// хвост целиком.
final class TextHalfSurvivesDiversityTests: XCTestCase {
    /// Кандидат с вектором: у каждого свой, иначе MMR сочтёт их копиями.
    private func withVector(_ id: String, _ index: Int, distance: Double) -> RetrievalHit {
        var hit = RetrievalHit(id: id, document: "текст \(id)", metadata: nil, distance: distance)
        hit.embedding = (0..<6).map { $0 == index ? 1.0 : 0.02 }
        return hit
    }

    /// Кандидат из текстовой половины: документ есть, вектора нет.
    private func withoutVector(_ id: String) -> RetrievalHit {
        RetrievalHit(id: id, document: "текст \(id)", metadata: nil, distance: nil, sources: [.text])
    }

    /// Главное: найденное текстом попадает в выдачу, а не в хвост за ней.
    func testTextOnlyCandidatesReachTheTop() {
        // Порядок слияния: вектор, текст, вектор, текст, …
        let hits = [
            withVector("в1", 0, distance: 0.10),
            withoutVector("т1"),
            withVector("в2", 1, distance: 0.20),
            withoutVector("т2"),
            withVector("в3", 2, distance: 0.30),
            withVector("в4", 3, distance: 0.40),
            withoutVector("т3"),
        ]

        let diversified = RetrievalPipeline.diversifying(hits, count: 2, lambda: 0.7, metric: .cosine)
        let order = diversified.hits.map(\.id)

        // Двух выбранных MMR достаточно, чтобы текстовые встали между ними,
        // а не после всех.
        XCTAssertLessThan(
            order.firstIndex(of: "т1") ?? .max, order.count - 1,
            "текстовый кандидат не должен оказаться в самом хвосте: \(order)"
        )
        XCTAssertEqual(order.first, "в1", "первым остаётся лучший по MMR")
        XCTAssertEqual(order.dropFirst().first, "т1", "следом — тот, кого текст поставил вторым")
        XCTAssertTrue(order.contains("т2") && order.contains("т3"), "ничего не потеряно: \(order)")
        XCTAssertEqual(diversified.note?.contains("без вектора"), true, "панель обязана сказать, что их расставили")
    }

    /// Место считается по **уцелевшим**, а не по всем пришедшим.
    ///
    /// Из двухсот векторных кандидатов MMR оставляет десять; если считать
    /// место текстового по выбывшим, он уедет за пределы `n_results` —
    /// ровно это и происходило.
    func testThePlaceIsCountedAmongSurvivors() {
        var hits: [RetrievalHit] = (0..<6).map { withVector("в\($0)", $0, distance: 0.1 + Double($0) / 100) }
        hits.append(withoutVector("текстовый"))

        // MMR оставляет двоих; текстовый пришёл седьмым, но перед ним
        // уцелело меньше двух — значит он обязан оказаться в первой тройке.
        let order = RetrievalPipeline.diversifying(hits, count: 2, lambda: 0.7, metric: .cosine).hits.map(\.id)
        XCTAssertLessThanOrEqual(
            (order.firstIndex(of: "текстовый") ?? .max) + 1, 3,
            "текстовый кандидат обязан подняться вслед за прореженной векторной половиной: \(order)"
        )
    }

    /// Ничего не меняется там, где векторы есть у всех: правило про хвост
    /// касается только кандидатов без вектора.
    func testNothingChangesWhenEveryCandidateHasAVector() {
        let hits = (0..<4).map { withVector("в\($0)", $0, distance: 0.1 + Double($0) / 100) }
        let diversified = RetrievalPipeline.diversifying(hits, count: 3, lambda: 0.7, metric: .cosine)
        XCTAssertEqual(diversified.hits.count, 3)
        XCTAssertEqual(diversified.hits.first?.id, "в0")
        XCTAssertEqual(diversified.note?.contains("без вектора"), false)
    }
}
