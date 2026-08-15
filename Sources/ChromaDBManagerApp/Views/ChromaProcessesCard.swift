import SwiftUI
import ChromaCore

/// Процессы chroma, оставшиеся от прошлых запусков.
///
/// **Живёт на «Обзоре», а не в установке.** Такой процесс держит порт и базу,
/// и увидеть его надо в первую секунду после запуска приложения — на экране,
/// который человек и так открывает. На вкладке «Установка» карточка попадалась
/// на глаза тому, кто и без неё пришёл разбираться с движком, а остальным —
/// никогда: до неё надо было додуматься.
///
/// Своим файлом, а не куском экрана: карточка отвечает на один вопрос —
/// «чужие процессы нашего сервера», — и её должно быть можно поставить куда
/// угодно, не таща за собой пол-экрана окружения.
struct ChromaProcessesCard: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var processManager: ChromaProcessManager
    /// Чужие процессы chroma усыновляет и останавливает та же модель, что и
    /// раньше: переехали карточки, а не логика.
    @ObservedObject var serverModel: ServerViewModel

    var body: some View {
        // Пусто — карточки нет вовсе: постоянный «процессов не найдено»
        // на первом экране это строка, которую перестают читать.
        if !processManager.orphans.isEmpty { orphansCard }
        if !processManager.unverified.isEmpty { unverifiedCard }
    }

    private var orphansCard: some View {
        SectionCard(
            title: String(localized: "Найден процесс от прошлой сессии"),
            subtitle: String(localized: "Приложение сохраняет PID запущенных им серверов и проверяет их при старте.")
        ) {
            ForEach(processManager.orphans) { record in
                HStack {
                    process(record)
                    Spacer()
                    Button(String(localized: "Остановить")) {
                        Task { await serverModel.stopOrphan(record, app: app) }
                    }
                    .buttonStyle(.chromaNormal)
                }
                .padding(.vertical, 2)
            }
            Text(String(localized: "Если этот процесс обслуживает вашу локальную базу, приложение просто подключится к нему при следующем подключении."))
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
        }
    }

    /// Processes that are alive and look like ours but could not be confirmed.
    ///
    /// Shown rather than quietly dropped: forgetting them is exactly how four
    /// servers once ended up running for days, holding the database, with the
    /// app unaware they existed. The app will not signal what it cannot
    /// identify — but it will say that something is there.
    private var unverifiedCard: some View {
        SectionCard(
            title: String(localized: "Процесс, который не удалось опознать"),
            subtitle: String(localized: "Он жив и похож на наш сервер, но одну из проверок подтвердить не вышло. Приложение не отправляет сигналы тому, в чём не уверено, — и не забывает про такие процессы.")
        ) {
            ForEach(processManager.unverified) { record in
                process(record)
                    .padding(.vertical, 2)
            }
            Text(String(localized: "Причина — в логе, раздел «Сервер». Часто это временно: проверьте ещё раз кнопкой обновления. Если процесс лишний, его можно снять вручную по PID."))
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
        }
    }

    /// Чем процесс назван человеку: PID и адрес, путь к базе, время запуска.
    private func process(_ record: RunningServerRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PID \(record.pid) · \(record.host):\(record.port)").font(Theme.Font.body)
            Text(record.path).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .lineLimit(1).truncationMode(.middle)
            Text(String(localized: "запущен \(record.startedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
        }
    }
}
