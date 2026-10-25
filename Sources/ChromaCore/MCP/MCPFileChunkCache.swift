import Foundation

/// Упорядоченный список кусков файла — один раз на файл, а не на каждый вызов.
///
/// **Зачем.** Порядок кусков ChromaDB не хранит, а `get_file` его обещает:
/// чтобы отдать страницу, приложение перечисляет из базы метаданные **всех**
/// кусков файла и сортирует их. Делается это на каждом вызове и во всех
/// режимах — и у карты, и у раздела, и у сплошного текста, и у обычного
/// листания: `orderedByChunkIndex` стоит у каждого.
///
/// **Сколько это стоит.** Замер на живой базе, ТЗ на 1281 кусок:
/// одна страница — 0,207 с, из них 0,194 с обход и 0,014 с сам текст. Чтение
/// документа целиком — 96 страниц, 19,8 с, из них **18,7 с (94 %)** на то,
/// чтобы девяносто шесть раз подряд перечислить одни и те же 1281 метаданных.
/// Записей обойдено 122 976 ради 1,9 МБ текста. И цена квадратична: страниц
/// столько же порядка, сколько кусков.
///
/// **Что здесь лежит.** Ровно результат обхода: упорядоченные метаданные без
/// текстов и признак «файл длиннее предела упорядочивания». Тексты страницы
/// и так берутся отдельным запросом по идентификаторам — им кэш не нужен.
///
/// **Когда запись перестаёт годиться.** Проверок четыре, и каждая ловит своё:
/// - поколение коллекции меняется на любой записи через `ChromaClient` —
///   добавлении, правке, удалении, в том числе оборванных на середине;
/// - `invalidateAll()` — на чужую запись, прошедшую через прокси, и на смену
///   клиента базы;
/// - счёт документов коллекции ловит запись мимо приложения вовсе, если она
///   меняет число документов;
/// - срок жизни — то, что не поймало ничто из перечисленного: запись мимо
///   приложения, не меняющая счёта.
///
/// Снимок поколения берётся **до** обхода (`ticket`), а не при сохранении:
/// иначе запись, случившаяся посреди обхода, терялась бы, и обход, сделанный
/// до неё, запоминался бы как свежий.
public final class MCPFileChunkCache: @unchecked Sendable {
    /// Какой файл какой коллекции. Отбор входит в ключ целиком: один и тот же
    /// файл, спрошенный отпечатком и путём, — это два разных отбора, и
    /// подменять один другим нельзя.
    ///
    /// Отбор — по `identityKey`, то есть по тому, что уйдёт на сервер, а не
    /// самим `DocumentFilter`: у каждого условия свой `UUID`, и фильтр,
    /// собранный на каждом вызове заново, был бы всякий раз новым ключом —
    /// кэш не находил бы ничего никогда.
    public struct Key: Hashable, Sendable {
        public let collectionID: String
        public let filterIdentity: String

        public init(collectionID: String, filter: DocumentFilter?) {
            self.collectionID = collectionID
            self.filterIdentity = filter?.identityKey ?? ""
        }
    }

    /// Результат обхода — то, ради чего кэш и заведён.
    public struct Entry: Sendable {
        public let documents: [MCPDocumentPayload]
        public let overflowed: Bool

        public init(documents: [MCPDocumentPayload], overflowed: Bool) {
            self.documents = documents
            self.overflowed = overflowed
        }
    }

    /// Сколько файлов держим разом.
    ///
    /// Четыре, а не сколько влезет: метаданные ТЗ на 1281 кусок весят около
    /// полутора мегабайт, и держать их десятками — это платить памятью за то,
    /// чего никто не спросит. Агент читает один документ за раз, изредка два.
    public static let capacity = 4

    /// Сколько кусков держим разом по всем файлам.
    ///
    /// Четыре файла — это и четыре таблицы по двадцать тысяч строк, у каждой
    /// строки все её колонки в метаданных: десятки мегабайт ради того, что
    /// агент, может быть, дочитает. Последний запомненный файл остаётся
    /// всегда, даже если он один больше предела.
    public static let maximumDocuments = 20_000

    /// Через сколько запись считается протухшей.
    ///
    /// Минута — это про то, чего приложение не видит: запись в ту же базу
    /// мимо него. Всё, что идёт через него, снимается точнее и сразу —
    /// по поколению коллекции.
    ///
    /// Отсчитывается по `systemUptime`, а не по часам: перевод часов назад
    /// продлил бы жизнь записи на столько же.
    public static let lifetime: TimeInterval = 60

