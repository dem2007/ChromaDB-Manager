import Foundation
import CoreGraphics
import PDFKit

/// Линии и картинки страницы PDF — из её содержимого, а не из текста
///.
///
/// PDFKit отдаёт текст и рамки знаков, но не рисунок страницы. Рамка таблицы
/// живёт в потоке содержимого: отрезками (`m`/`l` и обводка) или тонкими
/// закрашенными прямоугольниками — так рамку ячейки пишет Word. Поток
/// разбирается системным `CGPDFScanner`, со всеми преобразованиями
/// координат (`cm`, `q`/`Q`) и вложенными формами (`Do`): рамка, нарисованная
/// внутри формы со своей матрицей, иначе встала бы не туда.
///
/// Заодно — картинки: страница, где текста почти нет, а картинка закрывает
/// её почти всю, — скан внутри документа с текстовым слоем.
final class PDFRulings {
    private(set) var rulings = TableLattice.Rulings()
    /// Доля площади страницы под картинками.
    private(set) var imageCoverage = 0.0
    /// Во сколько раз самая крупная картинка страницы детальнее самой
    /// страницы: точек картинки на пункт. Скан 300 dpi на листе A4 —
    /// около 4,2; распознавание рисует страницу вдвое и теряет половину.
    private(set) var imageDetail: Double?
    private var largestImage = 0.0

    /// Тоньше этого — линия, а не закрашенная область.
    static let thickness = 2.5
    /// Короче этого — штрих, а не линия рамки: подчёркивание буквы, точка.
    static let minimumLength = 3.0
    /// Глубже этого формы не разбираются: форма внутри формы внутри формы —
    /// уже не вёрстка, а возможная петля.
    static let maximumDepth = 4

    private var matrix = CGAffineTransform.identity
    private var saved: [CGAffineTransform] = []
    private var subpaths: [[CGPoint]] = []
    private var closed: [Bool] = []
    private var clipping = false
    private var pageArea = 1.0
    private var depth = 0

    /// Линии и картинки страницы.
    static func scan(_ page: PDFPage) -> PDFRulings {
        let result = PDFRulings()
        guard let reference = page.pageRef else { return result }
        let box = page.bounds(for: .mediaBox)
        result.pageArea = max(1, Double(box.width * box.height))
        // Поток и сканер — не объекты Swift, а указатели: их освобождают
        // руками. Без этого каждая разобранная страница оставляла в
        // памяти свой поток со всеми распакованными данными — синхронизация
        // папки с PDF дошла до 1,5 ГБ, из них 894 МБ — данные потоков.
        let stream = CGPDFContentStreamCreateWithPage(reference)
        defer { CGPDFContentStreamRelease(stream) }
        result.run(stream)
        return result
    }

    private func run(_ stream: CGPDFContentStreamRef) {
        let table = Self.operators
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
    }

    // MARK: - Путь

    private func move(_ point: CGPoint) {
        subpaths.append([point.applying(matrix)])
        closed.append(false)
    }

    private func line(_ point: CGPoint) {
        guard !subpaths.isEmpty else { move(point); return }
        subpaths[subpaths.count - 1].append(point.applying(matrix))
    }

    private func close() {
        guard !closed.isEmpty else { return }
        closed[closed.count - 1] = true
    }

    private func rectangle(_ rect: CGRect) {
        move(CGPoint(x: rect.minX, y: rect.minY))
        line(CGPoint(x: rect.maxX, y: rect.minY))
        line(CGPoint(x: rect.maxX, y: rect.maxY))
        line(CGPoint(x: rect.minX, y: rect.maxY))
        close()
    }

    private func discard() {
        subpaths = []
        closed = []
        clipping = false
    }

    /// Обводка: каждая сторона пути — отрезок, если она горизонтальна
    /// или вертикальна.
    private func stroke() {
        guard !clipping else { discard(); return }
        for (index, points) in subpaths.enumerated() {
            var edges = Array(zip(points, points.dropFirst()))
            if closed[index], let first = points.first, let last = points.last, first != last {
                edges.append((last, first))
            }
            for (a, b) in edges { add(from: a, to: b) }
        }
        discard()
    }

    /// Заливка: узкий прямоугольник — линия по его оси. Широкий — фон
    /// ячейки; его края линиями не считаются: заливка рисуется и без рамки.
    private func fill() {
        guard !clipping else { discard(); return }
        for points in subpaths where points.count >= 4 {
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            // Только прямоугольник по осям: иначе это фигура, а не линия.
            let axisAligned = points.allSatisfy { point in
                (abs(point.x - minX) < 0.5 || abs(point.x - maxX) < 0.5)
                    && (abs(point.y - minY) < 0.5 || abs(point.y - maxY) < 0.5)
            }
            guard axisAligned else { continue }
            let width = Double(maxX - minX), height = Double(maxY - minY)
            if height <= Self.thickness, width >= Self.minimumLength {
                rulings.horizontal.append(.init(position: Double(minY + maxY) / 2, from: Double(minX), to: Double(maxX)))
            } else if width <= Self.thickness, height >= Self.minimumLength {
                rulings.vertical.append(.init(position: Double(minX + maxX) / 2, from: Double(minY), to: Double(maxY)))
            }
        }
        discard()
    }

