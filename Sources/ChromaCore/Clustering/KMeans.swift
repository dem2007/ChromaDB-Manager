import Foundation
import Accelerate

/// Генератор псевдослучайных чисел с явным зерном (SplitMix64).
///
/// Свой, а не `SystemRandomNumberGenerator`: k-means начинается со случайного
/// выбора центров, и без фиксированного зерна два прогона по одной и той же
/// коллекции дали бы разные темы — без единого изменения в данных. Правило G4
/// требует воспроизводимости, и здесь оно значит буквально это: тот же вход —
/// тот же отчёт.
///
/// Тринадцать строк арифметики вместо зависимости (правило 6 приложения 5).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Дробь в [0, 1). Через 53 старших бита — столько мантисса `Double` и
    /// вмещает; брать младшие у SplitMix64 незачем, но и вредно не будет.
    mutating func fraction() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Целое в [0, bound).
    mutating func index(below bound: Int) -> Int {
        guard bound > 1 else { return 0 }
        return min(bound - 1, Int(fraction() * Double(bound)))
    }
}

/// Набор векторов одной длины, разложенный в один плоский массив.
///
/// Плоско, а не массивом массивов: и k-means, и подсчёт расстояний ходят по
/// векторам подряд, а `[[Double]]` — это n отдельных выделений памяти, по
/// которым процессор прыгает вместо того, чтобы читать линейно.
///
/// **Векторы приводятся к единичной длине.** Кластеризация по направлению, а не
/// по длине: смысл в эмбеддингах кодируется направлением, а длина у большинства
/// моделей — артефакт. На единичных векторах косинусное расстояние равно
/// `1 − скалярное произведение`, и порядок совпадает с евклидовым, поэтому
/// метрика самой коллекции здесь ни при чём: мы не ищем, а группируем.
public struct VectorSet: Sendable {
    public let dimension: Int
    public let count: Int
    /// `count * dimension` значений подряд.
    public private(set) var values: [Double]
    /// Какие из поданных векторов сюда попали.
    ///
    /// Возвращается, а не выводится заново по тому же правилу: вызывающий
    /// держит рядом идентификаторы и тексты документов, и любое расхождение
    /// между «что отбросил набор» и «что отбросил вызывающий» приписало бы теме
    /// чужие примеры. Пусть правило будет одно и живёт здесь.
    public let keptIndexes: [Int]

    /// Нулевые векторы и векторы не той длины отбрасываются: у нулевого нет
    /// направления, а разной длины они быть не могут — это уже находка
    /// инспектора, а не работа для кластеризации.
    public init(vectors: [[Double]], dimension: Int) {
        self.dimension = dimension
        var values: [Double] = []
        values.reserveCapacity(vectors.count * dimension)
        var kept: [Int] = []
        kept.reserveCapacity(vectors.count)
        for (index, vector) in vectors.enumerated() where vector.count == dimension {
            var squares = 0.0
            vDSP_svesqD(vector, 1, &squares, vDSP_Length(dimension))
            let length = squares.squareRoot()
            guard length > 0, length.isFinite else { continue }
            var scale = 1 / length
            var unit = [Double](repeating: 0, count: dimension)
            vDSP_vsmulD(vector, 1, &scale, &unit, 1, vDSP_Length(dimension))
            guard unit.allSatisfy(\.isFinite) else { continue }
            values.append(contentsOf: unit)
            kept.append(index)
        }
        self.values = values
        self.count = kept.count
        self.keptIndexes = kept
    }

    init(values: [Double], dimension: Int, count: Int) {
        self.values = values
        self.dimension = dimension
        self.count = count
        self.keptIndexes = Array(0..<count)
    }

    public func vector(at index: Int) -> [Double] {
        Array(values[(index * dimension)..<((index + 1) * dimension)])
    }

