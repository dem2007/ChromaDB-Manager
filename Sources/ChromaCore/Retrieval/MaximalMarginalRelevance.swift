import Foundation
import Accelerate

/// Picks results that do not repeat each other.
///
/// The problem is ordinary and constant: a top-10 by cosine distance on a real
/// database is regularly ten near-identical fragments — chunks overlap by 15 %
/// by default, and documents repeat their own phrasing. The user gets one
/// thought ten times instead of ten thoughts.
///
/// Maximal Marginal Relevance fixes it with arithmetic on vectors that have
/// already been fetched: not one additional call to the model.
public enum MaximalMarginalRelevance {
    /// Balance between «ближе к запросу» and «не похоже на уже выбранное».
    ///
    /// 1 is the plain ranking, 0 ignores the query entirely. The default is what
    /// the section fixes; the slider that sets it is labelled «точность ↔
    /// разнообразие» rather than with a Greek letter, because nobody tuning a
    /// search thinks in lambdas.
    public static let defaultLambda = 0.7

    /// One candidate, as MMR needs to see it.
    public struct Candidate {
        public let id: String
        /// How relevant the collection said it is, 0…1. Bigger is closer.
        public let relevance: Double
        /// Unit-normalised, so a dot product *is* the cosine similarity.
        public let vector: [Double]

        public init(id: String, relevance: Double, vector: [Double]) {
            self.id = id
            self.relevance = relevance
            self.vector = MaximalMarginalRelevance.normalised(vector)
        }
    }

    /// Ids in the order MMR chose, longest-first by marginal value.
    ///
    /// Deterministic: ties go to the candidate the collection ranked higher, so
    /// the same query twice gives the same answer. A candidate without a vector
    /// cannot be compared to anything and is left in place at the end rather
    /// than dropped — losing a result because its embedding did not come back
    /// would be a worse failure than showing it out of order.
    public static func select(
        _ candidates: [Candidate], count: Int, lambda: Double
    ) -> [String] {
        guard count > 0, !candidates.isEmpty else { return [] }
        guard candidates.count > 1 else { return [candidates[0].id] }
        let lambda = min(1, max(0, lambda))
        let wanted = min(count, candidates.count)

        var remaining = Array(candidates.indices)
        var chosen: [Int] = []
        // The best similarity of each remaining candidate to anything already
        // chosen — updated as we go, so the whole thing stays O(n·k) instead of
        // recomputing every pair on every step.
        var similarityToChosen = [Double](repeating: -Double.infinity, count: candidates.count)

        while chosen.count < wanted, !remaining.isEmpty {
            var bestPosition = 0
            var bestScore = -Double.infinity
            for (position, index) in remaining.enumerated() {
                // The similarity is used as it comes, negatives included. The
                // section writes the formula without a floor, and the floor is
                // not neutral: clamping at zero turns «указывает в другую
                // сторону» into «просто не похоже», which is precisely the
                // distinction diversity is asking about.
                let redundancy = chosen.isEmpty ? 0 : similarityToChosen[index]
                let score = lambda * candidates[index].relevance - (1 - lambda) * redundancy
                // Strictly greater: the first candidate of an equal pair wins,
                // and the pool arrives in the collection's own order.
                if score > bestScore {
                    bestScore = score
                    bestPosition = position
                }
            }
            let picked = remaining.remove(at: bestPosition)
            chosen.append(picked)

            for index in remaining {
                let similarity = dot(candidates[picked].vector, candidates[index].vector)
                similarityToChosen[index] = max(similarityToChosen[index], similarity)
            }
        }
        return chosen.map { candidates[$0].id }
    }

    // MARK: - Arithmetic

    /// Through Accelerate, as the section requires — and because a dot product
    /// over a thousand dimensions, done a few thousand times, is exactly what
    /// vDSP exists for. No third-party dependency (rule 6 of Приложение 5).
    static func dot(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var result = 0.0
        vDSP_dotprD(left, 1, right, 1, &result, vDSP_Length(left.count))
        return result
    }

    /// A unit vector, so similarity is a dot product and nothing else.
    ///
    /// A zero vector stays zero: it is similar to nothing, which is the answer
    /// that keeps it from dominating the redundancy term.
    static func normalised(_ vector: [Double]) -> [Double] {
        guard !vector.isEmpty else { return vector }
        var squares = 0.0
        vDSP_svesqD(vector, 1, &squares, vDSP_Length(vector.count))
        let length = squares.squareRoot()
        guard length > 0, length.isFinite else { return vector }
        var scale = 1 / length
        var result = [Double](repeating: 0, count: vector.count)
        vDSP_vsmulD(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
