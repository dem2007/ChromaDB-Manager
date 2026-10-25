import SwiftUI
import AppKit
import ChromaCore

/// Spec: the state of everything that decides who can reach the database,
/// the switch that opens it to the network, and the emergency stop.
///
/// Тип А — формы. «Сводка»: что стоит посмотреть, состояние, экстренная
/// остановка последней секцией. «Доступ по сети»: прокси, порт наружу,
/// шифрование — здесь и только здесь. Уведомления — в окне «Настройки».
struct SecurityView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var processManager: ChromaProcessManager
    @EnvironmentObject private var proxy: ProxyServer
    @EnvironmentObject private var audit: AuditLog
    @ObservedObject var model: SecurityViewModel
    /// Прокси запускает и останавливает та же модель, что и раньше: переехала
    /// карточка, а не логика.
    @ObservedObject var serverModel: ServerViewModel

    private var assessment: SecurityAssessment { app.securityAssessment }

    /// Разрез экрана: «Сводка», «Доступ по сети».
    var tab: Int = 0
    /// Перейти на соседнюю вкладку — к прокси со сводки.
    var openTab: (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            messages
            switch tab {
            case 1:
                networkForm
            default:
                summaryForm
            }
        }
        // Сертификат и адреса машины читаются здесь — один раз на открытие
        // экрана, а не на каждое обращение к оценке.
        .task { app.refreshSecuritySnapshot() }
    }

    @ViewBuilder
    private var messages: some View {
        if model.errorMessage != nil || model.statusMessage != nil {
            VStack(alignment: .leading) {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let status = model.statusMessage {
                    HStack {
                        Notice(.info, status)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.statusMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    // MARK: - Сводка

    /// Значок важности пункта «На что стоит посмотреть».
    @ViewBuilder
    private func severityIcon(_ state: StatusLabel.State) -> some View {
        switch state {
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .off:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }

    /// «Подключиться могут только программы на этом Маке (127.0.0.1).»
    private var exposureFootnote: String {
        let exposure = settings.configuration.proxyExposure
        var sentence = exposure.subtitle
        if sentence.hasSuffix(".") { sentence.removeLast() }
        return "\(sentence) (\(exposure.bindHost))."
    }

    private var summaryForm: some View {
        Form {
            // «На что стоит посмотреть» — первой секцией.
            Section {
                if assessment.warnings.isEmpty {
                    StatusLabel(.ok, String(localized: "Всё в порядке"))
                } else {
                    // `Label` со значком важности (v4): вторая строка встаёт под
                    // текстом, а не под точкой; значок говорит, насколько это
                    // важно, — серые точки не говорили ничего.
                    ForEach(assessment.warnings) { warning in
                        Label {
                            VStack(alignment: .leading) {
                                Text(warning.text)
                                if let suggestion = warning.suggestion {
                                    Text(suggestion)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            // Обход ключей локальными программами — настоящий
                            // риск, хотя ядро и называет его сведением (оно
                            // показывается всегда): значок — предупреждение.
                            severityIcon(warning.id == "local-access" ? .warning : state(for: warning.severity))
                        }
                    }
                }
            } header: {
                Text("На что стоит посмотреть")
            }

            Section {
                LabeledContent(String(localized: "Сервер ChromaDB")) {
                    StatusLabel(
                        processManager.isRunning ? (assessment.serverIsExposed ? .error : .ok) : .off,
                        serverDescription
                    )
                }
                // Прокси управляется на «Доступе по сети» — здесь его строка
                // со ссылкой туда.
                LabeledContent {
                    StatusLabel(
                        proxy.state.isRunning ? (settings.configuration.proxyExposure.isExposed ? .warning : .ok) : .off,
                        proxy.state.title
                    )
                    // Ссылкой, как «Источники» на «Обзоре» (v5): переход на
                    // вкладку, а не диалог — без многоточия. Своими словами, а
                    // не «Открыть», — чтобы не читалось со статусом одной фразой.
                    Button(String(localized: "Доступ по сети")) { openTab(1) }
                        .buttonStyle(.link)
                } label: {
                    Text("Прокси")
                }
                LabeledContent(String(localized: "Ключи")) {
                    StatusLabel(assessment.activeClients.isEmpty ? .off : .ok, keysDescription)
                }
                LabeledContent(String(localized: "Журнал доступа")) {
                    StatusLabel(
                        rejectedToday > 0 ? .warning : .ok,
                        String(localized: "за сегодня записей: \(recordedToday.plainDigits), из них отказов: \(rejectedToday.plainDigits)")
                    )
                }
            } header: {
                SectionHeader(
                    String(localized: "Сводка"),
                    help: String(localized: "Данные к базе идут только через прокси: сам ChromaDB наружу не выставляется и всегда остаётся на 127.0.0.1. Ключи, права и лимиты действуют на прокси и на MCP — это два транспорта поверх одних и тех же ключей.")
                )
            }

            // Экстренная остановка — последней секцией, с последствием
            // словами рядом: это тот случай, когда текст не
            // прячется под «?».
            Section {
                // Строка с подписью, а не голая кнопка справа (v4 A7).
                LabeledContent(String(localized: "Остановить прокси и сервер, отозвать все ключи")) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    // Тревожная кнопка — красная: её ищут в спешке.
                    Button(String(localized: "Остановить…"), role: .destructive) {
                        model.isConfirmingStop = true
                    }
                    .destructiveButtonStyle()
                    .disabled(model.isBusy)
                    .confirmationDialog(
                        String(localized: "Остановить всё и отозвать ключи?"),
                        isPresented: $model.isConfirmingStop,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Остановить и отозвать"), role: .destructive) {
                            Task { await model.emergencyStop(app) }
                        }
                        Button(String(localized: "Отменить"), role: .cancel) {}
                    } message: {
                        Text(String(localized: "Прокси и сервер ChromaDB будут остановлены, все выданные ключи перестанут действовать сразу и навсегда. Права и лимиты клиентов сохранятся — понадобится только выпустить новые ключи."))
                    }
                }
            } header: {
                SectionHeader(
                    String(localized: "Экстренная остановка"),
                    help: String(localized: "Прокси и сервер ChromaDB останавливаются, все выданные ключи перестают действовать сразу и навсегда. Права и лимиты клиентов сохранятся — понадобится только выпустить новые ключи. Документы и коллекции не трогаются.")
                )
            } footer: {
                // Необратимость — всегда в footer, одним
                // предложением; подробности — под «?».
                Text("Ключи перестанут действовать навсегда; документы и коллекции не трогаются.")
            }

            Section {
                HowItWorks(screen: "security", String(localized: "Данные к базе идут только через прокси: сам ChromaDB наружу не выставляется и всегда остаётся на 127.0.0.1. Любая программа, запущенная под вашей учётной записью, может обратиться к ChromaDB напрямую на 127.0.0.1 — в обход ключей и лимитов: собственной аутентификации у этой версии движка нет."))
            }
        }
        .formStyle(.grouped)
    }

    private func state(for severity: SecurityWarning.Severity) -> StatusLabel.State {
        switch severity {
        case .info: return .off
        case .caution: return .warning
        case .critical: return .error
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

    // MARK: - Доступ по сети

    private var networkForm: some View {
        Form {
            proxySection
            exposureSection
            encryptionSection
        }
        .formStyle(.grouped)
    }

    /// Прокси — здесь, и только здесь.
    private var proxySection: some View {
        Section {
            LabeledContent {
                if proxy.state.isRunning {
                    Button(String(localized: "Остановить прокси")) { serverModel.stopProxy(app) }
                } else {
                    Button(String(localized: "Запустить прокси")) { serverModel.startProxy(app) }
                        .disabled(app.endpoint == nil)
                }
            } label: {
                StatusLabel(proxy.state.isRunning ? .ok : .off, proxy.state.title)
            }
            if proxy.state.isRunning {
                LabeledContent(String(localized: "Пересылает в"), value: proxy.upstreamDescription ?? "—")
                LabeledContent(String(localized: "Доступен"), value: proxy.exposure.title)
                // Режим **работающего** прокси, а не настройка: настройку
                // могли поменять, а прокси ещё не перезапускали.
                LabeledContent(String(localized: "Трафик"), value: proxy.tls == .tls
                    ? String(localized: "шифруется (TLS)")
                    : String(localized: "без шифрования"))
                LabeledContent(String(localized: "Соединений"), value: proxy.activeConnections.plainDigits)
                LabeledContent(String(localized: "Запросов"), value: proxy.totalRequests.plainDigits)
                LabeledContent(String(localized: "Отказов"), value: proxy.rejectedRequests.plainDigits)
            } else {
                TextField(String(localized: "Порт"), value: $settings.configuration.proxyPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Прокси")
        } footer: {
            VStack(alignment: .leading) {
                if !proxy.state.isRunning, app.endpoint == nil {
                    Notice(.info, String(localized: "Проксировать пока нечего: сначала подключитесь к базе."))
                }
                // Одна мысль — в одном месте: что проверяет прокси,
                // сказано здесь, и больше нигде.
                Text("Прокси проверяет ключ, коллекции и лимиты и пишет каждый запрос в журнал доступа. Кому что разрешено — на экране «Клиенты».")
            }
        }
    }

    private var exposureSection: some View {
        Section {
            // Каждый вариант — своей строкой (v4): `.radioGroup` без подписи
            // прямо в секции; подписью служит заголовок «Доступ по сети».
            // С подписью строки группа ложилась в ряд и сжималась вправо.
            Picker(String(localized: "Доступ"), selection: Binding(
                get: { settings.configuration.proxyExposure },
                set: { model.requestExposure($0, app: app) }
            )) {
                Text("Только этот Mac").tag(NetworkExposure.loopback)
                Text("Локальная сеть").tag(NetworkExposure.allInterfaces)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .confirmationDialog(
                String(localized: "Открыть прокси в локальную сеть?"),
                isPresented: $model.isConfirmingExposure,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Открыть наружу"), role: .destructive) {
                    model.confirmExposure(app)
                }
                Button(String(localized: "Отменить"), role: .cancel) {}
            } message: {
                // Said before the system dialog appears, not after: an
                // unexplained macOS prompt is exactly what C5 is about.
                Text(String(localized: "К порту прокси сможет обратиться любое устройство в сети. Пустить внутрь он сможет только того, у кого есть действующий ключ, но сам порт станет виден.\n\nСразу после открытия macOS спросит, разрешать ли входящие соединения приложению — это нормально и ожидаемо. Если отказать, порт будет открыт, но запросы снаружи доходить не будут.\n\nКлючи выдаются на экране «Клиенты», а «Экстренная остановка» закрывает всё разом."))
            }

            if settings.configuration.proxyExposure.isExposed {
                let addresses = model.externalAddresses(port: settings.configuration.proxyPort)
                if addresses.isEmpty {
                    Notice(.warning, String(localized: "Сетевых адресов у этого Mac сейчас нет — подключаться будет неоткуда."))
                } else {
                    ForEach(addresses, id: \.self) { address in
                        LabeledContent(String(localized: "Клиенты подключаются на")) {
                            Text(address)
                                .font(.body.monospaced())
                                .copyable(address)
                        }
                        .contextMenu {
                            Button(String(localized: "Скопировать адрес")) { model.copy(address) }
                        }
                    }
                }
                // The app cannot see the firewall's answer, so it says what it
                // does know: the port is open and nothing has arrived.
                if app.securityAssessment.warnings.contains(where: { $0.id == "no-external-traffic" }) {
                    LabeledContent {
                        Button(String(localized: "Настройки брандмауэра…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } label: {
                        Notice(.warning, String(localized: "Порт открыт, но запросов извне не было."))
                    }
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Доступ по сети"),
                help: String(localized: "Наружу открывается только прокси. Сам сервер ChromaDB всегда остаётся на 127.0.0.1. При первом открытии порта наружу macOS может спросить, разрешать ли входящие соединения — без разрешения снаружи никто не подключится.")
            )
        } footer: {
            // Выход в сеть — всегда в footer.
            Text(verbatim: exposureFootnote)
        }
    }

    // MARK: - Шифрование

    /// Сертификат: отпечаток, срок, имена, перевыпуск и экспорт.
    ///
    /// Отпечаток — целиком, а не «первые восемь знаков»: он и есть то, чем
    /// клиент проверяет, что говорит с нами.
    private var encryptionSection: some View {
        Section {
            Toggle(String(localized: "Шифровать трафик прокси (TLS)"), isOn: Binding(
                get: { settings.configuration.proxyUsesTLS },
                set: { model.setTLS($0, app: app) }
            ))
            .confirmationDialog(
                String(localized: "Выпустить сертификат заново?"),
                isPresented: $model.isConfirmingReissue,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Выпустить"), role: .destructive) { model.reissueCertificate(app) }
                Button(String(localized: "Отменить"), role: .cancel) {}
            } message: {
                Text(String(localized: "Отпечаток изменится. Все, кто уже доверился прежнему сертификату, получат ошибку соединения, пока не получат новый отпечаток или новый файл сертификата.\n\nДелать это стоит, когда сертификат подходит к концу срока или когда у Мака сменился адрес в сети."))
            }
            if settings.configuration.proxyUsesTLS {
                if let certificate = assessment.certificate {
                    certificateRows(certificate)
                } else {
                    // Кнопка нужна до запуска: отпечаток отдают клиенту заранее,
                    // вместе с ключом.
                    LabeledContent {
                        Button(String(localized: "Выпустить сейчас")) { model.reissueCertificate(app) }
                            .help(String(localized: "Чтобы отдать клиенту отпечаток и файл заранее, не запуская прокси"))
                    } label: {
                        Text("Сертификат выпустится сам при первом запуске прокси.")
                    }
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Шифрование"),
                help: String(localized: "Ключ клиента передаётся заголовком. Без шифрования его видит любой, кто слушает сеть между клиентом и этим Mac. Клиент видит ровно тот отпечаток, что показан здесь: совпал — соединение то самое.")
            )
        } footer: {
            if !settings.configuration.proxyUsesTLS {
                if settings.configuration.proxyExposure.isExposed {
                    Notice(.warning, String(localized: "Прокси открыт наружу и не шифрует: ключи уходят в сеть открытым текстом."))
                } else {
                    // О текущем режиме (v4): шифрование выключено, и почему это
                    // не страшно.
                    Text("Шифрование выключено: прокси слушает только этот Mac, трафик не покидает машину.")
                }
            }
        }
    }

    @ViewBuilder
    private func certificateRows(_ certificate: TLSCertificateInfo) -> some View {
        LabeledContent(String(localized: "Отпечаток SHA-256")) {
            Text(certificate.fingerprint)
                .font(.body.monospaced())
                .copyable(certificate.fingerprint)
        }
        LabeledContent(String(localized: "Действует до"), value: certificate.notAfter.formatted(date: .abbreviated, time: .shortened))
        LabeledContent(String(localized: "Осталось")) {
            if certificate.isExpired() {
                StatusLabel(.error, String(localized: "истёк"))
            } else {
                Text("\(certificate.daysRemaining().plainDigits) дн.")
            }
        }
        LabeledContent(String(localized: "Выписан на"), value: certificate.hosts.joined(separator: ", "))
        HStack {
            Button(String(localized: "Скопировать отпечаток")) { model.copy(certificate.fingerprint) }
            Spacer()
            Button(String(localized: "Сохранить сертификат…")) { model.exportCertificate(app) }
            Button(String(localized: "Выпустить заново…")) { model.isConfirmingReissue = true }
        }
    }
}
