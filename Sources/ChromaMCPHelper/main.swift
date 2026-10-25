import Foundation
import ChromaCore

// Вспомогательный исполняемый файл MCP-сервера (этап 7).
//
// Агентское приложение запускает его как подпроцесс и говорит с ним по
// стандартным потокам; он передаёт сообщения приложению через сокет Unix.
// Своей логики у него нет вовсе — ни инструментов, ни прав, ни доступа
// к базе. Это сознательно: два места, где решается, что агенту можно,
// разошлись бы, и одно из них оказалось бы дырой.
//
// Железное правило stdio по спецификации: в `stdout` не попадает ничего,
// кроме сообщений протокола. Всё остальное — в `stderr`, и клиент не обязан
// считать это признаком ошибки.

/// Запись в стандартный вывод под замком: ответы приходят из очереди сокета,
/// а ошибки формируются в потоке чтения, и вперемешку они дали бы рваные строки.
final class StandardOutput: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ message: Data) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(LineFraming.frame(message))
    }

    func write(_ message: JSONRPCOutgoing) {
        guard let encoded = try? message.encoded() else { return }
        write(encoded)
    }
}

func log(_ text: String) {
    FileHandle.standardError.write(Data("[chromadb-mcp] \(text)\n".utf8))
}

let output = StandardOutput()
let queue = DispatchQueue(label: "chromadb.mcp.helper")

/// Сколько запросов ушло в приложение и ещё не получили ответа.
///
/// Нужен ровно для одного: не оборвать себя раньше, чем ответ доедет.
/// Ответы приходят из очереди сокета, а конец файла на `stdin` — из потока
/// чтения; без счёта эти два события идут наперегонки, и выигрывает обычно
/// второе. Живой случай: агент прислал `initialize` устаревшего образца,
/// приложение ответило «обновите клиент» — и ответ не дошёл, потому что
/// процесс успел выйти. Человек увидел «стандартный ввод закрыт» и ни слова
/// о причине.
final class PendingReplies: @unchecked Sendable {
    private let lock = NSCondition()
    /// Чьи запросы ещё ждут ответа. Раньше считались только штуки —
    /// этого хватало, чтобы не выйти раньше времени, но не хватало, чтобы
    /// ответить за приложение, когда связь с ним оборвалась посреди вызова.
    ///
    /// Отдельного счётчика нет: он расходился со списком. Ответ на запрос,
    /// за который мы уже ответили сами, уменьшал счёт **чужого** ожидания,
    /// и выход переставал ждать ответа, который ещё в пути.
    private var awaiting: [JSONRPCID] = []

    func sent(_ id: JSONRPCID) {
        lock.lock()
        awaiting.append(id)
        lock.unlock()
    }

    /// Ответ узнаётся по `id` **и** по отсутствию метода.
    ///
    /// Разбирать ответ как `JSONRPCIncoming` нельзя: у того `method`
    /// обязателен, а у ответа его нет вовсе — разбор проваливался всегда,
    /// и ни один идентификатор не снимался с ожидания. Отсюда шли обе беды:
    /// выход всегда ждал полные две секунды, а на закрытии приложения агент
    /// получал по второму — ошибочному — ответу на каждый уже отвеченный
    /// запрос.
    func received(_ data: Data) {
        guard let id = JSONRPCReply.answeredID(in: data) else { return }
        answered(id)
    }

    /// Ожидание этого запроса закрыто — ответило приложение или мы за него.
    ///
    /// Без этого отказ «приложение не запущено» отвечал агенту, а запрос
    /// оставался в списке ждущих: следующий обрыв связи отвечал на него
    /// **второй раз**, и выход ждал две секунды ответа, которого не будет
    ///.
    func answered(_ id: JSONRPCID) {
        lock.lock()
        if let index = awaiting.firstIndex(of: id) { awaiting.remove(at: index) }
        lock.broadcast()
        lock.unlock()
    }

