import SwiftUI
import ChromaCore

/// «Корзина»: what was deleted from the UI, from where, when — and the
/// way back, without a re-embed.
struct TrashView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var trash: TrashService
    @ObservedObject var model: TrashViewModel

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var entries: [TrashEntry] { model.entries(app) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    MessageBanner(kind: .success, text: status) { model.statusMessage = nil }
                }

                if trash.entries.isEmpty {
                    emptyCard
                } else {
                    contentCard
                }
                settingsSection
                howItWorks
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
        .confirmationDialog(
            String(localized: "Очистить корзину безвозвратно?"),
            isPresented: $model.showEmptyConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) { model.emptyTrash(app) }
            Button(String(localized: "Отмена"), role: .cancel) {}
        } message: {
            Text(String(localized: "Записей: \(trash.entries.count.plainDigits). Восстановить их после этого будет нельзя."))
        }
    }

    private var emptyCard: some View {
        SectionCard(
            title: String(localized: "Корзина пуста"),
            subtitle: String(localized: "Что удалено вручную, откуда и когда — восстановление без повторного эмбеддинга."),
            help: String(localized: "Автоматически удалённые чанки при переиндексации сюда не попадают — только ручное удаление из интерфейса. Восстановление идёт из сохранённого вектора: модель заново не считает.")
        ) {
            Text(settings.configuration.trashEnabled
                 ? String(localized: "Удалённые вручную документы и коллекции появятся здесь.")
                 : String(localized: "Корзина выключена: удаление документа необратимо. Включить её можно ниже."))
                .font(Theme.Font.body)
                .foregroundStyle(settings.configuration.trashEnabled
                                 ? Theme.Palette.captionText
                                 : Theme.Palette.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Содержимое корзины: сколько лежит, чем отобрать и что с этим делать.
    private var contentCard: some View {
        SectionCard(
            title: String(localized: "В корзине \(RussianCount.grouped(trash.entries.count, "запись", "записи", "записей"))"),
            subtitle: trash.totalBytes > 0
                ? String(localized: "Занято \(Self.sizeFormatter.string(fromByteCount: Int64(trash.totalBytes))). Восстановление идёт из сохранённого вектора — модель заново не считает.")
                : String(localized: "Восстановление идёт из сохранённого вектора — модель заново не считает."),
            help: String(localized: "Автоматически удалённые чанки при переиндексации сюда не попадают — только ручное удаление из интерфейса.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                controlsRow
                if entries.isEmpty {
                    Text("Под фильтр ничего не подходит.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                } else {
                    listCard
                }
            }
        }
    }

    private var howItWorks: some View {
        HowItWorks(screen: "trash") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Приложение не удаляет ничего само. В корзину попадает только то, что удалено руками из интерфейса: документ, выбранные находки инспектора или коллекция целиком.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Запись хранит и текст, и вектор — поэтому восстановление ничего не считает заново. Записи старше срока хранения и всё, что не помещается в предел размера, вытесняются: сначала самые старые.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Settings

    /// Настройки трогают раз в жизни — они свёрнуты, а их следствие («корзина
    /// выключена») сказано на самом экране.
    private var settingsSection: some View {
        AdvancedSection(place: "trash.settings", title: String(localized: "Настройки корзины")) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                Toggle(String(localized: "Использовать корзину"), isOn: Binding(
                    get: { settings.configuration.trashEnabled },
                    set: { model.setTrashEnabled($0, app: app) }
                ))
                .font(Theme.Font.control)

                HStack {
                    Text(String(localized: "Хранить")).font(Theme.Font.control)
                    Picker(String(localized: "Хранить"), selection: Binding(
                        get: { settings.configuration.trashRetentionDays },
                        set: { model.applyRetention(days: $0, app: app) }
                    )) {
                        ForEach([7, 14, 30, 90], id: \.self) { Text(String(localized: "\($0.plainDigits) дн.")).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    Text(String(localized: "Предел размера")).font(Theme.Font.control)
                    Stepper(
                        value: Binding(
                            get: { Double(settings.configuration.trashLimitBytes) / 1_073_741_824 },
                            set: { model.applyLimit(gigabytes: $0, app: app) }
                        ),
                        in: 0.25...20,
                        step: 0.25
                    ) {
                        Text(String(format: "%.2f ГБ", Double(settings.configuration.trashLimitBytes) / 1_073_741_824))
                            .font(Theme.Font.mono)
                    }
                    .frame(width: 220)
                    Spacer()
                }

                Text("Записи старше срока и всё, что не помещается в предел, вытесняются — начиная с самых старых.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 10) {
            TextField(String(localized: "Поиск"), text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 200, maxWidth: 260)

            Picker(String(localized: "Коллекция"), selection: $model.collectionFilter) {
                Text(String(localized: "Все коллекции")).tag(String?.none)
                ForEach(trash.collectionNames, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
            .frame(minWidth: 130, maxWidth: 220)

            Spacer(minLength: 8)

            if model.isRestoring {
                ProgressView().controlSize(.small)
            }
            Button(String(localized: "Восстановить выбранное")) {
                Task { await model.restoreSelected(app) }
            }
            .buttonStyle(.chromaPrimary)
            .disabled(model.selectedIDs.isEmpty || model.isRestoring)

            Button(String(localized: "Восстановить всё")) {
                Task { await model.restoreAll(app) }
            }
            .buttonStyle(.chromaNormal)
            .disabled(entries.isEmpty || model.isRestoring)

            Button(String(localized: "Очистить корзину")) {
                model.showEmptyConfirmation = true
            }
            .buttonStyle(.chromaDanger)
            .disabled(trash.entries.isEmpty)
        }
    }

    // MARK: - List

    private var listCard: some View {
        TableCard {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TableRow(isFirst: index == 0, isHighlighted: model.selectedIDs.contains(entry.id)) {
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: TrashEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selectedIDs.contains(entry.id) },
                set: { _ in model.toggle(entry) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.reason == .collection
                         ? String(localized: "вся коллекция")
                         : String(localized: "документ"))
                        .font(Theme.Font.micro)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((entry.reason == .collection ? Theme.Palette.attention : Theme.Palette.stopped).opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    Text(entry.collectionName).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                    Text("·").foregroundStyle(Theme.Palette.captionText)
                    Text(Self.dateFormatter.string(from: entry.deletedAt))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    if entry.embedding == nil {
                        Text(String(localized: "без вектора — восстановление недоступно"))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.documentID)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.captionText)
                    .copyable(entry.documentID)
                Text(preview(entry.document))
                    .font(Theme.Font.body)
                    .lineLimit(2)
                    .copyable(entry.document ?? "")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func preview(_ document: String?) -> String {
        guard let document, !document.isEmpty else { return String(localized: "— пустой документ —") }
        let flat = document.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}