    private func add(from a: CGPoint, to b: CGPoint) {
        let dx = Double(abs(a.x - b.x)), dy = Double(abs(a.y - b.y))
        if dy < 0.8, dx >= Self.minimumLength {
            rulings.horizontal.append(.init(position: Double(a.y + b.y) / 2,
                                            from: Double(min(a.x, b.x)), to: Double(max(a.x, b.x))))
        } else if dx < 0.8, dy >= Self.minimumLength {
            rulings.vertical.append(.init(position: Double(a.x + b.x) / 2,
                                          from: Double(min(a.y, b.y)), to: Double(max(a.y, b.y))))
        }
    }

    // MARK: - Картинки и формы

    private func xObject(named name: String, in stream: CGPDFContentStreamRef) {
        guard let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
        var reference: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &reference), let reference,
              let dictionary = CGPDFStreamGetDictionary(reference) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image":
            // Картинка рисуется в единичный квадрат, растянутый матрицей.
            let box = CGRect(x: 0, y: 0, width: 1, height: 1).applying(matrix)
            let area = Double(abs(box.width * box.height))
            imageCoverage += area / pageArea
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            if area > largestImage,
               CGPDFDictionaryGetInteger(dictionary, "Width", &width),
               CGPDFDictionaryGetInteger(dictionary, "Height", &height) {
                largestImage = area
                let side = Double(max(abs(box.width), abs(box.height)))
                imageDetail = side > 0 ? Double(max(width, height)) / side : nil
            }
        case "Form":
            guard depth < Self.maximumDepth else { return }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            // Форма без своих ресурсов пользуется ресурсами страницы; поиск
            // по словарю самой формы тогда просто ничего не найдёт.
            let form = CGPDFContentStreamCreateWithStream(reference, resources ?? dictionary, stream)
            let outer = matrix
            let outerSaved = saved
            matrix = Self.formMatrix(dictionary).concatenating(matrix)
            defer { CGPDFContentStreamRelease(form) }
            depth += 1
            run(form)
            depth -= 1
            matrix = outer
            saved = outerSaved
        default:
            break
        }
    }

    private static func formMatrix(_ dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6
        else { return .identity }
        var values = [CGFloat](repeating: 0, count: 6)
        for index in 0..<6 {
            var value: CGPDFReal = 0
            _ = CGPDFArrayGetNumber(array, index, &value)
            values[index] = value
        }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    // MARK: - Таблица операторов

    private static func this(_ info: UnsafeMutableRawPointer?) -> PDFRulings? {
        info.map { Unmanaged<PDFRulings>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[index] = value
        }
        return values
    }

    private static let operators: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let this = this(info) else { return }
            this.saved.append(this.matrix)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let this = this(info) else { return }
            this.matrix = this.saved.popLast() ?? this.matrix
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 6) else { return }
            let change = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            this.matrix = change.concatenating(this.matrix)
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 4) else { return }
            this.rectangle(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 2) else { return }
            this.move(CGPoint(x: v[0], y: v[1]))
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 2) else { return }
            this.line(CGPoint(x: v[0], y: v[1]))
        }
        // Кривые: конец кривой — новая точка пути, сама кривая линией рамки
        // не бывает. Разрыв, а не продолжение: иначе хорда кривой стала бы
        // «отрезком».
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 6) else { return }
            this.move(CGPoint(x: v[4], y: v[5]))
        }
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 4) else { return }
            this.move(CGPoint(x: v[2], y: v[3]))
        }
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
            guard let this = this(info), let v = numbers(scanner, 4) else { return }
            this.move(CGPoint(x: v[2], y: v[3]))
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in this(info)?.close() }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in this(info)?.stroke() }
        CGPDFOperatorTableSetCallback(table, "s") { _, info in
            this(info)?.close()
            this(info)?.stroke()
        }
        for name in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in this(info)?.fill() }
        }
        for name in ["B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in
                guard let this = this(info) else { return }
                // Заливка и обводка разом: путь нужен обеим.
                let paths = this.subpaths, flags = this.closed, clip = this.clipping
                this.fill()
                this.subpaths = paths
                this.closed = flags
                this.clipping = clip
                this.stroke()
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in this(info)?.discard() }
        CGPDFOperatorTableSetCallback(table, "W") { _, info in this(info)?.clipping = true }
        CGPDFOperatorTableSetCallback(table, "W*") { _, info in this(info)?.clipping = true }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let this = this(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            this.xObject(named: String(cString: name), in: CGPDFScannerGetContentStream(scanner))
        }
        return table
    }()
}
