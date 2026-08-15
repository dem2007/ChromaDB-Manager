import SwiftUI
import AppKit
import ChromaCore

/// Spec: the state of everything that decides who can reach the database,
/// the switch that opens it to the network, and the emergency stop.
struct SecurityView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var processManager: ChromaProcessManager
    @EnvironmentObject private var proxy: ProxyServer
    @EnvironmentObject private var audit: AuditLog
    // Injected rather than reached through `app`: a nested ObservableObject
    // does not redraw a view that only observes its owner.
    @EnvironmentObject private var notifier: Notifier
    @ObservedObject var model: SecurityViewModel
    /// Прокси запускает и останавливает та же модель, что и раньше: переехала
    /// карточка, а не логика.
    @ObservedObject var serverModel: ServerViewModel

    private var assessment: SecurityAssessment { app.securityAssessment }

    /// Разрез экрана: «Сводка», «Доступ по сети», «Уведомления».
    var tab: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    MessageBanner(kind: .success, text: status) { model.statusMessage = nil }
                }

                switch tab {
                case 1:
                    // Прокси — здесь, и только здесь. Он и есть «что открыто
                    // наружу»; на «Сервере» жила вторая его половина, и
                    // настройки расходились между двумя экранами.
                    exposureCard
                    encryptionCard
                    proxyCard
                case 2:
                    notificationsCard
                default:
                    if !assessment.warnings.isEmpty { warningsCard }
                    summaryCard
                    emergencyCard
                }

                howItWorks
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
        // Сертификат и адреса машины читаются здесь — один раз на открытие
        // экрана, а не на каждое обращение к оценке.
        .task { app.refreshSecuritySnapshot() }
    }

    /// Экстренная остановка — карточкой, а не кнопкой в шапке.
    ///
    /// Она стояла в правом верхнем углу рядом с заголовком: красная кнопка,
    /// одна на весь экран, без единого слова о том, что произойдёт. Теперь
    /// последствие написано рядом с ней — и это ровно тот случай, когда текст
    /// не прячется под «?».
    private var emergencyCard: some View {
        SectionCard(
            title: String(localized: "Экстренная остановка"),
            subtitle: String(localized: "Прокси и сервер ChromaDB останавливаются, все выданные ключи перестают действовать сразу и навсегда.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                Text("Права и лимиты клиентов сохранятся — понадобится только выпустить новые ключи. Документы и коллекции не трогаются.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Остановить и отозвать ключи")) {
                        model.isConfirmingStop = true
                    }
                    .buttonStyle(.chromaDanger)
                    .disabled(model.isBusy)
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .confirmationDialog(
                    String(localized: "Остановить всё и отозвать ключи?"),
                    isPresented: $model.isConfirmingStop,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Остановить и отозвать"), role: .destructive) {
                        Task { await model.emergencyStop(app) }
                    }
                    Button(String(localized: "Отмена"), role: .cancel) {}
                } message: {
                    Text(String(localized: "Прокси и сервер ChromaDB будут остановлены, все выданные ключи перестанут действовать сразу и навсегда. Права и лимиты клиентов сохранятся — понадобится только выпустить новые ключи."))
                }
            }
        }
    }

    private var howItWorks: some View {
        HowItWorks(screen: "security") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Данные к базе идут только через прокси: сам ChromaDB наружу не выставляется и всегда остаётся на 127.0.0.1. Ключи, права и лимиты действуют на прокси и на MCP — это два транспорта поверх одних и тех же ключей.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Любая программа, запущенная под вашей учётной записью, может обратиться к ChromaDB напрямую на 127.0.0.1 — в обход ключей и лимитов: собственной аутентификации у этой версии движка нет.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        SectionCard(
            title: String(localized: "Сводка"),
            subtitle: String(localized: "Данные к базе идут только через прокси: сам ChromaDB наружу не выставляется.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    title: String(localized: "Сервер ChromaDB"),
                    state: processManager.isRunning ? (assessment.serverIsExposed ? .missing : .ok) : .unknown,
                    value: serverDescription
                )
                statusRow(
                    title: String(localized: "Прокси"),
                    state: proxy.state.isRunning ? (settings.configuration.proxyExposure.isExposed ? .warning : .ok) : .unknown,
                    value: proxy.state.title
                )
                statusRow(
                    title: String(localized: "Ключи"),
                    state: assessment.activeClients.isEmpty ? .unknown : .ok,
                    value: keysDescription
                )
                statusRow(
                    title: String(localized: "Журнал доступа"),
                    state: rejectedToday > 0 ? .warning : .ok,
                    value: String(localized: "за сегодня записей: \(recordedToday.plainDigits), из них отказов: \(rejectedToday.plainDigits)")
                )
            }
        }
    }

    private var serverDescription: String {
        guard processManager.isRunning else { return String(localized: "не запущен") }
        let host = assessment.serverHost ?? "?"
        let port = assessment.serverPort?.plainDigits ?? "?"
        return "\(host):\(port)"
    }

    private var keysDescription: String {
        let active = assessment.activeClients.count
        let write = assessment.writeClients.count
        if active == 0 {
            return assessment.clients.isEmpty
                ? String(localized: "клиентов нет")
                : String(localized: "действующих нет, всего клиентов: \(assessment.clients.count.plainDigits)")
        }
        return String(localized: "действующих: \(active.plainDigits), с правом записи: \(write.plainDigits)")
    }

    private var todayEntries: [AuditEntry] {
        let midnight = Calendar.current.startOfDay(for: Date())
        return audit.entries.filter { $0.date >= midnight }
    }

    private var recordedToday: Int { todayEntries.count }

    private var rejectedToday: Int {
        todayEntries.filter { ($0.responseStatus ?? 200) >= 400 }.count
    }

    private func statusRow(title: String, state: CheckState, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(state: state)
            Text(title)
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .frame(width: 130, alignment: .leading)
            Text(value).font(Theme.Font.body).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Warnings

    private var warningsCard: some View {
        SectionCard(title: String(localized: "На что стоит посмотреть")) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(assessment.warnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        // Точка, а не иконка-эмоция: состояние здесь несёт
                        // цвет, а восклицательный знак только кричит.
                        Circle()
                            .fill(color(for: warning.severity))
                            .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.text).font(Theme.Font.body)
                            if let suggestion = warning.suggestion {
                                Text(suggestion).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            }
                        }
                    }
                }
            }
        }
    }

    private func color(for severity: SecurityWarning.Severity) -> Color {
        switch severity {
        case .info: return Theme.Palette.stopped
        case .caution: return Theme.Palette.attention
        case .critical: return Theme.Palette.danger
        }
    }

    // MARK: - Шифрование

    /// Сертификат: отпечаток, срок, имена, перевыпуск и экспорт.
    ///
    /// Отпечаток стоит первым и целиком, а не «первые восемь знаков»: он и есть
    /// то, чем клиент проверяет, что говорит с нами. Прятать его под кнопку
    /// значит заставлять человека сверять по памяти.
    private var encryptionCard: some View {
        SectionCard(
            title: String(localized: "Шифрование"),
            subtitle: String(localized: "Ключ клиента передаётся заголовком. Без шифрования его видит любой, кто слушает сеть между клиентом и этим Маком.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Шифровать трафик прокси (TLS)"), isOn: Binding(
                    get: { settings.configuration.proxyUsesTLS },
                    set: { model.setTLS($0, app: app) }
                ))

                if !settings.configuration.proxyUsesTLS {
                    Text(settings.configuration.proxyExposure.isExposed
                        ? String(localized: "Прокси открыт наружу и не шифрует: ключи уходят в сеть открытым текстом.")
                        : String(localized: "Прокси слушает только этот Мак — такой трафик не покидает машину."))
                        .font(Theme.Font.caption)
                        .foregroundStyle(settings.configuration.proxyExposure.isExposed
                            ? Theme.Palette.danger
                            : Theme.Palette.captionText)
                }

                if settings.configuration.proxyUsesTLS {
                    if let certificate = assessment.certificate {
                        certificateDetails(certificate)
                    } else {
                        // Кнопка нужна до запуска, а не после: отпечаток
                        // отдают клиенту заранее, вместе с ключом. Без неё
                        // единственный способ увидеть сертификат — запустить
                        // прокси, то есть открыть порт, чтобы посмотреть бумагу.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Сертификат выпустится сам при первом запуске прокси."))
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            Button(String(localized: "Выпустить сейчас")) { model.reissueCertificate(app) }
                                .help(String(localized: "Чтобы отдать клиенту отпечаток и файл заранее, не запуская прокси"))
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Как подключается клиент")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    HStack(alignment: .top, spacing: 6) {
                        Text(model.connectionExample(app: app))
                            .font(Theme.Font.mono)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            model.copy(model.connectionExample(app: app))
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Скопировать пример"))
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Выпустить сертификат заново?"),
                isPresented: $model.isConfirmingReissue,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Выпустить"), role: .destructive) { model.reissueCertificate(app) }
                Button(String(localized: "Отмена"), role: .cancel) {}
            } message: {
                Text(String(localized: "Отпечаток изменится. Все, кто уже доверился прежнему сертификату, получат ошибку соединения, пока не получат новый отпечаток или новый файл сертификата.\n\nДелать это стоит, когда сертификат подходит к концу срока или когда у Мака сменился адрес в сети."))
            }
        }
    }

    @ViewBuilder
    private func certificateDetails(_ certificate: TLSCertificateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Отпечаток SHA-256")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                HStack(alignment: .top, spacing: 6) {
                    Text(certificate.fingerprint)
                        .font(Theme.Font.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.copy(certificate.fingerprint)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Скопировать отпечаток"))
                }
                Text(String(localized: "Клиент видит ровно этот отпечаток. Совпал — соединение то самое."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }

            proxyRow(String(localized: "Действует до"), certificate.notAfter.formatted(date: .abbreviated, time: .shortened))
            proxyRow(String(localized: "Осталось"), certificate.isExpired()
                ? String(localized: "истёк")
                : String(localized: "\(certificate.daysRemaining().plainDigits) дн."))
            proxyRow(String(localized: "Выписан на"), certificate.hosts.joined(separator: ", "))

            HStack(spacing: 8) {
                Button(String(localized: "Сохранить сертификат…")) { model.exportCertificate(app) }
                Button(String(localized: "Выпустить заново")) { model.isConfirmingReissue = true }
            }
        }
    }

    // MARK: - Exposure

    private var exposureCard: some View {
        SectionCard(
            title: String(localized: "Доступ по сети"),
            subtitle: String(localized: "Наружу открывается только прокси — он проверяет ключ, коллекции и лимиты. Сам сервер ChromaDB всегда остаётся на 127.0.0.1.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { settings.configuration.proxyExposure },
                    set: { model.requestExposure($0, app: app) }
                )) {
                    ForEach(NetworkExposure.allCases) { exposure in
                        Text(exposure.title).tag(exposure)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(settings.configuration.proxyExposure.subtitle)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)

                if settings.configuration.proxyExposure.isExposed {
                    let addresses = model.externalAddresses(port: settings.configuration.proxyPort)
                    if addresses.isEmpty {
                        Text(String(localized: "Сетевых адресов у этого Мака сейчас нет — подключаться будет неоткуда."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Клиенты подключаются на:")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            ForEach(addresses, id: \.self) { address in
                                HStack(spacing: 6) {
                                    Text(address)
                                        .font(Theme.Font.mono)
                                        .textSelection(.enabled)
                                    Button {
                                        model.copy(address)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(String(localized: "Скопировать адрес"))
                                }
                            }
                        }
                    }
                    Text(String(localized: "При первом открытии порта наружу macOS может спросить, разрешать ли входящие соединения — без разрешения снаружи никто не подключится."))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)

                    // The app cannot see the firewall's answer, so it says what
                    // it does know: the port is open and nothing has arrived.
                    if app.securityAssessment.warnings.contains(where: { $0.id == "no-external-traffic" }) {
                        HStack(spacing: 8) {
                            Label(
                                String(localized: "Порт открыт, но запросов извне не было."),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                            Button(String(localized: "Настройки брандмауэра…")) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(Theme.Font.caption)
                            Spacer()
                        }
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Открыть прокси в локальную сеть?"),
                isPresented: $model.isConfirmingExposure,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Открыть наружу"), role: .destructive) {
                    model.confirmExposure(app)
                }
                Button(String(localized: "Отмена"), role: .cancel) {}
            } message: {
                // Said before the system dialog appears, not after: an
                // unexplained macOS prompt is exactly what C5 is about.
                Text(String(localized: "К порту прокси сможет обратиться любое устройство в сети. Пустить внутрь он сможет только того, у кого есть действующий ключ, но сам порт станет виден.\n\nСразу после открытия macOS спросит, разрешать ли входящие соединения приложению — это нормально и ожидаемо. Если отказать, порт будет открыт, но запросы снаружи доходить не будут.\n\nКлючи выдаются на экране «Клиенты», а «Экстренная остановка» закрывает всё разом."))
            }
        }
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        SectionCard(
            title: String(localized: "Уведомления"),
            subtitle: String(localized: "Сообщать через Центр уведомлений: сервер упал, кому-то отказано в доступе, выполнена экстренная остановка, — и итоги фоновых операций.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Показывать уведомления"), isOn: Binding(
                    get: { settings.configuration.notificationsEnabled },
                    set: { isOn in Task { await model.setNotifications(isOn, app: app) } }
                ))
                .disabled(!isNotificationSupported)

                switch notifier.availability {
                case .unsupported(let reason):
                    Text(String(localized: "Уведомления недоступны: \(reason). В собранном приложении (Scripts/build-app.sh) они работают."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                case .denied:
                    Text(String(localized: "macOS отклонил запрос. Включить можно в «Системных настройках» → «Уведомления»."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                case .ready, .unknown:
                    Text(String(localized: "Разрешение запрашивается один раз — в момент включения переключателя."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }

                Divider().padding(.vertical, 2)

                // a separate setting, because the two kinds of notification
                // answer different questions. The events above are «something
                // is wrong right now»; this is «the work you walked away from
                // is done».
                Text(String(localized: "Итоги фоновых операций"))
                    .font(Theme.Font.cardTitle)
                Text(String(localized: "Одно уведомление по итогу синхронизации, пересчёта или импорта — со сводкой, а не по файлу на каждый."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(String(localized: "Уведомлять"), selection: Binding(
                    get: { settings.configuration.operationNotifications },
                    set: { settings.configuration.operationNotifications = $0 }
                )) {
                    ForEach(OperationNotificationPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .disabled(!settings.configuration.notificationsEnabled)

                Text(settings.configuration.operationNotifications.explanation)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)

                if !settings.configuration.notificationsEnabled {
                    Text(String(localized: "Пока переключатель выше выключен, итоги никуда не отправляются независимо от этой настройки."))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var isNotificationSupported: Bool {
        if case .unsupported = notifier.availability { return false }
        return true
    }
    // MARK: - Прокси (переехал с «Сервера»)

    /// Spec At this stage the proxy forwards everything and only writes
    /// the audit log — rules and keys come next, and there is no point putting
    /// them in front of traffic that has not been shown to survive the trip.
    private var proxyCard: some View {
        SectionCard(
            title: String(localized: "Прокси"),
            subtitle: String(localized: "Слой, через который к базе будут ходить внешние клиенты.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusDot(state: proxy.state.isRunning ? .ok : .unknown)
                    Text(proxy.state.title).font(Theme.Font.body)
                    Spacer()
                    if proxy.state.isRunning {
                        Button(String(localized: "Остановить прокси")) { serverModel.stopProxy(app) }
                    } else {
                        Button(String(localized: "Запустить прокси")) { serverModel.startProxy(app) }
                            .disabled(app.endpoint == nil)
                    }
                }

                if proxy.state.isRunning {
                    proxyRow(String(localized: "Пересылает в"), proxy.upstreamDescription ?? "—")
                    proxyRow(String(localized: "Доступен"), proxy.exposure.title)
                    proxyRow(String(localized: "Трафик"), proxy.tls == .tls
                        ? String(localized: "шифруется (TLS)")
                        : String(localized: "без шифрования"))
                    proxyRow(String(localized: "Соединений"), proxy.activeConnections.plainDigits)
                    proxyRow(String(localized: "Запросов"), proxy.totalRequests.plainDigits)
                    proxyRow(String(localized: "Отказов"), proxy.rejectedRequests.plainDigits)
                    Text(proxy.tls == .tls
                        ? String(localized: "Клиент подключается так: chromadb.HttpClient(host=\"127.0.0.1\", port=\(settings.configuration.proxyPort.plainDigits), ssl=True)")
                        : String(localized: "Клиент подключается так: chromadb.HttpClient(host=\"127.0.0.1\", port=\(settings.configuration.proxyPort.plainDigits))"))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.captionText)
                        .textSelection(.enabled)
                } else {
                    HStack {
                        Text(String(localized: "Порт")).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        TextField("", value: $settings.configuration.proxyPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    if app.endpoint == nil {
                        Text(String(localized: "Проксировать пока нечего: сначала подключитесь к базе."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                Text(String(localized: "Прокси проверяет ключ, коллекции и лимиты и пишет каждый запрос в журнал доступа. Кому что разрешено — на экране «Клиенты»; открыть порт в локальную сеть — ниже, в «Доступе по сети»."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
    }


    /// Строка «поле — значение» внутри карточки прокси.
    private func proxyRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
                .frame(width: 130, alignment: .leading)
            Text(value).font(Theme.Font.control).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