    /// Забирает всех, кто ещё ждёт: им придётся ответить самим.
    func drainAwaiting() -> [JSONRPCID] {
        lock.lock()
        defer { lock.unlock() }
        let taken = awaiting
        awaiting.removeAll()
        lock.broadcast()
        return taken
    }

    /// Ждёт ответов не дольше отведённого срока: клиент мог и уйти, а висеть
    /// вечно вспомогательный процесс не имеет права.
    func waitForQuiet(upTo seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        lock.lock()
        while !awaiting.isEmpty, Date() < deadline {
            lock.wait(until: deadline)
        }
        lock.unlock()
    }
}

let pending = PendingReplies()

/// Связь с приложением. Поднимается лениво — при первом сообщении, а не при
/// запуске: клиент может держать сервер запущенным часами, и приложение,
/// открытое посреди этого времени, должно заработать без перезапуска агента.
final class AppLink: @unchecked Sendable {
    private var channel: MCPChannel?
    private let lock = NSLock()
    /// Версия, которую агент назвал в `initialize`. Повторяется приложению
    /// при каждом подключении: перезапущенное приложение иначе её не знает,
    /// а второй `initialize` агент не пришлёт.
    private var negotiatedVersion: String?

    func remember(version: String?) {
        lock.lock()
        negotiatedVersion = version
        lock.unlock()
    }

    /// Отправляет сообщение приложению. Возвращает `false`, если связи нет.
    func send(_ message: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if channel == nil { channel = openChannel() }
        guard let channel else { return false }
        // Неудачная отправка — тоже повод ответить агенту. Канал
        // считается живым, пока о его смерти не сообщили, и сообщение,
        // ушедшее в уже закрытое соединение, раньше пропадало без следа.
        channel.send(message) { error in
            log("сообщение не ушло: \(error.localizedDescription)")
            answerForTheApp()
        }
        return true
    }

    private func openChannel() -> MCPChannel? {
        do {
            let channel = try MCPConnector.connect(queue: queue)
            channel.onMessage = { data in
                pending.received(data)
                output.write(data)
            }
            channel.onClose = { [weak self] error in
                if let error { log("связь с приложением разорвана: \(error)") }
                // Следующее сообщение поднимет связь заново: приложение могли
                // просто перезапустить, и это не повод считать сервер мёртвым.
                self?.lock.lock()
                self?.channel = nil
                self?.lock.unlock()
                // Но тем, кто ждёт ответа **сейчас**, приложение уже
                // не ответит: их запросы ушли в закрывшийся канал.
                // Без этого агент ждал своего таймаута, а человек видел
                // «модель зависла» вместо «приложение закрыли».
                answerForTheApp()
            }
            // `connect` уже поднял и дождался связи: файл сокета остаётся
            // на диске после закрытия приложения, и «файл есть» не значит
            // «есть кому отвечать».
            // Представляемся ключом клиента. У stdio нет заголовков, а права
            // проверяются по ключу — значит, он обязан как-то доехать.
            // Отдельным уведомлением при подключении, а не добавкой в каждое
            // сообщение: так сообщения агента доезжают до приложения байт
            // в байт, и мост по-прежнему ничего в них не меняет.
            if let key = ProcessInfo.processInfo.environment["CHROMADB_MCP_KEY"], !key.isEmpty {
                var params: [String: JSONValue] = ["key": .string(key)]
                if let negotiatedVersion { params["protocolVersion"] = .string(negotiatedVersion) }
                if let hello = try? JSONRPCOutgoing.notification(
                    method: MCPProtocol.helloNotification,
                    params: .object(params)
                ).encoded() {
                    channel.send(hello)
                }
            } else {
                log("переменная CHROMADB_MCP_KEY не задана — приложение ответит отказом по правам")
            }
            return channel
        } catch {
            log("\(error.localizedDescription)")
            return nil
        }
    }
}

let link = AppLink()

