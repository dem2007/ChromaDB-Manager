import XCTest
@testable import ChromaCore

/// §E3 — MMR: ten near-identical fragments are not ten results.
final class MaximalMarginalRelevanceTests: XCTestCase {
    /// Three clusters, well apart, four vectors each.
    private func clusters() -> [MaximalMarginalRelevance.Candidate] {
        let centres: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        var candidates: [MaximalMarginalRelevance.Candidate] = []
        for (cluster, centre) in centres.enumerated() {
            for member in 0..<4 {
                // A slight nudge off the centre, so members of one cluster are
                // near-identical but not literally equal.
                var vector = centre
                vector[(cluster + 1) % 3] += Double(member) * 0.01
                candidates.append(MaximalMarginalRelevance.Candidate(
                    id: "c\(cluster)-\(member)",
                    // The first cluster is the most relevant, and inside every
                    // cluster relevance falls slowly.
                    relevance: 1 - Double(cluster) * 0.05 - Double(member) * 0.001,
                    vector: vector
                ))
            }
        }
        return candidates
    }

    private func clustersOf(_ ids: [String]) -> Set<String> {
        Set(ids.map { String($0.prefix(2)) })
    }

    func testAtLambdaOneTheAnswerIsThePlainRanking() {
        let chosen = MaximalMarginalRelevance.select(clusters(), count: 3, lambda: 1)
        XCTAssertEqual(chosen, ["c0-0", "c0-1", "c0-2"])
        XCTAssertEqual(clustersOf(chosen), ["c0"], "λ = 1 — это обычное ранжирование, один кластер")
    }

    func testAtLambdaAHalfEveryClusterIsRepresented() {
        let chosen = MaximalMarginalRelevance.select(clusters(), count: 3, lambda: 0.5)
        XCTAssertEqual(clustersOf(chosen), ["c0", "c1", "c2"])
    }

    func testTheDefaultLambdaIsTheOneTheSectionFixes() {
        XCTAssertEqual(MaximalMarginalRelevance.defaultLambda, 0.7, accuracy: 0.0001)
    }

    // MARK: - Boundaries

    func testTheEdgesOfLambdaDoNotBreak() {
        for lambda in [0.0, 1.0, -5.0, 42.0] {
            let chosen = MaximalMarginalRelevance.select(clusters(), count: 4, lambda: lambda)
            XCTAssertEqual(chosen.count, 4, "λ = \(lambda)")
            XCTAssertEqual(Set(chosen).count, 4, "λ = \(lambda): результат не должен повторяться")
        }
    }

    func testAPoolSmallerThanRequestedGivesWhatThereIs() {
        let two = Array(clusters().prefix(2))
        XCTAssertEqual(MaximalMarginalRelevance.select(two, count: 10, lambda: 0.7).count, 2)
    }

    func testEmptyAndSingleCandidateSetsAreAnswersNotErrors() {
        XCTAssertTrue(MaximalMarginalRelevance.select([], count: 5, lambda: 0.7).isEmpty)
        let one = Array(clusters().prefix(1))
        XCTAssertEqual(MaximalMarginalRelevance.select(one, count: 5, lambda: 0.7), ["c0-0"])
        XCTAssertTrue(MaximalMarginalRelevance.select(one, count: 0, lambda: 0.7).isEmpty)
    }

    func testAZeroVectorIsSimilarToNothingRatherThanToEverything() {
        var candidates = clusters()
        candidates.append(MaximalMarginalRelevance.Candidate(
            id: "zero", relevance: 0.99, vector: [0, 0, 0]
        ))
        let chosen = MaximalMarginalRelevance.select(candidates, count: 4, lambda: 0.5)
        XCTAssertEqual(Set(chosen).count, 4)
    }

    // MARK: - Against a reference computed by hand