    /// Подвыборка ровным шагом, а не случайная: подбор числа кластеров должен
    /// повторяться от прогона к прогону так же, как сам k-means.
    func strided(to limit: Int) -> (set: VectorSet, indexes: [Int]) {
        guard count > limit, limit > 0 else {
            return (self, Array(0..<count))
        }
        let step = Double(count) / Double(limit)
        var values: [Double] = []
        values.reserveCapacity(limit * dimension)
        var indexes: [Int] = []
        indexes.reserveCapacity(limit)
        for position in 0..<limit {
            let index = min(count - 1, Int(Double(position) * step))
            values.append(contentsOf: self.values[(index * dimension)..<((index + 1) * dimension)])
            indexes.append(index)
        }
        return (VectorSet(values: values, dimension: dimension, count: limit), indexes)
    }
}

/// k-means по векторам коллекции.
///
/// Сферический: центры приводятся к единичной длине после каждого пересчёта,
/// расстояние — косинусное. Никаких проекций, раскладок и диаграмм рассеяния
/// этот тип не строит и построить не может — он возвращает номера кластеров
/// и расстояния, а дальше из них складывается таблица (L5).
public enum KMeans {
    public struct Fit: Sendable {
        public let k: Int
        /// Для каждой точки — номер её кластера.
        public let assignments: [Int]
        /// Для каждой точки — косинусное расстояние до своего центра.
        public let distances: [Double]
        public let centroids: [[Double]]
        /// Сумма расстояний до своих центров: чем меньше, тем плотнее разбиение.
        public let inertia: Double
        public let iterations: Int
        public let converged: Bool
        /// Силуэт: насколько точки ближе к своим соседям по теме, чем к
        /// ближайшей чужой теме. От −1 до 1, больше — лучше.
        public let silhouette: Double
    }

    public static let defaultMaxIterations = 60
    /// По скольким точкам считается силуэт. Настоящий силуэт — это все пары
    /// расстояний, то есть квадрат от числа точек: на десяти тысячах векторов
    /// длиной в тысячу чисел он считался бы дольше самой кластеризации. На
    /// шестистах точках он занимает доли секунды и даёт ту же картину.
    public static let silhouetteSampleLimit = 600

    /// Одно разбиение при заданном k.
    ///
    /// `shouldStop` спрашивается между шагами. Без него отмена не работала
    /// вовсе: `fit` — синхронный счёт, и на десяти тысячах векторов длиной
    /// в тысячу чисел один его вызов идёт секунды, а `suggestK` вызывает его
    /// трижды. Человек нажимал «Отменить» и ещё полминуты смотрел на кнопку,
    /// потому что ближайшая проверка отмены была за пределами этого счёта
    ///. Прерванное разбиение возвращается как есть, с `converged`
    /// в `false`; решает, что с ним делать, вызывающий — он же и знает, что
    /// произошла отмена.
    public static func fit(
        _ points: VectorSet, k requestedK: Int, seed: UInt64,
        maxIterations: Int = defaultMaxIterations,
        shouldStop: () -> Bool = { false }
    ) -> Fit {
        let k = max(1, min(requestedK, points.count))
        guard points.count > 0, points.dimension > 0 else {
            return Fit(
                k: 0, assignments: [], distances: [], centroids: [],
                inertia: 0, iterations: 0, converged: true, silhouette: 0
            )
        }

        var centroids = seeds(points, k: k, seed: seed)
        var assignments = [Int](repeating: 0, count: points.count)
        var distances = [Double](repeating: 0, count: points.count)
        var iterations = 0
        var converged = false

        while iterations < maxIterations {
            if shouldStop() { break }
            iterations += 1
            let step = assign(points, centroids: centroids, k: k)
            // На первом шаге номера «не изменились» только потому, что все они
            // ещё нули: без этой оговорки прогон закончился бы, не начавшись.
            let changed = step.assignments != assignments || iterations == 1
            assignments = step.assignments
            distances = step.distances
            guard changed else { converged = true; break }
            centroids = recomputed(points, assignments: assignments, distances: distances, k: k)
        }
        // Последний пересчёт центров мог сдвинуть их после того, как номера уже
        // были розданы. Раздаём ещё раз, чтобы расстояния в отчёте относились
        // к тем центрам, которые в отчёт и попадут.
        let final = assign(points, centroids: centroids, k: k)

        return Fit(
            k: k,
            assignments: final.assignments,
            distances: final.distances,
            centroids: (0..<k).map { Array(centroids[($0 * points.dimension)..<(($0 + 1) * points.dimension)]) },
            inertia: final.distances.reduce(0, +),
            iterations: iterations,
            converged: converged,
            silhouette: silhouette(points, assignments: final.assignments, k: k)
        )
    }