    /// Снимок поколения, взятый до обхода.
    ///
    /// Обход, начатый до записи и законченный после, сохраняться не должен:
    /// он видел базу до записи. Поэтому `store` сверяет снимок с тем, что
    /// есть сейчас, и при расхождении не запоминает ничего.
    public struct Ticket: Equatable, Sendable {
        fileprivate let epoch: Int
        fileprivate let generation: Int
    }

    private struct Stored {
        let entry: Entry
        let ticket: Ticket
        /// Сколько документов было в коллекции, когда обход делался.
        ///
        /// Проверка против самой базы, а не против того, кого мы успели
        /// заметить: записать в ChromaDB можно и мимо приложения — через
        /// прокси или чужим клиентом, — и такой записи не увидит ни один
        /// наш обработчик. Счёт стоит один дешёвый запрос против двух
        /// полных обходов.
        let stamp: Int
        let storedAt: TimeInterval
    }

    private let lock = NSLock()
    private var storage: [Key: Stored] = [:]
    /// Ключи в порядке последнего обращения: последний — самый свежий.
    private var order: [Key] = []
    private var generations: [String: Int] = [:]
    /// Поколение всего кэша: растёт на `invalidateAll`.
    private var epoch = 0

    public init() {}

    /// Снимок поколения для этого файла — взять **до** обхода.
    public func ticket(for key: Key) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        return currentTicket(for: key)
    }

    private func currentTicket(for key: Key) -> Ticket {
        Ticket(epoch: epoch, generation: generations[key.collectionID, default: 0])
    }

    /// Что лежит для этого файла — или `nil`, если обходить придётся заново.
    /// - Parameter stamp: сколько документов в коллекции **сейчас**.
    public func entry(for key: Key, stamp: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = storage[key] else { return nil }
        guard stored.ticket == currentTicket(for: key),
              stored.stamp == stamp,
              now - stored.storedAt < Self.lifetime
        else {
            storage[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        // Обращение освежает место в очереди: вытесняем то, чем не пользуются.
        order.removeAll { $0 == key }
        order.append(key)
        return stored.entry
    }

    /// Запомнить обход. Пустой файл не запоминается: его «нет» — это ответ
    /// базы, а не устройство файла, и держать такой ответ минуту незачем.
    /// - Parameter ticket: снимок, взятый до обхода; `nil` — «сейчас».
    ///   Коллекция изменилась с тех пор — обход не запоминается.
    public func store(
        _ entry: Entry, for key: Key, stamp: Int, ticket: Ticket? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !entry.documents.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let current = currentTicket(for: key)
        guard ticket.map({ $0 == current }) ?? true else { return }
        storage[key] = Stored(
            entry: entry,
            ticket: current,
            stamp: stamp,
            storedAt: now
        )
        order.removeAll { $0 == key }
        order.append(key)
        // Протухшие уходят сразу, а не когда их спросят: иначе минута жизни
        // на деле — до следующего вытеснения.
        for stale in order where stale != key {
            if let stored = storage[stale], now - stored.storedAt > Self.lifetime { storage[stale] = nil }
        }
        order.removeAll { storage[$0] == nil }
        var held = order.reduce(0) { $0 + (storage[$1]?.entry.documents.count ?? 0) }
        while order.count > 1, order.count > Self.capacity || held > Self.maximumDocuments {
            let evicted = order.removeFirst()
            held -= storage[evicted]?.entry.documents.count ?? 0
            storage[evicted] = nil
        }
    }

    /// Коллекция изменилась — всё, что помнили про её файлы, больше не годится.
    ///
    /// Поколением, а не вычёркиванием ключей: файл мог и не попасть в кэш,
    /// а изменение коллекции всё равно обязано его обесценить.
    public func invalidate(collectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        generations[collectionID, default: 0] += 1
    }

    /// Всё, что помнили, больше не годится.
    ///
    /// Коллекция в чужой записи названа так, как её назвал зовущий, — именем
    /// или идентификатором, — и сопоставить это с ключами кэша нельзя. Значит
    /// снимается всё: запись — событие редкое, а неверный порядок кусков
    /// дороже потерянного обхода. Поколение всего кэша растёт, чтобы обход,
    /// идущий прямо сейчас, не вернул снятое обратно.
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        epoch += 1
        storage.removeAll()
        order.removeAll()
    }

    /// Сколько файлов помнится — для проверок и диагностики.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