    /// Five vectors on the unit circle, λ = 0.5, three to pick.
    ///
    /// Worked out on paper, so the implementation is checked against the
    /// formula and not against itself:
    ///
    /// relevance: a 1.00, b 0.95, c 0.90, d 0.60, e 0.55
    /// a ≈ b (0.995), c is 90° from a, d ≈ e (0.995) and 180° from a.
    ///
    /// step 1: a wins on relevance alone → a
    /// step 2: 0.5·0.95 − 0.5·0.995 = −0.0225 (b)
    ///         0.5·0.90 − 0.5·0     = +0.45   (c) ← c
    ///         0.5·0.60 − 0.5·(−1)  = +0.80   (d) ← d wins
    /// step 3: b: 0.5·0.95 − 0.5·max(0.995, 0) = −0.0225
    ///         c: 0.5·0.90 − 0.5·max(0, 0)     = +0.45  ← c
    ///         e: 0.5·0.55 − 0.5·max(−1, 0.995)= −0.2225
    /// answer: a, d, c
    func testTheResultMatchesAHandComputedReference() {
        func onCircle(_ degrees: Double) -> [Double] {
            let radians = degrees * .pi / 180
            return [cos(radians), sin(radians)]
        }
        let candidates = [
            MaximalMarginalRelevance.Candidate(id: "a", relevance: 1.00, vector: onCircle(0)),
            MaximalMarginalRelevance.Candidate(id: "b", relevance: 0.95, vector: onCircle(6)),
            MaximalMarginalRelevance.Candidate(id: "c", relevance: 0.90, vector: onCircle(90)),
            MaximalMarginalRelevance.Candidate(id: "d", relevance: 0.60, vector: onCircle(180)),
            MaximalMarginalRelevance.Candidate(id: "e", relevance: 0.55, vector: onCircle(186)),
        ]
        XCTAssertEqual(MaximalMarginalRelevance.select(candidates, count: 3, lambda: 0.5), ["a", "d", "c"])
    }

    func testTiesGoToWhicheverTheCollectionRankedFirst() {
        let candidates = [
            MaximalMarginalRelevance.Candidate(id: "первый", relevance: 0.5, vector: [1, 0]),
            MaximalMarginalRelevance.Candidate(id: "второй", relevance: 0.5, vector: [0, 1]),
        ]
        XCTAssertEqual(MaximalMarginalRelevance.select(candidates, count: 1, lambda: 0.7), ["первый"])
    }

    // MARK: - The arithmetic itself

    func testNormalisationMakesADotProductACosine() {
        let left = MaximalMarginalRelevance.normalised([3, 4])
        let right = MaximalMarginalRelevance.normalised([3, 4])
        XCTAssertEqual(MaximalMarginalRelevance.dot(left, right), 1, accuracy: 0.0001)
        let opposite = MaximalMarginalRelevance.normalised([-3, -4])
        XCTAssertEqual(MaximalMarginalRelevance.dot(left, opposite), -1, accuracy: 0.0001)
        let orthogonal = MaximalMarginalRelevance.normalised([-4, 3])
        XCTAssertEqual(MaximalMarginalRelevance.dot(left, orthogonal), 0, accuracy: 0.0001)
    }

    func testAZeroVectorStaysZero() {
        XCTAssertEqual(MaximalMarginalRelevance.normalised([0, 0, 0]), [0, 0, 0])
    }

    func testVectorsOfDifferentLengthsDoNotCrash() {
        XCTAssertEqual(MaximalMarginalRelevance.dot([1, 2, 3], [1, 2]), 0)
        XCTAssertEqual(MaximalMarginalRelevance.dot([], []), 0)
    }
}

/// §E3 — how the stage sits in the pipeline.
final class DiversityStageTests: XCTestCase {
    private func hit(_ id: String, distance: Double, vector: [Double]?) -> RetrievalHit {
        RetrievalHit(
            id: id, document: id, metadata: nil, distance: distance,
            embedding: vector
        )
    }

