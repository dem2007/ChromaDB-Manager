import SwiftUI
import ChromaCore

/// Процессы chroma, оставшиеся от прошлых запусков —
/// секциями формы «Обзора».
///
/// **Живёт на «Обзоре», а не в установке.** Такой процесс держит порт и базу,
/// и увидеть его надо в первую секунду после запуска приложения — на экране,
/// который человек и так открывает.
///
/// Своим файлом, а не куском экрана: секции отвечают на один вопрос —
/// «чужие процессы нашего сервера», — и их можно поставить в любую форму.
struct ChromaProcessesCard: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var processManager: ChromaProcessManager
    /// Чужие процессы chroma усыновляет и останавливает та же модель, что и
    /// раньше: переехали секции, а не логика.
    @ObservedObject var serverModel: ServerViewModel
    @State private var stopping: RunningServerRecord?

    var body: some View {
        // Пусто — секции нет вовсе: постоянный «процессов не найдено»
        // на первом экране — строка, которую перестают читать.
        if !processManager.orphans.isEmpty { orphansSection }
        if !processManager.unverified.isEmpty { unverifiedSection }
    }

    private var orphansSection: some View {
        Section {
            ForEach(processManager.orphans) { record in
                LabeledContent {
                    Button(String(localized: "Остановить…"), role: .destructive) { stopping = record }
                        // У кнопки своей строки, а не у секции: диалог на
                        // секции формы не открывается.
                        .confirmationDialog(
                            String(localized: "Остановить процесс \(record.pid)?"),
                            isPresented: Binding(
                                get: { stopping?.id == record.id },
                                set: { if !$0 { stopping = nil } }
                            )
                        ) {
                            Button(String(localized: "Остановить"), role: .destructive) {
                                Task { await serverModel.stopOrphan(record, app: app) }
                            }
                            Button(String(localized: "Отменить"), role: .cancel) {}
                        } message: {
                            Text("Процесс сервера на порту \(record.port.plainDigits) будет остановлен. Данные базы не трогаются.")
                        }
                } label: {
                    process(record)
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Найден процесс от прошлой сессии"),
                help: String(localized: "Приложение сохраняет PID запущенных им серверов и проверяет их при старте.")
            )
        } footer: {
            Text("Если он обслуживает вашу локальную базу, приложение подключится к нему при следующем подключении.")
        }
    }

    /// Живые и похожие на наш сервер, но не подтверждённые процессы.
    ///
    /// Показываются, а не отбрасываются молча: так однажды четыре сервера
    /// работали сутками, держа базу, а приложение о них не знало.
    /// Сигнал тому, что не опознано, приложение не шлёт — но говорит, что оно есть.
    private var unverifiedSection: some View {
        Section {
            ForEach(processManager.unverified) { record in
                process(record)
            }
        } header: {
            SectionHeader(
                String(localized: "Процесс, который не удалось опознать"),
                help: String(localized: "Он жив и похож на наш сервер, но одну из проверок подтвердить не вышло. Приложение не отправляет сигналы тому, в чём не уверено, — и не забывает про такие процессы.")
            )
        } footer: {
            Text("Причина — в логе, раздел «Сервер». Если процесс лишний, его можно снять вручную по PID.")
        }
    }

    /// Чем процесс назван человеку: PID и адрес, путь к базе, время запуска.
    private func process(_ record: RunningServerRecord) -> some View {
        VStack(alignment: .leading) {
            Text("PID \(record.pid) · \(record.host):\(record.port)")
            Text(record.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(record.path)
            Text(String(localized: "запущен \(record.startedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