/// Отвечает за приложение всем, чьи запросы остались без ответа.
///
/// Ошибкой выполнения, а не молчанием: агент обязан узнать, что вызов
/// не состоялся, — иначе он ждёт таймаута, а человек читает это как
/// «зависла модель».
func answerForTheApp() {
    let waiting = pending.drainAwaiting()
    guard !waiting.isEmpty else { return }
    log("связь оборвалась, отвечаем за приложение: запросов \(waiting.count)")
    for id in waiting {
        output.write(.failure(id: id, JSONRPCError(
            code: JSONRPCError.internalError,
            message: MCPConnector.ConnectError.appNotRunning.localizedDescription
        )))
    }
}

/// Отказ, когда приложение не запущено.
///
/// По D2.2 это обязано быть внятной ошибкой, а не молчанием: агент, не
/// получивший ответа, зависает, и человек видит не причину, а таймаут.
/// На уведомление ответить нечем — по JSON-RPC у него нет идентификатора,
/// и отвечать на него запрещено.
func refuse(_ incoming: JSONRPCIncoming?, message: Data) {
    let error = JSONRPCError(
        code: JSONRPCError.internalError,
        message: MCPConnector.ConnectError.appNotRunning.localizedDescription
    )
    guard let incoming else {
        // Не разобралось — тот же ответ, что дало бы приложение: не JSON —
        // ошибка разбора, JSON, но не запрос, — неверный запрос.
        output.write(.unidentifiedFailure(MCPServer.unreadable(message)))
        return
    }
    guard let id = incoming.id else { return }
    output.write(.failure(id: id, error))
    pending.answered(id)
}

/// Передаёт сообщение агента приложению — или отвечает за него отказом.
///
/// Разбираем ровно настолько, чтобы знать идентификатор: он нужен, если
/// ответить придётся нам самим. Содержимое — дело приложения.
func forward(_ message: Data) {
    let incoming = try? JSONDecoder().decode(JSONRPCIncoming.self, from: message)
    if let id = incoming?.id { pending.sent(id) }
    if incoming?.method == MCPProtocol.initializeMethod {
        link.remember(version: incoming?.params?["protocolVersion"]?.stringValue)
    }
    // Отменённый запрос ответа больше не ждёт: сервер не вправе слать по нему
    // ничего (`2026-07-28`, «Cancellation»). Без этого мост, потеряв связь
    // с приложением, ответил бы за него отказом — на то, что агент отменил.
    if incoming?.method == MCPProtocol.cancelledNotification,
       let requestID = incoming?.params?["requestId"],
       let id = try? JSONDecoder().decode(JSONRPCID.self, from: JSONEncoder().encode(requestID)) {
        pending.answered(id)
    }
    if !link.send(message) { refuse(incoming, message: message) }
}

// Чтение стандартного ввода блокирующим циклом.
//
// Конец файла на `stdin` — по спецификации основной и единственный переносимый
// сигнал завершения, и сервер обязан выйти сразу же. Поэтому цикл здесь,
// в главном потоке: закончился ввод — закончился процесс.
var framer = LineFramer()
let input = FileHandle.standardInput

while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }   // конец файла

    let messages: [Data]
    do {
        messages = try framer.consume(chunk)
    } catch {
        log("строка длиннее допустимого — соединение прекращено: \(error)")
        output.write(.unidentifiedFailure(JSONRPCError(
            code: JSONRPCError.invalidRequest,
            message: "The message exceeds the maximum line length"
        )))
        break
    }

    for message in messages { forward(message) }
}

// Хвост без перевода строки идёт тем же путём, что и сообщения из цикла:
// без учёта хвоста процесс выходил сразу и терял ответ на него — тот самый
// случай, ради которого ожидание и заводилось.
if let tail = framer.flush() { forward(tail) }

// Конец ввода — сигнал завершения, но не повод проглотить ответ, который
// уже в пути. Две секунды: столько идёт разговор через сокет с приложением,
// открытым на этой же машине, а клиент, который закрыл ввод и ушёл, ничего
// не теряет от такой задержки.
pending.waitForQuiet(upTo: 2)
log("стандартный ввод закрыт — завершение")