    func testWithoutVectorsNothingIsReordered() {
        let hits = [hit("a", distance: 0.1, vector: nil), hit("b", distance: 0.2, vector: nil)]
        let result = RetrievalPipeline.diversifying(hits, count: 2, lambda: 0.5, metric: .cosine)
        XCTAssertEqual(result.hits.map(\.id), ["a", "b"])
        XCTAssertEqual(result.note, "векторов кандидатов нет — переупорядочивать нечем")
    }

    /// A result whose embedding did not come back must not vanish.
    func testACandidateWithoutAVectorKeepsItsPlaceAtTheEnd() {
        let hits = [
            hit("a", distance: 0.10, vector: [1, 0]),
            hit("b", distance: 0.11, vector: [0.99, 0.01]),
            hit("нет вектора", distance: 0.12, vector: nil),
            hit("c", distance: 0.50, vector: [0, 1]),
        ]
        let result = RetrievalPipeline.diversifying(hits, count: 4, lambda: 0.5, metric: .cosine)
        XCTAssertEqual(Set(result.hits.map(\.id)).count, 4, "ни один результат не должен потеряться")
        XCTAssertEqual(result.hits.last?.id, "нет вектора")
    }

    func testOnACosineCollectionRelevanceComesFromTheDistance() {
        // b is nearly identical to a but much closer to the query; with λ high
        // the ranking should still put it second, not drop it.
        let hits = [
            hit("a", distance: 0.10, vector: [1, 0]),
            hit("b", distance: 0.12, vector: [0.999, 0.001]),
            hit("c", distance: 0.90, vector: [0, 1]),
        ]
        let byRelevance = RetrievalPipeline.diversifying(hits, count: 2, lambda: 1, metric: .cosine)
        XCTAssertEqual(byRelevance.hits.map(\.id), ["a", "b"])

        let byDiversity = RetrievalPipeline.diversifying(hits, count: 2, lambda: 0.4, metric: .cosine)
        XCTAssertEqual(byDiversity.hits.map(\.id), ["a", "c"], "при упоре на разнообразие второй результат — не копия первого")
    }

    /// `l2` and `ip` have no bounded scale, so a percentage would be invented.
    /// The collection's own order becomes the relevance instead.
    func testOnAnUnboundedMetricTheRankIsTheRelevance() {
        let hits = [
            hit("a", distance: 41.0, vector: [1, 0]),
            hit("b", distance: 41.5, vector: [0.999, 0.001]),
            hit("c", distance: 90.0, vector: [0, 1]),
        ]
        let result = RetrievalPipeline.diversifying(hits, count: 2, lambda: 0.4, metric: .l2)
        XCTAssertEqual(result.hits.map(\.id), ["a", "c"])
    }

    func testTheNoteNamesTheLambda() {
        let hits = [hit("a", distance: 0.1, vector: [1, 0]), hit("b", distance: 0.2, vector: [0, 1])]
        let result = RetrievalPipeline.diversifying(hits, count: 2, lambda: 0.7, metric: .cosine)
        XCTAssertEqual(result.note?.contains("0.70"), true, result.note ?? "-")
    }
}

/// §E3 — the profile switch.
final class DiversityProfileTests: XCTestCase {
    func testANewProfileHasItOff() {
        let profile = SearchProfile(collectionName: "к")
        XCTAssertFalse(profile.diversityEnabled)
        XCTAssertFalse(profile.requestedStages.contains(.diversity))
        XCTAssertEqual(profile.diversityLambda, MaximalMarginalRelevance.defaultLambda, accuracy: 0.0001)
    }

    /// MMR chooses n out of a pool; with a pool of n there is nothing to choose.
    func testTurningItOnAsksForAPool() {
        var profile = SearchProfile(collectionName: "к")
        profile.diversityEnabled = true
        XCTAssertTrue(profile.requestedStages.contains(.diversity))
        XCTAssertEqual(profile.poolSize(nResults: 5, stages: profile.requestedStages), 25)
    }
}