    /// Что дал подбор числа тем.
    public struct Selection: Sendable {
        public let k: Int
        /// Силуэт при выбранном числе тем и при делении надвое и натрое.
        public let scores: [Score]
        /// Крупное деление выигрывает у выбранного **заметно**.
        ///
        /// Обычно это значит, что в коллекции лежат две разные по природе вещи
        /// — например, содержательные документы и служебные обрывки. Умолчать
        /// об этом нельзя, но и принимать за ответ тоже: «две темы» не
        /// описывает содержимое.
        public let coarseSplitDominates: Bool

        public struct Score: Sendable, Hashable {
            public let k: Int
            public let silhouette: Double
        }

        public var line: String {
            scores.map { "\($0.k):\(String(format: "%.3f", $0.silhouette))" }.joined(separator: " ")
        }
    }

    /// Сколько тем брать, если человек не задал своё число.
    ///
    /// **Это соглашение, а не находка.** Первая редакция выбирала k по лучшему
    /// силуэту среди лесенки значений — и на настоящих коллекциях это не
    /// работает: у текстовых эмбеддингов нет «естественного» числа тем.
    /// Измерено живьём на 9 771 документе википедийной выгрузки: по одной
    /// подвыборке мера росла до самого края лесенки (k=24), по другой — падала
    /// и оставляла победителем k=2. Одно и то же собрание, две подвыборки,
    /// противоположные ответы. Величина, которая так себя ведёт, не может
    /// ничего выбирать; силуэт остаётся тем, для чего он годится, — описанием
    /// уже готового разбиения.
    ///
    /// Корень из числа документов, делённый на три, в границах от четырёх до
    /// двадцати четырёх: десять тысяч документов дают 24 темы, тысяча — 10,
    /// три сотни — 6. Меньше четырёх тем — не ответ на вопрос «что
    /// накопилось», больше двадцати четырёх — уже не список, который читают.
    public static func defaultK(for count: Int) -> Int {
        let raw = Int((Double(count).squareRoot() / 3).rounded())
        return max(4, min(24, max(2, raw)))
    }

    /// Число тем по умолчанию плюс проверка, не делится ли коллекция надвое
    /// сильнее, чем на выбранное число.
    ///
    /// Проверяются ровно три значения — 2, 3 и выбранное, — а не вся лесенка:
    /// каждое стоит секунды, и считать десяток ради числа, которое ничего не
    /// решает, незачем. Подвыборка — потому что от двух тысяч векторов эта
    /// картина уже не зависит.
    public static func suggestK(
        _ points: VectorSet, seed: UInt64, limit: Int = 2000,
        shouldStop: () -> Bool = { false }
    ) -> Selection {
        let chosen = defaultK(for: points.count)
        let sample = points.strided(to: limit).set
        let candidates = [2, 3, chosen].filter { $0 >= 2 && $0 <= sample.count }
        guard !candidates.isEmpty else {
            return Selection(k: max(1, min(chosen, points.count)), scores: [], coarseSplitDominates: false)
        }

        var scores: [Selection.Score] = []
        for candidate in Array(Set(candidates)).sorted() {
            if shouldStop() { break }
            let fit = fit(sample, k: candidate, seed: seed, maxIterations: 30, shouldStop: shouldStop)
            scores.append(Selection.Score(k: candidate, silhouette: fit.silhouette))
        }

        // «Заметно» — это в четверть лучше, а не на третьем знаке.
        let decisiveMargin = 1.25
        let mine = scores.first { $0.k == chosen }?.silhouette ?? 0
        let coarse = scores.filter { $0.k < 4 && $0.k != chosen }.map(\.silhouette).max() ?? 0
        return Selection(
            k: chosen,
            scores: scores,
            coarseSplitDominates: mine > 0 && coarse > mine * decisiveMargin
        )
    }

    // MARK: - Шаги

    /// k-means++: первый центр случайно, каждый следующий — с вероятностью,
    /// пропорциональной квадрату расстояния до уже выбранных. Со случайного
    /// старта k-means регулярно сходится к разбиению, где два центра стоят в
    /// одном плотном месте, а половина коллекции остаётся без своего.
    static func seeds(_ points: VectorSet, k: Int, seed: UInt64) -> [Double] {
        var random = SeededRandom(seed: seed)
        let dimension = points.dimension
        var centroids: [Double] = []
        centroids.reserveCapacity(k * dimension)

        let first = random.index(below: points.count)
        centroids.append(contentsOf: points.values[(first * dimension)..<((first + 1) * dimension)])

        var best = [Double](repeating: Double.greatestFiniteMagnitude, count: points.count)
        for chosen in 1..<max(k, 1) {
            let centre = Array(centroids[((chosen - 1) * dimension)..<(chosen * dimension)])
            var total = 0.0
            points.values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for index in 0..<points.count {
                    var similarity = 0.0
                    vDSP_dotprD(base + index * dimension, 1, centre, 1, &similarity, vDSP_Length(dimension))
                    let distance = max(0, 1 - similarity)
                    if distance < best[index] { best[index] = distance }
                    total += best[index] * best[index]
                }
            }
            guard total > 0 else {
                // Все точки уже совпали с выбранными центрами: раздавать
                // оставшиеся места наугад честнее, чем делать вид, что
                // расстояния есть.
                let index = random.index(below: points.count)
                centroids.append(contentsOf: points.values[(index * dimension)..<((index + 1) * dimension)])
                continue
            }
            var target = random.fraction() * total
            var picked = points.count - 1
            for index in 0..<points.count {
                target -= best[index] * best[index]
                if target <= 0 { picked = index; break }
            }
            centroids.append(contentsOf: points.values[(picked * dimension)..<((picked + 1) * dimension)])
        }
        return centroids
    }

    /// Раздача номеров: для каждой точки — ближайший центр и следующий за ним.
    /// Второй нужен силуэту, и считать его отдельным проходом было бы вдвое
    /// дороже на ровном месте.
    static func assign(
        _ points: VectorSet, centroids: [Double], k: Int
    ) -> (assignments: [Int], distances: [Double], second: [Double]) {
        let dimension = points.dimension
        var assignments = [Int](repeating: 0, count: points.count)
        var distances = [Double](repeating: 0, count: points.count)
        var second = [Double](repeating: 1, count: points.count)

        points.values.withUnsafeBufferPointer { buffer in
            centroids.withUnsafeBufferPointer { centres in
                guard let base = buffer.baseAddress, let centreBase = centres.baseAddress else { return }
                for index in 0..<points.count {
                    let point = base + index * dimension
                    var bestDistance = Double.greatestFiniteMagnitude
                    var runnerUp = Double.greatestFiniteMagnitude
                    var bestCluster = 0
                    for cluster in 0..<k {
                        var similarity = 0.0
                        vDSP_dotprD(point, 1, centreBase + cluster * dimension, 1, &similarity, vDSP_Length(dimension))
                        let distance = max(0, 1 - similarity)
                        if distance < bestDistance {
                            runnerUp = bestDistance
                            bestDistance = distance
                            bestCluster = cluster
                        } else if distance < runnerUp {
                            runnerUp = distance
                        }
                    }
                    assignments[index] = bestCluster
                    distances[index] = bestDistance
                    second[index] = runnerUp.isFinite ? runnerUp : bestDistance
                }
            }
        }
        return (assignments, distances, second)
    }

    /// Новые центры — среднее своих точек, приведённое к единичной длине.
    ///
    /// Опустевший кластер получает самую далёкую от своего центра точку: без
    /// этого k уменьшается молча, и отчёт обещает восемь тем, показывая шесть.
    static func recomputed(
        _ points: VectorSet, assignments: [Int], distances: [Double], k: Int
    ) -> [Double] {
        let dimension = points.dimension
        var sums = [Double](repeating: 0, count: k * dimension)
        var counts = [Int](repeating: 0, count: k)

        points.values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            sums.withUnsafeMutableBufferPointer { target in
                guard let targetBase = target.baseAddress else { return }
                for index in 0..<points.count {
                    let cluster = assignments[index]
                    counts[cluster] += 1
                    vDSP_vaddD(
                        targetBase + cluster * dimension, 1,
                        base + index * dimension, 1,
                        targetBase + cluster * dimension, 1,
                        vDSP_Length(dimension)
                    )
                }
            }
        }

        var orphans = zip(distances.indices, distances).sorted { $0.1 > $1.1 }.map(\.0)
        for cluster in 0..<k where counts[cluster] == 0 {
            guard let donor = orphans.first else { break }
            orphans.removeFirst()
            for offset in 0..<dimension {
                sums[cluster * dimension + offset] = points.values[donor * dimension + offset]
            }
            counts[cluster] = 1
        }

        for cluster in 0..<k {
            let range = (cluster * dimension)..<((cluster + 1) * dimension)
            var vector = Array(sums[range])
            var squares = 0.0
            vDSP_svesqD(vector, 1, &squares, vDSP_Length(dimension))
            let length = squares.squareRoot()
            guard length > 0, length.isFinite else { continue }
            var scale = 1 / length
            var unit = [Double](repeating: 0, count: dimension)
            vDSP_vsmulD(vector, 1, &scale, &unit, 1, vDSP_Length(dimension))
            vector = unit
            sums.replaceSubrange(range, with: vector)
        }
        return sums
    }

    /// Силуэт по подвыборке точек: среднее расстояние до своих против среднего
    /// до ближайшей чужой темы.
    ///
    /// **Настоящий силуэт, а не упрощённый по расстояниям до центров.** Первая
    /// редакция считала упрощённый — он дешевле, но у него встроенный перекос:
    /// каждый добавленный центр уменьшает расстояние до своего сильнее, чем до
    /// чужого, поэтому мера растёт с числом тем просто оттого, что тем больше.
    /// Мерить качество разбиения величиной, которая улучшается от самого факта
    /// дробления, нельзя.
    ///
    /// Подвыборка ровным шагом: настоящий силуэт — это все пары расстояний, а
    /// на шестистах точках картина та же и считается за доли секунды.
    static func silhouette(
        _ points: VectorSet, assignments: [Int], k: Int, limit: Int = silhouetteSampleLimit
    ) -> Double {
        guard points.count > 1, k > 1 else { return 0 }
        let step = max(1, points.count / max(1, limit))
        var sampled: [Int] = []
        var index = 0
        while index < points.count {
            sampled.append(index)
            index += step
        }
        guard sampled.count > 1 else { return 0 }

        let dimension = points.dimension
        var total = 0.0
        var counted = 0
        points.values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var sums = [Double](repeating: 0, count: k)
            var counts = [Int](repeating: 0, count: k)
            for own in sampled {
                for cluster in 0..<k { sums[cluster] = 0; counts[cluster] = 0 }
                for other in sampled where other != own {
                    var similarity = 0.0
                    vDSP_dotprD(
                        base + own * dimension, 1, base + other * dimension, 1,
                        &similarity, vDSP_Length(dimension)
                    )
                    let cluster = assignments[other]
                    sums[cluster] += max(0, 1 - similarity)
                    counts[cluster] += 1
                }
                let mine = assignments[own]
                // Единственный представитель своей темы в подвыборке: сравнить
                // не с чем, и приписывать ему ноль было бы враньём в обе
                // стороны.
                guard counts[mine] > 0 else { continue }
                let inside = sums[mine] / Double(counts[mine])
                var outside = Double.greatestFiniteMagnitude
                for cluster in 0..<k where cluster != mine && counts[cluster] > 0 {
                    outside = min(outside, sums[cluster] / Double(counts[cluster]))
                }
                guard outside.isFinite, max(inside, outside) > 0 else { continue }
                total += (outside - inside) / max(inside, outside)
                counted += 1
            }
        }
        return counted > 0 ? total / Double(counted) : 0
    }
}
