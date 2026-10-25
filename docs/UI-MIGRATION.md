# Переход интерфейса на системные компоненты macOS

Журнал редизайна по инструкции «ChromaDB Manager → стандартный интерфейс macOS
(14 Sonoma — 26 Tahoe)», v2. Ветка — `redesign-native`, отведена от `design`
на `e78cded`. Вернуть прежний вид — переключиться на `design`; эта ветка
никуда не вливается без отдельного решения.

## 0. Разведка — 28 сентября 2026

### Сборка

| | |
|---|---|
| Минимальная macOS | **14.0**: `platforms: [.macOS(.v14)]` в `Package.swift`, `LSMinimumSystemVersion 14.0` в `Resources/Info.plist` |
| SDK | macOS **26.5** (`xcrun --show-sdk-version`) |
| Xcode | **26.6** (17F113), Swift 6.3.3; `swift-tools-version: 5.9` |
| Как собирается | SwiftPM, без проекта Xcode: `Scripts/build-app.sh` заворачивает бинарник в `.app` и подписывает ad-hoc |
| Ключ режима совместимости (`UIDesignRequiresCompatibility`) | **нет** — Liquid Glass на 26 приложение получит |
| Машина разработки | macOS 26.5.2. Машин с 14 и 15 нет — проверка на них только в VM |

### Чем нарисован интерфейс

**SwiftUI** целиком. AppKit — точечно, в трёх файлах:

- `Theme.swift` — три `NSViewRepresentable`: накладные полосы прокрутки
  (`WindowScrollerStyle`, `OverlayScrollerSetter`) и заголовок экрана своим
  видом в полосе окна (`TitlebarTitle`);
- `QuickSearchPanel.swift` — плавающая панель быстрого поиска на `NSPanel`;
- `DocumentViewerView.swift` — PDF через `PDFView` из PDFKit (`NSViewRepresentable`).

Сцены (`App/ChromaDBManagerApp.swift`): `Window` главного окна (не `WindowGroup` —
нарочно: `WindowGroup` с идентификатором восстанавливал окна пачкой), `Window` «Исходный
документ», `MenuBarExtra`, `.commands`. Окна «Настройки» (`Settings { }`) нет.

Вида (`struct …: View`) в исходниках — 65. `Theme.` используется 1418 раз в 32 файлах.

### Карта экранов

| Сайдбар (группа) | Вкладка | Где нарисовано |
|---|---|---|
| **База** → Обзор | Состояние | `OverviewView.swift` |
| | Подключение | `ConnectionView.swift` |
| | Сервер | `ServerView.swift`, `ChromaProcessesCard.swift` |
| **База** → Установка | Установка | `EnvironmentStatusView.swift` — `checksCard` и далее |
| | Резервные копии | `EnvironmentStatusView.swift` — `backupsCard`, `maintenanceCard` |
| | Управление данными | `EnvironmentStatusView.swift` — `appUpdateCard`, `wipeCard`, `transferCard`; `MenuBarSettingsCard.swift`; `TransferSheet.swift` |
| **База** → Коллекции | Документы · Поиск · Обзор · Темы · Правила (вкладки коллекции, `CollectionTab.swift`) | `CollectionsView.swift`, `CollectionInsights.swift`, `FilterBuilderView.swift`, `SearchProfileSheet.swift`, `ReembeddingView.swift`, `DropSheet.swift` |
| **Данные** → Источники | Источники | `SourcesScreen.swift` → `SourcesView.swift` (`SourcesSection`), `TableMappingView.swift`, `CommaListField.swift` |
| | Диагностика | `DiagnosticsView.swift` (`DiagnosticsSection`) |
| | Стенд | `TestBenchView.swift` (`TestBenchSection`) |
| **Данные** → Модели | Модели | `EmbeddingsView.swift` — `defaultModelCard`, `lmStudioCard`, `modelsCard` |
| | Кэш | `EmbeddingsView.swift` — `cacheCard` |
| | Замеры | `EmbeddingsView.swift` (`BenchmarkTableSection`, `ModelProbeSection`), `StatisticsView.swift` |
| **Данные** → Оценка | Набор запросов · Варианты · Прогоны | `EvaluationView.swift` |
| **Данные** → Корзина | — | `TrashView.swift` |
| **Доступ** → Клиенты | Ключи · MCP · Журнал | `ClientsView.swift` |
| **Доступ** → Безопасность | Сводка · Доступ по сети · Уведомления | `SecurityView.swift` |
| **Система** → Задачи | — | `TasksView.swift` |
| **Система** → Логи | События · Доступ · Хранение · Сервер | `LogsView.swift` |
| Каркас | сайдбар, заголовок, вкладки, строка статуса | `RootView.swift`, `Components.swift`, `Theme.swift` |
| Вне главного окна | строка меню, быстрый поиск, просмотрщик | `MenuBarRoot.swift`, `MenuBarView.swift`, `QuickSearchPanel.swift`, `DocumentViewerView.swift` |

### Инвентаризация самодельного оформления

Команда из, совпадений — **368**, из них одно вне интерфейса
(`ChromaCore/Extraction/VisionOCRExtractor.swift:274` — `CGColor(red:…)`: белый
фон страницы перед распознаванием, к интерфейсу отношения не имеет; не трогается).

| Файл | Совпадений |
|---|---|
| `ChromaDBManagerApp/Views/Components.swift` | 57 |
| `ChromaDBManagerApp/Views/CollectionsView.swift` | 57 |
| `ChromaDBManagerApp/Views/SourcesView.swift` | 50 |
| `ChromaDBManagerApp/Views/TableMappingView.swift` | 24 |
| `ChromaDBManagerApp/Views/TestBenchView.swift` | 23 |
| `ChromaDBManagerApp/Views/SearchProfileSheet.swift` | 16 |
| `ChromaDBManagerApp/Views/CollectionInsights.swift` | 14 |
| `ChromaDBManagerApp/Views/LogsView.swift` | 13 |
| `ChromaDBManagerApp/Views/EvaluationView.swift` | 13 |
| `ChromaDBManagerApp/Views/ConnectionView.swift` | 13 |
| `ChromaDBManagerApp/Views/DocumentViewerView.swift` | 10 |
| `ChromaDBManagerApp/Views/Theme.swift` | 9 |
| `ChromaDBManagerApp/Views/FilterBuilderView.swift` | 9 |
| `ChromaDBManagerApp/Views/EnvironmentStatusView.swift` | 9 |
| `ChromaDBManagerApp/Views/EmbeddingsView.swift` | 9 |
| `ChromaDBManagerApp/Views/OverviewView.swift` | 6 |
| `ChromaDBManagerApp/Views/RootView.swift` | 5 |
| `ChromaDBManagerApp/Views/ReembeddingView.swift` | 5 |
| `ChromaDBManagerApp/Views/ClientsView.swift` | 5 |
| `ChromaDBManagerApp/Views/TrashView.swift` | 4 |
| `ChromaDBManagerApp/Views/DiagnosticsView.swift` | 4 |
| `ChromaDBManagerApp/Views/StatisticsView.swift` | 3 |
| `ChromaDBManagerApp/Views/SecurityView.swift` | 3 |
| `ChromaDBManagerApp/Views/QuickSearchPanel.swift` | 2 |
| `ChromaDBManagerApp/Views/MenuBarView.swift` | 2 |
| `ChromaDBManagerApp/Views/TransferSheet.swift` | 1 |
| `ChromaDBManagerApp/Views/MenuBarSettingsCard.swift` | 1 |
| `ChromaCore/Extraction/VisionOCRExtractor.swift` | 1 |

Кроме этих 368 строк, самодельное оформление живёт в `Theme.swift` (шрифты,
отступы, палитра, радиусы — 1418 обращений) и в `Components.swift`
(`SectionCard`, `CapsuleButtonStyle`, `SegmentedSelector`, `ChromaCheckboxToggleStyle`,
`HelpButton` и др.). Поиск их не ловит: экраны зовут `Theme.Font.caption`, а не
`.font(.system(size:))`.

<details><summary>Полный вывод поиска (368 строк)</summary>

```
Sources/ChromaDBManagerApp/Views/QuickSearchPanel.swift:140:        .padding(14)
Sources/ChromaDBManagerApp/Views/QuickSearchPanel.swift:144:        .frame(width: 460, height: 420, alignment: .top)
Sources/ChromaDBManagerApp/Views/SecurityView.swift:179:                .frame(width: 130, alignment: .leading)
Sources/ChromaDBManagerApp/Views/SecurityView.swift:525:                            .frame(width: 90)
Sources/ChromaDBManagerApp/Views/SecurityView.swift:546:                .frame(width: 130, alignment: .leading)
Sources/ChromaDBManagerApp/Views/LogsView.swift:147:            .frame(width: 110)
Sources/ChromaDBManagerApp/Views/LogsView.swift:217:                             : Theme.Palette.stopped).opacity(0.18))
Sources/ChromaDBManagerApp/Views/LogsView.swift:218:                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/LogsView.swift:230:                    .background(Theme.Palette.accent.opacity(0.16))
Sources/ChromaDBManagerApp/Views/LogsView.swift:231:                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/LogsView.swift:256:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/LogsView.swift:349:                                            .background(colour(for: entry.outcome).opacity(0.18))
Sources/ChromaDBManagerApp/Views/LogsView.swift:350:                                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/LogsView.swift:522:                    .frame(width: 140)
Sources/ChromaDBManagerApp/Views/LogsView.swift:532:                    .frame(width: 140)
Sources/ChromaDBManagerApp/Views/LogsView.swift:542:                    .frame(width: 140)
Sources/ChromaDBManagerApp/Views/LogsView.swift:570:                .frame(width: 160, alignment: .leading)
Sources/ChromaDBManagerApp/Views/LogsView.swift:644:                                                         ? Color.primary.opacity(0.8)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:108:                .frame(width: 220)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:113:                .frame(width: 220)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:134:                        .frame(width: 220)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:138:                                .textFieldStyle(.roundedBorder).frame(width: 60)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:156:                .frame(width: 320)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:201:                                .textFieldStyle(.roundedBorder).frame(width: 60)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:240:                .textFieldStyle(.roundedBorder).frame(width: 70)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:288:                .frame(width: 340)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:296:                .frame(width: 340)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:316:                            .frame(width: 260)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:354:                    .frame(width: 260)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:415:                            .textFieldStyle(.roundedBorder).frame(width: 320)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:422:                            .frame(width: 110)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:441:                    .frame(width: 340)
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:456:                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Palette.border))
Sources/ChromaDBManagerApp/Views/SearchProfileSheet.swift:491:                .textFieldStyle(.roundedBorder).frame(width: 60)
Sources/ChromaDBManagerApp/Views/TrashView.swift:131:                    .frame(width: 100)
Sources/ChromaDBManagerApp/Views/TrashView.swift:145:                    .frame(width: 220)
Sources/ChromaDBManagerApp/Views/TrashView.swift:226:                        .background((entry.reason == .collection ? Theme.Palette.attention : Theme.Palette.stopped).opacity(0.18))
Sources/ChromaDBManagerApp/Views/TrashView.swift:227:                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/ClientsView.swift:415:                .padding(12)
Sources/ChromaDBManagerApp/Views/ClientsView.swift:418:                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field))
Sources/ChromaDBManagerApp/Views/ClientsView.swift:420:                    RoundedRectangle(cornerRadius: Theme.Radius.field)
Sources/ChromaDBManagerApp/Views/ClientsView.swift:781:                .frame(width: 70)
Sources/ChromaDBManagerApp/Views/ClientsView.swift:819:                .frame(width: 120)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:38:                .frame(width: 190)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:81:                : Color(nsColor: .textBackgroundColor).opacity(0.6)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:83:        .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:97:                        .frame(width: 150)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:104:                            .frame(width: 122)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:113:                        .frame(width: 24)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:123:                .frame(width: 120)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:179:                    .frame(width: 110)
Sources/ChromaDBManagerApp/Views/FilterBuilderView.swift:198:                    .frame(width: 130)
Sources/ChromaDBManagerApp/Views/StatisticsView.swift:206:                                    .frame(width: 220, alignment: .leading)
Sources/ChromaDBManagerApp/Views/StatisticsView.swift:210:                                    .frame(width: 160, alignment: .leading)
Sources/ChromaDBManagerApp/Views/StatisticsView.swift:214:                                    .frame(width: 160, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:112:                            .frame(width: 200)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:162:                        .frame(width: 180)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:284:                                        .frame(width: 130 + 12, height: Self.rowHeight)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:338:                .frame(width: 30, height: Self.rowHeight, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:356:            .frame(width: 130, height: Self.rowHeight, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:395:                    Text("Колонка в файле").frame(width: 190, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:396:                    Text("Своё название").frame(width: 170, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:397:                    Text("Что с ней делать").frame(width: 140, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:420:                        Circle().fill(colour(for: binding.wrappedValue.role(of: column))).frame(width: 8, height: 8)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:432:                            .frame(width: 28, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:433:                        Text(column).font(Theme.Font.body).frame(width: 160, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:449:                        .frame(width: 170)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:458:                        .frame(width: 140)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:484:                    .frame(width: 220)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:607:                        .padding(8)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:609:                        .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:610:                        .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:625:                        .padding(8)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:627:                        .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:628:                        .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:663:                    .frame(width: 260)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:698:                    .frame(width: 220)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:714:                            .frame(width: 180, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TableMappingView.swift:744:                            .frame(width: 260)
Sources/ChromaDBManagerApp/Views/MenuBarView.swift:38:        .padding(12)
Sources/ChromaDBManagerApp/Views/MenuBarView.swift:43:        .frame(width: 400, height: 430, alignment: .top)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:154:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:156:            RoundedRectangle(cornerRadius: Theme.Radius.card)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:159:        .shadow(
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:202:            .frame(width: 28)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:233:            .frame(width: 30)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:265:                            RoundedRectangle(cornerRadius: Theme.Radius.row)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:349:                             ? Color.white.opacity(0.8)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:444:                .frame(width: 120, alignment: .leading)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:447:                .frame(width: 90)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:612:            .background(Theme.Palette.accent.opacity(0.08))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:613:            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:615:                RoundedRectangle(cornerRadius: Theme.Radius.row)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:616:                    .strokeBorder(Theme.Palette.accent.opacity(0.22), lineWidth: 1)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:713:                .frame(width: 30)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:741:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:743:            RoundedRectangle(cornerRadius: Theme.Radius.card)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:746:        .shadow(
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:858:                .frame(width: 190)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:863:                .frame(width: 160)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:966:                    .frame(width: 190)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1054:                        .frame(width: 190)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1124:                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1158:                            .frame(width: 28)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1230:                    .padding(10)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1231:                    .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1232:                    .clipShape(RoundedRectangle(cornerRadius: 8))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1319:                    .frame(width: 40)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1411:        .padding(10)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1412:        .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1413:        .clipShape(RoundedRectangle(cornerRadius: 8))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1426:                .frame(width: 16, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1536:        .padding(10)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1537:        .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1538:        .clipShape(RoundedRectangle(cornerRadius: 8))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1707:                            RoundedRectangle(cornerRadius: 5, style: .continuous)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1708:                                .fill(markTint(mark).opacity(0.14))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1773:                .frame(width: 34)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1812:        .padding(12)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1813:        .background(Color(nsColor: .controlBackgroundColor))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1814:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1851:                            .frame(width: 160)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1884:        .padding(8)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1885:        .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1886:        .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1910:                            RoundedRectangle(cornerRadius: Theme.Radius.field)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1946:                            .frame(width: 160)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:1955:                                .frame(width: 120, alignment: .leading)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2042:                        .frame(width: 180)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2054:                        .frame(width: 180)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2169:                                .frame(width: 300, alignment: .leading)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2182:                .padding(6)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2185:            .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2186:            .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2289:            .frame(width: 140)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2291:                .frame(width: 78)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2293:                .frame(width: 140)
Sources/ChromaDBManagerApp/Views/CollectionsView.swift:2296:                    .frame(width: 76)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:181:            .frame(width: 80)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:316:                                .background(Color.green.opacity(0.18))
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:317:                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:384:                .frame(width: 40)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:403:                    .frame(width: 200)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:422:                TextField(String(localized: "Имя"), text: $model.externalName).frame(width: 140)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:423:                TextField("Host", text: $model.externalHost).frame(width: 150)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:424:                TextField("Port", text: $model.externalPort).frame(width: 70)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:428:                TextField("tenant", text: $model.externalTenant).frame(width: 150)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:429:                TextField("database", text: $model.externalDatabase).frame(width: 150)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:440:                SecureField(String(localized: "Токен (необязательно)"), text: $model.externalToken).frame(width: 200)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:451:                .frame(width: 190)
Sources/ChromaDBManagerApp/Views/ConnectionView.swift:495:                        .frame(width: 110)
Sources/ChromaDBManagerApp/Views/MenuBarSettingsCard.swift:60:                    .labelsHidden().frame(width: 120)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:223:                    .frame(width: 130)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:273:                                        : Theme.Palette.attention.opacity(0.18))
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:274:                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:444:                        .frame(width: 220, alignment: .leading)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:446:                        RoundedRectangle(cornerRadius: 3)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:447:                            .fill(Theme.Palette.accent.opacity(0.35))
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:453:                        .frame(width: 60, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:473:                        .frame(width: 220, alignment: .leading)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:475:                        RoundedRectangle(cornerRadius: 3)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:476:                            .fill(Theme.Palette.accent.opacity(0.35))
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:482:                        .frame(width: 60, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:664:                    .frame(width: 130)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:683:                .frame(width: 100, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/CollectionInsights.swift:686:                .frame(width: 70, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/RootView.swift:232:                        .frame(width: 7, height: 7)
Sources/ChromaDBManagerApp/Views/RootView.swift:307:        .background(WindowScrollerStyle().frame(width: 0, height: 0))
Sources/ChromaDBManagerApp/Views/RootView.swift:634:                    .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/RootView.swift:647:                    .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/RootView.swift:691:        .background(Color(nsColor: .windowBackgroundColor))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:50:            .padding(8)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:52:            .background(Theme.Palette.attention.opacity(0.10))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:53:            .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:112:            .padding(8)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:114:            .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:115:            .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:126:                .frame(width: 160, alignment: .leading)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:136:            .background(Theme.Palette.accent.opacity(0.14))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:137:            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:156:                .frame(width: 260)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:167:                        .frame(width: 140)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:172:                    .frame(width: 230)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:185:                    .frame(width: 320)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:210:                .frame(width: 320)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:221:                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:257:                                .background(Color.red.opacity(0.18))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:258:                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:263:                                .background(Color.accentColor.opacity(0.18))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:264:                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:287:                .padding(8)
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:289:                .background(Color(nsColor: .textBackgroundColor))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:290:                .clipShape(RoundedRectangle(cornerRadius: 6))
Sources/ChromaDBManagerApp/Views/TestBenchView.swift:335:                        RoundedRectangle(cornerRadius: Theme.Radius.field)
Sources/ChromaDBManagerApp/Views/ReembeddingView.swift:135:                    .frame(width: 210)
Sources/ChromaDBManagerApp/Views/ReembeddingView.swift:142:                    .frame(width: 230)
Sources/ChromaDBManagerApp/Views/ReembeddingView.swift:234:        .padding(10)
Sources/ChromaDBManagerApp/Views/ReembeddingView.swift:235:        .background(Color.orange.opacity(0.08))
Sources/ChromaDBManagerApp/Views/ReembeddingView.swift:236:        .clipShape(RoundedRectangle(cornerRadius: 8))
Sources/ChromaDBManagerApp/Views/OverviewView.swift:83:                    .frame(width: 220)
Sources/ChromaDBManagerApp/Views/OverviewView.swift:268:                .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/OverviewView.swift:438:                ? Theme.Palette.attention.opacity(0.09)
Sources/ChromaDBManagerApp/Views/OverviewView.swift:441:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/OverviewView.swift:443:            RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(
Sources/ChromaDBManagerApp/Views/OverviewView.swift:444:                item.isUrgent ? Theme.Palette.attention.opacity(0.24) : Theme.Palette.border,
Sources/ChromaDBManagerApp/Views/TransferSheet.swift:226:                .frame(width: 140, alignment: .leading)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:159:                .font(.system(size: 32)).foregroundStyle(Theme.Palette.captionText)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:172:        .padding(24)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:181:                .font(.system(size: 32)).foregroundStyle(Theme.Palette.captionText)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:191:        .padding(24)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:198:                .font(.system(size: 32)).foregroundStyle(Theme.Palette.captionText)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:219:        .padding(24)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:499:                    Divider().opacity(0.3)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:502:            .padding(10)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:511:                .frame(width: 46, alignment: .trailing)
Sources/ChromaDBManagerApp/Views/DocumentViewerView.swift:523:        .background(isTarget ? Color.yellow.opacity(0.35) : Color.clear)
Sources/ChromaDBManagerApp/Views/Theme.swift:132:        static let border = Color.primary.opacity(0.09)
Sources/ChromaDBManagerApp/Views/Theme.swift:133:        static let rowDivider = Color.primary.opacity(0.06)
Sources/ChromaDBManagerApp/Views/Theme.swift:135:        static let subtleFill = Color.primary.opacity(0.022)
Sources/ChromaDBManagerApp/Views/Theme.swift:136:        static let selectionFill = Color.primary.opacity(0.05)
Sources/ChromaDBManagerApp/Views/Theme.swift:143:        static let segmentTrack = Color(white: 0.47).opacity(0.12)
Sources/ChromaDBManagerApp/Views/Theme.swift:146:        static let logBackground = Color.primary.opacity(0.02)
Sources/ChromaDBManagerApp/Views/Theme.swift:147:        static let logText = Color.primary.opacity(0.62)
Sources/ChromaDBManagerApp/Views/Theme.swift:148:        static let logTimestamp = Color.primary.opacity(0.35)
Sources/ChromaDBManagerApp/Views/Theme.swift:245:        background(OverlayScrollerSetter().frame(width: 0, height: 0))
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:175:                    .frame(width: 220)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:239:                                .frame(width: 130, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:276:                                .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:288:                                    .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:421:                                .frame(width: 100, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:424:                                .frame(width: 70, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:429:                                .frame(width: 110, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:432:                                .frame(width: 120, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EmbeddingsView.swift:437:                                .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:164:            .background(Theme.Palette.running.opacity(0.09))
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:165:            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.banner))
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:167:                RoundedRectangle(cornerRadius: Theme.Radius.banner)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:168:                    .strokeBorder(Theme.Palette.running.opacity(0.24), lineWidth: 1)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:264:                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Palette.border))
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:524:                        .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:527:                            .frame(width: 170, alignment: .leading).lineLimit(1)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:535:                            .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:544:                                .frame(width: 170, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:548:                    Divider().opacity(0.4)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:622:                .labelsHidden().frame(width: 260)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:729:                Divider().opacity(0.4)
Sources/ChromaDBManagerApp/Views/EvaluationView.swift:769:            .frame(width: 40)
Sources/ChromaDBManagerApp/Views/Components.swift:27:        tone == .danger ? Theme.Palette.danger.opacity(0.06) : Theme.Palette.card
Sources/ChromaDBManagerApp/Views/Components.swift:31:        tone == .danger ? Theme.Palette.danger.opacity(0.35) : Theme.Palette.border
Sources/ChromaDBManagerApp/Views/Components.swift:57:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/Components.swift:59:            RoundedRectangle(cornerRadius: Theme.Radius.card)
Sources/ChromaDBManagerApp/Views/Components.swift:62:        .shadow(
Sources/ChromaDBManagerApp/Views/Components.swift:180:            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/Components.swift:182:                RoundedRectangle(cornerRadius: Theme.Radius.card)
Sources/ChromaDBManagerApp/Views/Components.swift:185:            .shadow(
Sources/ChromaDBManagerApp/Views/Components.swift:190:            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/Components.swift:207:            .frame(width: 16, height: 16)
Sources/ChromaDBManagerApp/Views/Components.swift:210:                    isOn ? Color.clear : Theme.Palette.captionText.opacity(0.45), lineWidth: 1
Sources/ChromaDBManagerApp/Views/Components.swift:213:            .overlay(Circle().fill(.white).frame(width: 6, height: 6).opacity(isOn ? 1 : 0))
Sources/ChromaDBManagerApp/Views/Components.swift:317:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/Components.swift:319:            RoundedRectangle(cornerRadius: Theme.Radius.row)
Sources/ChromaDBManagerApp/Views/Components.swift:395:                        Capsule()
Sources/ChromaDBManagerApp/Views/Components.swift:397:                            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1.5, y: 1)
Sources/ChromaDBManagerApp/Views/Components.swift:400:                        Capsule().strokeBorder(
Sources/ChromaDBManagerApp/Views/Components.swift:408:        .padding(3)
Sources/ChromaDBManagerApp/Views/Components.swift:409:        .background(Capsule().fill(Theme.Palette.segmentTrack))
Sources/ChromaDBManagerApp/Views/Components.swift:447:            .background(Color(nsColor: .controlBackgroundColor))
Sources/ChromaDBManagerApp/Views/Components.swift:448:            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/Components.swift:450:                RoundedRectangle(cornerRadius: Theme.Radius.card)
Sources/ChromaDBManagerApp/Views/Components.swift:471:                .background(isHighlighted ? Color.accentColor.opacity(0.06) : .clear)
Sources/ChromaDBManagerApp/Views/Components.swift:512:                        .font(.system(size: 10, weight: .semibold))
Sources/ChromaDBManagerApp/Views/Components.swift:514:                        .frame(width: 18, height: 18)
Sources/ChromaDBManagerApp/Views/Components.swift:522:        .background(color.opacity(0.09))
Sources/ChromaDBManagerApp/Views/Components.swift:523:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.banner))
Sources/ChromaDBManagerApp/Views/Components.swift:525:            RoundedRectangle(cornerRadius: Theme.Radius.banner)
Sources/ChromaDBManagerApp/Views/Components.swift:526:                .strokeBorder(color.opacity(0.24), lineWidth: 1)
Sources/ChromaDBManagerApp/Views/Components.swift:588:        .padding(15)
Sources/ChromaDBManagerApp/Views/Components.swift:591:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
Sources/ChromaDBManagerApp/Views/Components.swift:636:struct CapsuleButtonStyle: ButtonStyle {
Sources/ChromaDBManagerApp/Views/Components.swift:666:            .font(.system(size: size, weight: emphasised ? .medium : .regular))
Sources/ChromaDBManagerApp/Views/Components.swift:672:                    .font(.system(size: size, weight: .medium))
Sources/ChromaDBManagerApp/Views/Components.swift:683:            .overlay(Capsule().strokeBorder(chosen ?? Theme.Palette.border, lineWidth: 1))
Sources/ChromaDBManagerApp/Views/Components.swift:684:            .clipShape(Capsule())
Sources/ChromaDBManagerApp/Views/Components.swift:689:            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 8, y: glow == nil ? 0 : 2)
Sources/ChromaDBManagerApp/Views/Components.swift:704:            Capsule().fill(Theme.Palette.selectionFill)
Sources/ChromaDBManagerApp/Views/Components.swift:706:            Capsule().fill(chosen)
Sources/ChromaDBManagerApp/Views/Components.swift:710:                Capsule().fill(LinearGradient(
Sources/ChromaDBManagerApp/Views/Components.swift:715:                Capsule().fill(LinearGradient(
Sources/ChromaDBManagerApp/Views/Components.swift:716:                    colors: [Theme.Palette.danger.opacity(0.85), Theme.Palette.danger],
Sources/ChromaDBManagerApp/Views/Components.swift:720:                Capsule().fill(Theme.Palette.card)
Sources/ChromaDBManagerApp/Views/Components.swift:740:        case .primary: return Theme.Palette.accent.opacity(0.45)
Sources/ChromaDBManagerApp/Views/Components.swift:741:        case .danger: return Theme.Palette.danger.opacity(0.4)
Sources/ChromaDBManagerApp/Views/Components.swift:757:struct ChromaCheckboxToggleStyle: ToggleStyle {
Sources/ChromaDBManagerApp/Views/Components.swift:766:                    .font(.system(size: 14))
Sources/ChromaDBManagerApp/Views/Components.swift:784:extension ToggleStyle where Self == ChromaCheckboxToggleStyle {
Sources/ChromaDBManagerApp/Views/Components.swift:785:    static var chromaCheckbox: ChromaCheckboxToggleStyle { ChromaCheckboxToggleStyle() }
Sources/ChromaDBManagerApp/Views/Components.swift:788:extension ButtonStyle where Self == CapsuleButtonStyle {
Sources/ChromaDBManagerApp/Views/Components.swift:790:    static var chromaPrimary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .primary) }
Sources/ChromaDBManagerApp/Views/Components.swift:791:    static var chromaNormal: CapsuleButtonStyle { CapsuleButtonStyle(kind: .normal) }
Sources/ChromaDBManagerApp/Views/Components.swift:793:    static func chromaChoice(_ chosen: Color?) -> CapsuleButtonStyle {
Sources/ChromaDBManagerApp/Views/Components.swift:794:        CapsuleButtonStyle(kind: .normal, chosen: chosen, reservesEmphasisWidth: true)
Sources/ChromaDBManagerApp/Views/Components.swift:796:    static var chromaSecondary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .secondary) }
Sources/ChromaDBManagerApp/Views/Components.swift:798:    static var chromaDanger: CapsuleButtonStyle { CapsuleButtonStyle(kind: .danger) }
Sources/ChromaDBManagerApp/Views/Components.swift:809:                .frame(width: 16, alignment: .center)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:228:            .background(Theme.Palette.attention.opacity(0.09))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:229:            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.banner))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:231:                RoundedRectangle(cornerRadius: Theme.Radius.banner)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:232:                    .strokeBorder(Theme.Palette.attention.opacity(0.24), lineWidth: 1)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:330:                    .frame(width: 30)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:557:                            .frame(width: 150, alignment: .leading)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:765:                                .background(kindColor(item.kind).opacity(0.18))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:766:                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:956:                                .frame(width: 160)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:1372:                            RoundedRectangle(cornerRadius: Theme.Radius.field)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:1599:                .frame(width: 220)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:1634:                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:1636:                    RoundedRectangle(cornerRadius: Theme.Radius.row)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:1700:                    .frame(width: 90, alignment: .leading)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:1711:                .frame(width: 150)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2135:        .frame(width: 250)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2142:                    .frame(width: 220)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2147:                Slider(value: draft.chunking.overlapPercent, in: 0...50, step: 5).frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2178:                    .frame(width: 300)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2206:                    .frame(width: 280)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2241:            Slider(value: draft.chunking.overlapPercent, in: 0...50, step: 5).frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2248:                .frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2251:                    .frame(width: 240)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2256:                Slider(value: draft.chunking.parentOverlapPercent, in: 0...50, step: 5).frame(width: 160)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2259:                .frame(width: 240)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2262:                Slider(value: draft.chunking.childOverlapPercent, in: 0...50, step: 5).frame(width: 160)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2281:                    Slider(value: draft.chunking.thresholdValue, in: 50...99, step: 1).frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2286:                    Slider(value: draft.chunking.thresholdValue, in: 0.01...1, step: 0.01).frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2290:                .frame(width: 240)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2308:                    .frame(width: 280)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2314:                Slider(value: draft.chunking.sensitivity, in: 0...1, step: 0.1).frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2318:                Slider(value: draft.chunking.overlapPercent, in: 0...50, step: 5).frame(width: 200)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2345:                Slider(value: draft.chunking.temperature, in: 0...1, step: 0.05).frame(width: 180)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2363:                    .frame(width: 90)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2380:                    .frame(width: 280)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2391:                    .frame(width: 160)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2393:                    .frame(width: 190)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2404:            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2490:            Text(title).font(Theme.Font.mono).frame(width: 130, alignment: .leading)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2496:            .frame(width: 110)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2502:            Text(title).font(Theme.Font.mono).frame(width: 130, alignment: .leading)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2507:            .frame(width: 110)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2514:                .frame(width: 190)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2516:                .frame(width: 210)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2553:                        .frame(width: 260)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2557:                                .frame(width: 150)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2559:                                .frame(width: 170)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2565:                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2567:                    RoundedRectangle(cornerRadius: Theme.Radius.row)
Sources/ChromaDBManagerApp/Views/SourcesView.swift:2578:                        .frame(width: 140)
Sources/ChromaDBManagerApp/Views/DiagnosticsView.swift:473:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/DiagnosticsView.swift:550:                        .background(Theme.Palette.accent.opacity(0.14))
Sources/ChromaDBManagerApp/Views/DiagnosticsView.swift:551:                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
Sources/ChromaDBManagerApp/Views/DiagnosticsView.swift:565:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:263:                .frame(width: 200, alignment: .leading)
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:394:        .background(isSelected ? Theme.Palette.accent.opacity(0.08) : Theme.Palette.subtleFill)
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:395:        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:397:            RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:398:                isSelected ? Theme.Palette.accent.opacity(0.35) : Theme.Palette.border,
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:709:                        .frame(width: 180)
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:774:                    .padding(10)
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:777:                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field))
Sources/ChromaDBManagerApp/Views/EnvironmentStatusView.swift:820:            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText).frame(width: 130, alignment: .leading)
Sources/ChromaCore/Extraction/VisionOCRExtractor.swift:274:        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
```

</details>

### Что может помешать — выяснить до правок

1. **Скриншоты «до»** — `docs/screens/before/light/`: 32 снимка, по одному
   на каждую вкладку (коллекция — `base_docs_4b`), окно 1512×949,
   уменьшены до 1512 px по ширине. Сняты 28 сентября 2026 со сборки `e78cded`.
   Тёмная тема — `docs/screens/before/dark/`, те же 32 вкладки. Снята при тёмной
   теме системы: приложению нельзя задать тёмный вид только для себя (ни
   `-AppleInterfaceStyle Dark`, ни ключ в его настройках не действуют).
2. **Сторожа интерфейса в тестах.** 17 тестовых файлов читают исходники экранов
   и ищут в них конкретные строки (`ChosenStateIsVisibleTests`,
   `InterfaceGuardTests`, `ClientLimitsLayoutTests`, `LengthSettingsInFormTests`,
   `ResultRowHeightTests`, `ZZLayoutCheckTests` и др.). Редизайн их сломает; их
   придётся переписывать вместе с экраном — это тесты, не слой данных.
3. **** описывает прежнюю дизайн-систему (заголовок своим видом
   в полосе окна, шкала шрифтов, карточки). После редизайна он устаревает целиком.
4. **Не-UI код** понадобится в нескольких пунктах инструкции — по это вопрос
   к заказчику, а не решение агента: `UndoManager` для удаления ( — нужен
   способ вернуть удалённое), перенос настроек в окно ⌘, ( — `Settings`-сцена
   в `App`), drag & drop папок на «Источники».
5. **Прежняя попытка.** Незакоммиченный редизайн 28 сентября (без ТЗ) откатан и
   лежит патчем `~/design-native-macos-2026-09-28.patch`:
   `FormPage`/`FormSection`, вкладки в тулбаре, системный заголовок. Годится как
   справка, не как основа.

### План фаз

1. Компоненты `UI/` и `UI/Compat.swift` с превью.
2. Каркас окна: сайдбар с футером статуса, `navigationTitle`, вкладки
   в тулбаре, `@SceneStorage`; меню и окно «Настройки».
3. Экраны по одному в порядке сайдбара: Обзор (3 вкладки) → Установка (3)
   → Коллекции → Источники (3) → Модели (3) → Оценка (3) → Корзина → Клиенты (3)
   → Безопасность (3) → Задачи → Логи (4). Один экран — один коммит; сборка,
   тесты, запись сюда.
4. Дедупликация — отдельными коммитами.
5. Итоговая проверка.

## 1. Компоненты `UI/` — 28 сентября 2026

`Sources/ChromaDBManagerApp/UI/`, по и — восемь файлов, единственные,
где разрешены числовые размеры. У каждого `#Preview`.

| Файл | Что это |
|---|---|
| `Compat.swift` | `primaryButtonStyle()`: `.glassProminent` на 26, `.borderedProminent` на 14–15 |
| `SectionHeader.swift` | `SectionHeader(title, help:)` — заголовок секции с «?» справа |
| `InfoButton.swift` | `InfoButton(text)` — «?» с поповером 320 pt, `accessibilityLabel` «Подробнее» |
| `StatusLabel.swift` | `StatusLabel(.ok / .warning / .error / .off, text)` — точка 8 pt и слова |
| `HowItWorks.swift` | `HowItWorks(screen:, text)` — `DisclosureGroup`, раскрытие в `@SceneStorage` на экран |
| `AdvancedSection.swift` | `AdvancedSection(screen:) { }` — `Section` + `DisclosureGroup` «Для опытных», `@AppStorage` на экран |
| `LogView.swift` | `LogView(lines:, followsEnd:)` — ленивый моноширинный журнал, `.defaultScrollAnchor`, `ScrollViewReader`, выделение текста |
| `Notice.swift` | `Notice(.info / .warning, text)` — строка со значком для `footer` |

**Отступления от, осознанные:**

- `HowItWorks` и `AdvancedSection` принимают имя экрана (`screen:`): состояние
  раскрытия помнится на экран, ключ `@SceneStorage`/`@AppStorage` без него
  один на всё приложение.
- Прежние `AdvancedSection` и `HowItWorks` (`Views/Components.swift`, 19 вызовов
  в 11 экранах) переименованы в `LegacyAdvancedSection` и `LegacyHowItWorks` —
  механически, вид не меняется. Удаляются, когда их вызовет последний
  непереведённый экран.
- Строки превью — `verbatim`: иначе они попадают в каталог текстов и требуют
  английской пары, которой у образца быть не должно. Новая строка интерфейса
  одна — «Подробнее» (en: «More information»).

Сборка чистая, предупреждений о доступности API нет; тестов 3130, падений нет.

## 2. Каркас окна — 29 сентября 2026

`RootView.swift`, новый `ConnectionStatusFooter.swift`, сцена в `App/ChromaDBManagerApp.swift`.

**Заменено**

- Сайдбар — `List(selection:)` + `.listStyle(.sidebar)`, `Section(group.title)`,
  `Label` без шрифта и цвета; ширина 180–210–280. Выделение и шрифт рубрик —
  системные (убраны `.tint(navSelection)`, капс с разрядкой, `Theme.Font`).
- Заголовок раздела — `navigationTitle`, подзаголовок — `navigationSubtitle`.
- Вкладки раздела — `Picker(.segmented).labelsHidden()` в `ToolbarItem(.principal)`
  вместо самодельного `SegmentedSelector` в содержимом.
- Раздел и вкладка каждого раздела — `@SceneStorage("section")`,
  `@SceneStorage("tab.<раздел>")` вместо `@State`: окно открывается там, где его
  закрыли.
- Сцена: `.windowToolbarStyle(.unified)` (было `.unifiedCompact`),
  `.defaultSize(1100×720)`; минимум 820×520 — на детали.

**Удалено**

- Имя приложения с точкой над списком разделов.
- Заголовок своим видом в полосе окна (`TitlebarTitle`) и шапка экрана
  с подписью и вкладками.
- `.toolbarBackground(.hidden)`, `.chromaControlShape()` (капсулы), накладные
  полосы прокрутки на всё окно (`WindowScrollerStyle`) — теперь полосы
  прокрутки ведут себя по системной настройке «Показывать полосы прокрутки».
- Нижняя строка статуса окна и `ServerUptimeLabel`.

**Перенесено**

- Из нижней строки в `ConnectionStatusFooter` внизу сайдбара: состояние
  подключения (`StatusLabel`) с кнопкой ↻, «только чтение», «настройки не
  сохраняются», идущая автоиндексация или «автоиндексация на паузе» (:
  автоматика не бывает невидимой). Время работы сервера и режим — только на
  «Обзоре».

**Тексты.** Подзаголовки разделов укорочены до шести слов; английские
пары добавлены.

**Осталось на потом.** Карточка «настройки потеряны / подняты из копии»
(`settingsAlarm`) — пока прежний `MessageBanner`; вкладки коллекции — в самом
экране «Коллекции» (переносятся с ним). Снимок «после» —
`docs/screens/after/light/00-frame-overview.png`; тёмная тема «после» —
пакетом в конце фазы.

## 2б. Строка меню — 29 сентября 2026

`App/MainWindowCommands.swift`, `RootView.swift`, `CollectionsView.swift` (только
приём просьбы «Новая коллекция» извне).

| Меню | Пункты |
|---|---|
| Файл | Новая коллекция… ⌘N · Новый источник… ⇧⌘N · Новый ключ клиента… |
| База | Подключиться ⌥⌘C · Отключиться · Перезапустить сервер ⌘R · Остановить сервер… (с подтверждением) · Сделать резервную копию |
| Коллекция | Выполнить поиск ⌘↩ · Добавить документы… · Экспортировать… · Пересчитать векторы… — доступны, когда на экране коллекций выбрана коллекция |
| Вид | вкладки открытого раздела ⌘1…⌘5; `SidebarCommands`, `ToolbarCommands` |
| Правка | `TextEditingCommands` |
| Справка | Справка ChromaDB Manager (README репозитория) · Сообщить о проблеме… (новый issue) |

Действие меню идёт тем же путём, что кнопка на экране: `RootView` держит
модели и выполняет `MainWindowCommand`; второй реализации нет.

**Отступления.** «Сделать резервную копию» — без многоточия: копия делается
сразу, без диалога (правило многоточия), и окно переходит на «Установка →
Резервные копии», где виден ход. «Новый ключ клиента…» пока только открывает
«Клиенты → Ключи»: лист нового ключа появится с экраном клиентов.
«Показать/скрыть инспектор ⌥⌘I» — когда появится первый инспектор.

**Сбой, найденный и закрытый по дороге.** Первая версия отдавала меню
значение `focusedSceneValue` с замыканиями — оно пересоздавалось на каждой
перерисовке окна, и SwiftUI перестраивал меню каждый раз. Через ~28 секунд
после запуска (начало фоновой работы) значок в строке меню обновлялся посреди
раскладки главного окна, и AppKit ронял приложение
(`NSStatusBarButton setImage:` → `_postWindowNeedsUpdateConstraints`), дважды
подряд. Теперь меню видит один объект на окно (`focusedSceneObject`,
в `RootView` — `@State`), а доступность пунктов — сравнимая структура,
публикуемая только при изменении. Три запуска по 70 секунд — без сбоев.

**Тесты.** `TypographyScaleTests` охранял прежнее правило 6
(«только `Theme.Font`») и упал на подвале сайдбара. Переписан под новое:
в переведённых экранах нет `Theme.Font` и размеров шрифта числом, в `UI/`
число — только у точки `StatusLabel`. Список переведённых экранов растёт
с каждым коммитом экрана.

## 2в. Окно «Настройки» — 29 сентября 2026

`Views/SettingsWindow.swift`, сцена `Settings { }` в `App/ChromaDBManagerApp.swift`.
`TabView` с `.tabItem`, ширина 560, каждая вкладка — `Form(.grouped)`,
переключатели — `.switch`.

| Вкладка | Что в ней | Откуда взято |
|---|---|---|
| Основные | язык интерфейса (с «Перезапустить»); строка меню и быстрый поиск; запуск сервера при старте | «Обзор → Состояние», `MenuBarSettingsCard` на «Установка → Управление данными», «Обзор → Сервер» |
| Уведомления | показывать уведомления; итоги фоновых операций — `.radioGroup`, пояснение выбранного в `footer` | «Безопасность → Уведомления» |
| Хранение | логи (размер файла, файлов, строк на экране, папка); корзина (вкл., срок, предел); кэш эмбеддингов (предел) | «Логи → Хранение», «Корзина», «Модели → Кэш» |
| Обновления | версия, «Проверить обновления», проверка при запуске — приложения и движка | «Установка → Управление данными», «Установка → Установка» |
| Перенос | экспорт и импорт настроек; лист подтверждения импорта — новый, на `Form` | «Установка → Управление данными» |

Модели экранов, которыми меняются эти настройки (`TrashViewModel`,
`SecurityViewModel`, `EnvironmentViewModel`, `SettingsTransferViewModel`),
у окна настроек свои экземпляры: их методы не зависят от состояния экрана.
Кэш эмбеддингов — общий `AppEnvironment.shared.embeddingsModel`.

**Пока дублируется.** Прежние карточки на экранах остаются до перевода своих
экранов — там они заменяются ссылкой `SettingsLink` или удаляются;
вкладки «Безопасность → Уведомления» и «Логи → Хранение» исчезают вместе
с ними.

**Отступления.** Число ширины окна (560) и поля «Предел, ГБ» (60) — не в `UI/`:
оба названы в самой инструкции (пример). Путь к журналу выводится
папкой; «Показать в Finder» — в контекстном меню строки.

Снимки — `docs/screens/after/light/settings-1…5.png`.

## 3.1. Обзор → Состояние — 29 сентября 2026

`OverviewView.swift`, `ChromaProcessesCard.swift`. Тип А — `Form(.grouped)`,
ширина до 760.

**Заменено.** Четыре плитки с 28-pt цифрами → секция «Сводка»
(`LabeledContent` × 4, `.monospacedDigit()`). Карточка «Сейчас» → секция
со `StatusLabel` у сервера и прокси, адрес и папка — моноширинно, в одну
строку с усечением посередине и полным текстом в `.help`; «Показать в Finder»
у папки — в контекстном меню. «Требует решения» → строки `StatusLabel`
с переходом `.buttonStyle(.link)` справа; пусто — «Всё в порядке».
Процессы прошлой сессии — секции формы; «Остановить…» теперь
`role: .destructive` с подтверждением.

**Удалено.** Карточка «Язык интерфейса» — в «Настройки → Основные».

**Тексты.** Телеметрия — своими словами («не собирается»,
«сервер ещё не отвечал»), сырое сообщение движка — в `.help`.

**Тесты.** `testTheStatusCardKeepsItsSizeWhatever` переписан: вместо
высоты числом — «каждое значение в одну строку, строка телеметрии есть
всегда». `FirstRunChainTests` не тронут — `decisions` прежний.
Снимок — `docs/screens/after/light/01-overview-status.png`.

## 3.2. Обзор → Подключение — 29 сентября 2026

`ConnectionView.swift`. Тип А — `Form(.grouped)`, ширина до 760.

**Заменено.** Карточка «Подключение» с двумя кнопками → одна кнопка в тулбаре
(`Подключиться` / `Отключиться` по состоянию, прогресс при подключении);
состояние — в подвале сайдбара. Режим — `Picker(.segmented)` вместо
`SegmentedSelector`. Папка базы — `LabeledContent` с путём и меню «⋯»
(«Выбрать папку… / По умолчанию / Показать в Finder»). Профили серверов —
строки с галочкой текущего и меню «⋯» (проверить, запустить/остановить,
токен, только чтение, allow_reset, удалить) вместо ряда кнопок в строке;
«Добавить сервер» — `Menu` («Новый сервер…», «Существующий сервер…»).
Мастер нового сервера, внешний сервер и токен — листы на `SheetForm`
(«Отменить» Esc, главная Return). Пределы записи и таймауты — `AdvancedSection`,
единица — в подписи («…, с»). Сообщения — `Notice` с «Скрыть».

**Новое общее.** `SheetForm` — лист-форма по; перенесён в `UI/SheetForm.swift`
(девятый файл `UI/`: у листа ширина числом).

**Проверено глазами.** Режим «Сервер» с пустым списком профилей — увиден
случайно (см. 3.3) и сразу возвращён. Листы нового и внешнего сервера — не
открывались.
Снимок — `docs/screens/after/light/02-overview-connection.png`.

## 3.3. Обзор → Сервер — 29 сентября 2026

`ServerView.swift`. Тип А — `Form(.grouped)`.

**Заменено.** Карточка «Процесс» → секция: `StatusLabel` сервера, строка
действий справа — «Перезапустить» (обычная), «Остановить…»
(`role: .destructive` + подтверждение с последствием), «Запустить» —
главная. Сообщения — `Notice` с «Скрыть».

**Перенесено.** «Запускать сервер при старте приложения» — в «Настройки →
Основные»; на экране — строка с состоянием и `SettingsLink`
«Изменить в Настройках…».

**Происшествие при съёмке.** Скрипт снимков нажал «Сервер» по первой
найденной надписи и попал в сегмент режима на вкладке «Подключение» — режим
в настройках заказчика переключился на «Сервер». Сразу возвращён на
«Локальная база» (проверено по `config.json`), подключение не прерывалось.
Вкладки теперь нажимаются только внутри тулбара.
Снимок — `docs/screens/after/light/03-overview-server.png`.

## 3.4. Установка → Установка — 29 сентября 2026

`EnvironmentStatusView.swift` (вкладка 0; вкладки 1 и 2 пока прежние —
`legacyTabs`). `LogView` получил компактный режим (высота в форме).

**Заменено.** «Проверки» → строки `LabeledContent` со `StatusLabel`
(состояние словами — в `accessibilityValue`), действие строки справа,
«Проверить заново» / ход и «Остановить» — последней строкой. Способ
установки — `Picker(.radioGroup)` вместо радио-карточек; следствие
выбранного — в `footer`; параметры Python — строками, «Установить Python» —
`Menu` (Homebrew / python.org). Действия — одной строкой, главная одна:
«Установить ChromaDB…», пока движка нет, «Обновить движок…», когда стоит.
«Вывод команд» — `DisclosureGroup` с `LogView`, свёрнут и раскрывается сам,
когда команда пошла. «Зачем приложению права…» — в `HowItWorks`. Листы
«Установка Chroma CLI» и «Обновление движка» — `SheetForm`.

**Перенесено.** «Проверять обновления автоматически при запуске» —
в «Настройки → Обновления»; строка «Проверка обновлений» осталась в проверках
.
Снимок — `docs/screens/after/light/04-install-install.png`.

**Исправлено следом.** Коммит 3.8 ушёл с упавшим сторожем: кнопка
инспектора переключала признак и выглядела одинаково в обоих состояниях.
Теперь это `Toggle(.button)` — нажатое состояние видно в тулбаре. Проверка
тестов перед коммитом больше не зависит от конвейера команд.

## 3.9. Коллекции → Поиск — 29 сентября 2026

`CollectionsView.swift`. Тип А — одна `Form(.grouped)`.

**Заменено.** Карточка «Запрос» → секция: поле запроса на всю ширину (Enter
выполняет, Option+Enter — перенос, сохранён), «Умный поиск» —
переключатель, профиль — `Picker` с «Настроить…» и меню «⋯» (новый,
дублировать, экспорт/импорт, удалить), «Результатов» — число со `Stepper`,
«Применять фильтр» — переключатель, «Искать также в» — меню с флажками
коллекций, «История» — `Toggle(.button)`, «Выполнить» —
главная. Пояснения — в `footer` (модель не указана, конвейер выключен,
профиль не изменил выдачу, сколько моделей посчитают вектор).
Отчёт по коллекциям — `StatusLabel` на строку. «Как получен этот результат» —
секция с `DisclosureGroup`, стадии — `LabeledContent`. Результат — своя секция:
в заголовке номер, коллекция, ID и расстояние; текст с соседями и родителем,
пометки строкой, метаданные — раскрывашкой, «Пометить» и «Показать
в документе…» — последней строкой. История — секция со строками «Подставить»
и меню «⋯» (закрепить, для стенда, удалить), «Очистить историю…» —
с подтверждением. Встроенный редактор тегов у результата — поля формы.

**Не проверено глазами.** Секции выдачи, отчёта и диагностики: LM Studio
на рабочей машине недоступна, запрос не выполнить.
Снимок — `docs/screens/after/light/09-collections-search.png`.

## 3.10. Коллекции → Обзор и Темы — 29 сентября 2026

`CollectionInsights.swift` переписан целиком — секциями формы; экран коллекции
ставит их в `Form` (`insightsScreen`).

**Заменено.** «Выборка», «Состав», «Проверки», «Темы» — секции с `SectionHeader`
и одной фразой в `footer`; длинные пояснения — в «?» и `.help` у переключателей.
Числа — `LabeledContent` со `Stepper`. Распределения (длины, фасеты) — строки
с системным `ProgressView` и числом вместо нарисованных полос; «Показать» —
ссылка. Находки — раскрывашки по разряду (`StatusLabel` для не информационных,
счёт рядом, «Выбрать все» — ссылка), флажки находок — `Toggle(.checkbox)`;
«Удалить выбранные…» — с подтверждением (раньше удаляло сразу). Отчёт тем —
таблица строками и секция на каждую тему с примерами. «Служебные поля» —
`AdvancedSection` со строками `LabeledContent`.
Файл — в сторож шрифтов.
Снимки — `docs/screens/after/light/10-collections-overview.png`,
`11-collections-topics.png`.

## 3.11. Коллекции → Правила — 29 сентября 2026

`CollectionsView.swift`. Тип А — `Form(.grouped)`.

**Заменено.** Карточка схемы → секция: поле схемы — строка (имя, тип,
«обяз.» и «+unix» — `Toggle(.checkbox)`, значение по умолчанию, «Убрать поле»);
«Запретить поля вне схемы» — переключатель; нарушения — `Notice`; главная
кнопка одна: «Вывести из документов», пока схемы нет, «Сохранить» — когда есть.
Соответствие документов — секция со `StatusLabel`-итогом и строками нарушений.
«Схема файлом» — `AdvancedSection`; «Удалить схему…» — с подтверждением.

**Удалено.** Прокрутка карточек на экране коллекций (`legacyTabContent`)
и прежний «Как это работает» — все вкладки коллекции теперь формы или таблица.
Снимок — `docs/screens/after/light/12-collections-rules.png`.

## 3.12. Коллекции — листы — 29 сентября 2026

`CollectionsView.swift`, `UI/SheetForm.swift`.

**Заменено.** Листы коллекции — `SheetForm` (форма и ряд кнопок внизу справа:
«Отменить» — Esc, главная — Return). «Новая коллекция» — имя, модель, метрика;
параметры индекса — `AdvancedSection`. «Документ» — широкий лист с
`TextEditor`. «Импорт» — `SheetFrame` со своими кнопками (выбор файла,
предпросмотр). «Привязать модель». «Удалить коллекцию» и «Очистить
коллекцию» — `isDestructive`: кнопка с `role: .destructive`, без главного вида
и без Return — случайно не нажать.

**Добавлено в `UI/`.** `SheetWidth` (обычный 480 / широкий 640), `SheetFrame`
для листов со своим рядом кнопок, у `SheetForm` — `isDestructive` и
`isWorking` (индикатор рядом с кнопками).

**Проверено глазами.** Лист «Новая коллекция» (кнопка «+»). Остальные листы
глазами не смотрены: снимок окна листы не захватывает, а управлять экраном
во время работы пользователя не стал.

## 3.13. Коллекции — пересчёт, перенос, профиль поиска, просмотр, фильтр — 29 сентября 2026

`ReembeddingView.swift`, `TransferSheet.swift`, `SearchProfileSheet.swift`,
`DocumentViewerView.swift`, `DropSheet.swift`, `FilterBuilderView.swift`,
`CollectionsView.swift`, `UI/SheetForm.swift`.

**Заменено.**
- Пересчёт векторов: `SheetShell` с карточками → `SheetFrame` (широкий,
  высокий) с секциями: коллекция (`LabeledContent`), модель, нарезка,
  сценарий (`radioGroup`), незавершённый пересчёт (`StatusLabel`), резервная
  копия, подтверждение. «Пересчитать на месте» — разрушительная кнопка без
  Return; «Создать клон» — главная. Ход и итог на экране коллекции — строки
  над содержимым (`ReembeddingProgressRow`, `ReembeddingReportRow`) вместо
  карточек, ошибки — `Notice` с «Скрыть».
- Перенос (`.chromaexport`): секции «Экспорт/Импорт», «Что уйдёт в пакет»,
  «Пакет» (строки `LabeledContent`), «Куда импортировать», «Отчёт импорта»
  со `StatusLabel`. Кнопка остановки идущей операции — «Остановить», чтобы
  не путать с «Отменить» листа.
- Профиль поиска: одиннадцать секций в порядке стадий; числа — `Stepper`
  с `LabeledContent` и поля формы; длинные пояснения — в «?» заголовка и
  `.help`; предупреждения — `Notice` в `footer`. «Отмена» → «Отменить».
  Длина кандидата вынесена в свою секцию (стадия 1, как и была).
- Просмотр документа: шапка системными стилями, оговорка о точности —
  `Notice`; «нет файла», «только внешнее приложение», «страница сайта» —
  `ContentUnavailableView`; лист таблицы — `Grid`. PDFView и NSTextView
  с номерами строк не тронуты: это AppKit-вид, его отступы — часть рисования.
- Перетащенное: секции «Папки» и «Файлы» с кнопками в своих секциях.
- Фильтр: без фиксированных ширин (`fixedSize` у меню), вложенная группа —
  `GroupBox`, проблема условия — `Notice`; дублирующий заголовок «Текст
  документа» внутри секции убран.

**Добавлено в `UI/`.** `SheetHeight` (`.fitting` / `.tall` — длинная форма
прокручивается, кнопки на месте), `textArea()` для `TextEditor` (число
`minHeight: 80` ушло из `CollectionsView`), `documentSheetFrame()` и
`tableCellWidth()` для просмотра документа.

Все файлы Коллекций — в стороже шрифтов (`TypographyScaleTests`).

**Не проверено глазами.** Листы этого шага не открывались: управлять
окном приложения во время работы пользователя не стал. Снимки — за
отдельным разрешением.

## 3.14. Коллекции — проверка листов глазами и правки — 29 сентября 2026

Листы из 3.12–3.13 открыты в собранном приложении.

**Исправлено по проверке.**
- Числа со стрелками: метка `Stepper` становилась подписью строки и
  прижимала значение к ней, стрелки уезжали к краю. Новый компонент
  `UI/StepperRow.swift` (десятый файл `UI/`): подпись слева, значение и
  стрелки справа. Им же пользуются «Обзор» коллекции, пересчёт и профиль.
- Профиль поиска: поля «Приставка» и «Instruct» — без своей подписи
  (её роль играет заголовок секции), иначе моноширинный шрифт доставался
  подписи, а текст прижимался вправо.
- Фильтр: вложенная группа — с отступом и чертой слева (`GroupBox`
  в форме рамки не рисует); поля строки условия — `roundedBorder`, иначе
  подсказки «поле», «значение» читались как подписи; «Сохранить» у имени
  фильтра — `fixedSize`, кнопка больше не обрезается.

**Проверено глазами.** Пересчёт векторов, экспорт, профиль поиска (весь,
прокруткой), фильтр с группой и условиями, выдача поиска (LM Studio
теперь доступна). Шапка просмотра документа — да; содержимое — нет:
система спросила доступ к папке «Загрузки», решение за пользователем.
Лист «Перетащенное» не открывался — перетаскивание из Finder не
имитировал.
Снимки — `docs/screens/after/light/13-collections-reembed.png`,
`14-collections-export.png`, `15-collections-profile.png`,
`16-collections-search-results.png`.

## 3.15. Источники → Источники — 29 сентября 2026

`SourcesView.swift` (часть до редактора), `SourcesScreen.swift`,
`SettingsWindow.swift`, `RootView.swift`, `UI/SheetForm.swift`.
Тип Б: `List` источников + инспектор.

**Заменено.**
- Карточка на источник → строка списка: имя, путь `.secondary` (середина
  ужимается, полный — в `.help`), `StatusLabel` состояния («синхронизирован»,
  «требует решения», «ждёт подтверждения», «автозапуск приостановлен»…).
- Подробности — инспектор (⌥⌘I): путь, вид, нарезка, куда, запуск, прошлый
  раз; «Настроить…» и кнопка синхронизации по состоянию («Синхронизировать» /
  «Подтвердить запуск» / «Остановить») с причиной остановки из плана в
  `footer`; «Требует решения» — `Notice` со своим действием в каждой строке;
  исключённые пути — строки с «Вернуть».
- Тулбар: «Добавить» — `Menu` (Папку… / Сайт… / Репозиторий…),
  «Синхронизировать» выбранный, инспектор, «Ещё» (План…, Таблицы…, Правила
  запуска…), «Синхронизировать все» — главная. Контекстное меню строки —
  все действия над источником; двойной клик — «Настроить…»; Delete —
  «Убрать из списка…» с прежним подтверждением.
- План синхронизации — лист (по одному на план, по очереди): итог, оценка,
  файлы флажками с системной иконкой вида вместо цветных плашек, пробный
  прогон таблиц. «Подтвердить и синхронизировать» — главная.
- «Требуют решения» — лист: флажки + «Выбрать все» + одно решение на
  выбранное; кнопки в строках убраны (тип Б).
- «Результат синхронизации» — строка над списком со `StatusLabel` и
  «Подробнее…» → лист.
- «Переизвлечь и переэмбедить» — пункт меню с подтверждением, про бэкап —
  в тексте подтверждения.

**Перенесено.** «Правила запуска», «Умолчания нарезки» и «Как это
работает» — в окно «Настройки», новая вкладка «Источники»; «Ещё → Правила
запуска…» открывает окно сразу на ней.

**Удалено.** Карточка «Диагностика извлечения» — дубль вкладки.
Число находок — в надписи сегмента «Диагностика · 2375»: сегменты macOS
`.badge` не рисуют.

**Добавлено в `UI/`.** `inspectorWidth()` — ширина инспектора одна на
приложение; число ушло из `CollectionsView`.

**Проверено глазами.** Список, инспектор, меню «Ещё», лист плана,
строка итога, Настройки → Источники.

**Происшествие при проверке.** Escape не закрыл лист плана, и следующее
нажатие Return сработало как его главная кнопка: источник `table_test`
синхронизировался (1 файл xlsx, записано 73 чанка, 78 записей вместо 5 —
по нынешнему профилю таблицы, как и показывал план). Прогон не прерывался:
остановка посреди записи хуже. Впредь при проверке листы закрываются
кнопкой, а не клавишами.

## 3.16. Источники — лист настройки источника — 29 сентября 2026

`SourcesView.swift` (`SourceEditorSheet`), `UI/StepperRow.swift`.

**Заменено.** `SheetShell` с карточками → `SheetFrame` (широкий, высокий)
с секциями: источник (имя, папка), репозиторий / адрес и обход, папка и
файлы, чтение, куда попадают файлы, поля из пути, как резать на чанки,
контекст в вектор, предел чтения модели, умолчания нарезки, когда
синхронизировать, метаданные, схема коллекции.
- Числа с подписью «chunk_size: 512» и ручной шириной → `StepperRow`;
  проценты и пороги — `SliderRow` (слайдер и значение справа); секунды —
  `DecimalStepperRow`.
- Переключатели чтения — `Toggle` с подписью под названием (системный вид
  двух строк в форме), вместо переключателя и отдельного абзаца с отступом.
- Языки OCR — меню с отметками вместо сетки флажков на пол-листа.
- Цена и пересчёт (OCR — часы, обогащение — число вызовов, «это новая
  нарезка») остались строками на экране; длинные пояснения — в «?» и `.help`.
- Предупреждения — `Notice`, «схема закрыта» — `StatusLabel`; проблема
  правила или уровня — `Notice` слева в ряду кнопок. «Отмена» → «Отменить».

**Добавлено в `UI/`.** `DecimalStepperRow`, `SliderRow`.

Файл целиком — в стороже шрифтов. **Проверено глазами** — весь лист
прокруткой на источнике Adaptive. Параметры других стратегий (LLM,
hierarchical, semantic, document-based) собраны теми же строками, глазами
не смотрены.

## 3.17. Источники → Диагностика — 29 сентября 2026

`DiagnosticsView.swift`, `SourcesScreen.swift`. Тип Б.

**Заменено.** Карточки со строками-плашками (флажок, точка, четыре кнопки
в каждой строке) → `Table` с `Section` на источник («Казначейство →
collection · 743»), колонки «Файл», «Причина», «Замечено», множественный
выбор. Фильтр по разряду — `Picker(.segmented)` над таблицей: «Все ·
2370 / Сканы без текста / Сбой чтения / Читать нечем / С оговорками» (файлы
с предупреждениями — тем же видом, отдельным сегментом). Выбор разряда
сразу показывает только его. Подробности одной находки — инспектор:
источник, файл, когда замечено, причина `Notice`, предлагаемое действие
(«Включить распознавание», «Ввести пароль…», «Повторить»).
Действия над выбранным — тулбар («Повторить», «Исключить из источника»,
инспектор, «Ещё»: «Убрать выбранное из списка», «Очистить все находки…»
с подтверждением) и контекстное меню (+ «Показать в Finder»); Delete —
«Убрать из списка». Лист пароля — `SheetForm`.

**Удалено.** Постраничный показ по 50 строк: таблица ленивая,
тысячи строк не раскладываются разом. «Выбрать все» у источника и
кнопка-переключатель «Только выбранные» — их делают ⌘A, выделение
секции и фильтр разряда.

**Проверено глазами.** Таблица, фильтр, инспектор находки. Сегментный
фильтр с `fixedSize` распирал содержимое, и инспектор уезжал за край окна —
`fixedSize` снят.
Снимок — `docs/screens/after/light/22-sources-diagnostics.png`.

## 3.18. Источники → Стенд — 29 сентября 2026

`TestBenchView.swift` (`TestBenchSection`), `SourcesScreen.swift`,
`UI/SheetForm.swift`. Тип А — `Form(.grouped)`.

**Заменено.** Карточка со строками «подпись 160 pt — контрол» → секции:
«Тестовый стенд» (стратегия, размер чанка `StepperRow`, единицы, чат-модель,
файл с «Загрузить файл…», «Читать с настройками» — пояснение в `.help`),
«Текст» (`TextEditor` + «Нарезать» — главная), «Извлечение» (`LabeledContent`
вместо плашек-«чипов»; предупреждения — `Notice`), «Распознанная структура»,
«Чанки» (строка на чанк; «не влезает в контекст» — `StatusLabel(.error)`;
превышение контекста и сводка — в `footer`), «Как это работает».
У `SourcesScreen` больше нет общей прокрутки и полей — все три вкладки
системные.

**Исправлено по проверке.** `textArea()` получил верхнюю границу высоты:
`TextEditor` в форме рос вместе с текстом, и вставленный документ
выталкивал всё, что под ним.

`ModelProbeSection` в том же файле — это «Модели → Замеры», переедет с ними;
поэтому файл пока не в стороже шрифтов.
Снимок — `docs/screens/after/light/23-sources-bench.png`.

## 3.19. Источники → Таблицы (лист сопоставления колонок) — 29 сентября 2026

`TableMappingView.swift`. `SheetShell` 860×640 с карточками → `SheetFrame`
(широкий, высокий) с секциями: таблицы источника (строка на файл: профиль
`Picker`, «Открыть»), листы (выбор листа — `Picker`, режим на лист —
строкой с причиной второй подписью), первые строки, колонки, что получится
из строки, переиндексация листа (`StatusLabel`/`Notice`, подтверждение
прежнее), профиль сопоставления («Сохранить профиль» — главная).
Сообщения — `Notice` со «Скрыть»; цветной текст предупреждений — `Notice`.
Шрифты — системные стили.

**Отклонение.** Сетка предпросмотра и список колонок — ленивые, и их
геометрия задана числами в `enum Grid` этого файла, а не в `UI/`: номера
строк стоят вне прокрутки и совпадают с ячейками только по общей мерке.
Эти места стережёт `InterfaceGuardTests` (`LazyHStack`, `LazyVStack`,
`numberCell` до `ScrollView(.horizontal)`). Цвета ролей у ячеек остались —
это разметка данных, а не оформление.

**Проверено глазами** на `table_test` (книга из 14 листов): листы, сетка,
колонки, текст документа. Разметка не менялась, профиль не сохранялся.
Снимок — `docs/screens/after/light/24-sources-tables.png`.

## 3.20. Модели — 29 сентября 2026

`EmbeddingsView.swift`, `StatisticsView.swift` (`MeasurementsTab`),
`TestBenchView.swift` (`ModelProbeSheet`), `UI/SheetForm.swift`.

**Модели.** Сверху форма: «Модель по умолчанию» — `Picker`, замер —
в `footer`; «LM Studio» — адрес строкой с «Проверить соединение» рядом и
«Состояние» — `StatusLabel` («моделей: 14 · 16:54» / «ещё не спрашивали»).
Под ней — `Table` доступных моделей: имя (моно, замер скорости второй
строкой), тип — `Picker` в ячейке, контекст, «тип определён». Кнопки в
строках убраны: «Измерить скорость/заново…», «Перезагрузить с контекстом N…»,
«Скопировать имя» — контекстное меню; «Измерить скорость» — ещё и тулбар.
Пустой список — `ContentUnavailableView`. Подтверждения — прежний `.alert`
, «Отмена» → «Отменить».

**Кэш.** Форма по образцу: переключатель, «Записей», «Размер», «Из
кэша за сеанс», «Предел размера» — `DecimalStepperRow`, «Очистить кэш».

**Замеры.** `VSplitView` из трёх панелей-таблиц: «Скорость моделей»
(разовые замеры), «Средние времена прогонов» — две таблицы рядом,
«Эмбеддинг» и «Нарезка» (: вместо списков с точками; LLM-based —
`StatusLabel(.warning)`), «Чем посчитаны коллекции» с переключателем на
«Строки из таблиц». Тулбар: «Проверить модель…», «Обновить», «Ещё →
Сбросить измерения…» — с подтверждением (раньше сбрасывало сразу).
Ручные проверки (вектор, сравнение моделей, близость текстов) — лист
«Проверить модель…» вместо третьей карточки на вкладке.

**Удалено.** Свод «По моделям» под таблицей коллекций — он пересказывал
ту же таблицу.

**Добавлено в `UI/`.** `splitPane()` — панель `VSplitView` не схлопывается
до нуля.

**Проверено глазами** — все три вкладки и лист проверки (без запуска
замеров).
Снимки — `docs/screens/after/light/25…28-models-*.png`.

## 3.21. Оценка — вкладки, история, отчёт — 29 сентября 2026

`EvaluationView.swift`; тесты `ComparisonAlignmentTests`, `ResultRowRankTests`.

**Набор запросов** — тип Б: набор — `Picker` в тулбаре, рядом
«Добавить запрос…» и «Ещё» (новый, переименовать, экспорт, импорт,
«Удалить набор…»). Запросы — `Table` (запрос, эталон, теги и фильтр);
«Править…», «Удалить…» — контекстное меню, двойной щелчок — правка, Delete —
удаление с прежним подтверждением. Строка набора и заметка — под таблицей.
Пустой набор и отсутствие наборов — `ContentUnavailableView` с действиями.

**Варианты** — форма: варианты строками с «Убрать», пусто —
`ContentUnavailableView` с «Добавить вариант…»; «Прогон» —
стоимость, ход, «Остановить», «Прогнать» — главная; «Готов прогон» —
`StatusLabel` с «Открыть прогон»; «Как это работает».
Листы набора, запроса и варианта — `SheetForm` (фильтр запроса — секцией).

**Прогоны** — три части сегментами над содержимым: «История» — `Table`
сохранённых прогонов, «Открыть» — двойной щелчок (; отдельного окна
пока нет — открывается здесь же, на «Отчёте»), «Удалить…» — теперь с
подтверждением (раньше удаляло сразу); «Отчёт» — форма: `@k` —
`Toggle(.button)`, таблица метрик — `Grid`, метрики по вариантам —
секциями с `LabeledContent`, расхождения, сравнение с прогоном, оценка
чат-моделью, экспорт; «Разметка» — сетка выдач на всё место под шапкой.

**Тесты.** Высота панели разметки больше не считается от страницы — она
занимает всё место под шапкой: `paneHeight` и три его теста удалены,
сторож в `ComparisonAlignmentTests` проверяет `maxHeight: .infinity`.

**Не сделано в этом шаге.** Ячейки сетки разметки — прежние капсулы и
шрифты `Theme`: их высоты прибиты тестами (`ResultRowHeightTests`), и
переводить их надо вместе с тестами — следующим шагом.
Снимки — `docs/screens/after/light/29…33-evaluation-*.png`.

## 3.22. Оценка — ячейки сетки разметки — 30 сентября 2026

`EvaluationView.swift`; тесты `ResultRowHeightTests`, `ComparisonAlignmentTests`,
`ChosenStateIsVisibleTests`.

**Заменено.** Капсулы оценок (свой стиль `chromaChoice`) → системные
кнопки: выбранная оценка — `.borderedProminent`, залитая цветом своей
оценки, остальные — `.bordered`. Первая попытка — `Toggle(.button)`
с `.tint` — окрашивала надписи всех трёх кнопок, а заливку выбранной
делала едва заметной: выбранное снова было не видно, отменено по проверке.
Шрифты ячеек — системные `.body`, `.subheadline`, `.caption`; отказ поиска
у варианта — `StatusLabel(.error)`. Сетка прижата к левому верхнему углу
панели (`defaultScrollAnchor(.topLeading)`).

**Тесты переписаны вместе с экраном.** «Двойники» строки и шапки — на
новых шрифтах и кнопках; закреплённые высоты пересчитаны замером:
строка 87 pt (с мнением модели 145), шапка колонки 32 pt (с оговоркой 62).
Ширина колонки проверяется замером настоящей строки оценок
(`NSHostingView`), а не суммой метрик капсульного стиля. Сторож
требует залитую кнопку с цветом оценки и отсутствие капсульного стиля.

Файл целиком — в стороже шрифтов. Снимок —
`docs/screens/after/light/33-evaluation-marking.png`.

## 3.23. Корзина — 30 сентября 2026

`TrashView.swift`. Тип Б.

**Заменено.** Карточка со строками-плашками (флажок, цветной «чип» вида,
кнопки над списком) → `Table` с множественным выбором: документ (текст и
ID вторым рядом), коллекция, что удалено, когда, вектор (`StatusLabel`
«нет» — восстановить нельзя). Поиск — `.searchable` в тулбаре, фильтр по
коллекции — `Picker` в тулбаре; «Восстановить» — главная кнопка тулбара,
двойной щелчок и контекстное меню («Скопировать ID», «Скопировать текст»);
«Ещё» — «Восстановить всё», «Настройки корзины…», «Очистить корзину…»
с прежним подтверждением. Пусто — `ContentUnavailableView("Корзина
пуста")`, при выключенной корзине — ссылка в Настройки; поиск без
результатов — `ContentUnavailableView.search`. Счёт, занятое место и
«Как это устроено» — строка под таблицей с «?».

**Удалено.** «Настройки корзины» на экране — они уже в
«Настройки → Хранение».

**Проверено глазами** — только пустое состояние: корзина на рабочей базе
пуста, а наполнять её ради проверки значило бы удалять документы.
Снимок — `docs/screens/after/light/34-trash-empty.png`.

## 3.24. Клиенты — 30 сентября 2026

`ClientsView.swift`, `RootView.swift`, `UI/AdvancedSection.swift`,
`UI/SheetForm.swift`; тест `ClientLimitsLayoutTests`.

**Ключи** — раздел со своим списком: `HSplitView`, слева `List`
ключей (имя, `StatusLabel` «активен / отозван», последняя активность),
справа форма ключа. «Активен» — `Toggle(.switch)` в заголовке формы;
права — переключатели; коллекции — флажки со своим полем фильтра; лимиты —
`AdvancedSection` «Лимиты» с одним «?» в заголовке, каждое поле — строка
формы с подсказкой (`.help`), по умолчанию — число серым в пустом поле;
подключение агента — раскрывающийся блок (конфигурация, команда, кнопки
агентов, проверка со `StatusLabel`). «Новый ключ…» — «+» в тулбаре и
⌘-пункт меню → лист в два шага: имя, затем ключ один раз с «Скопировать»
. Контекстное меню ключа: «Настроить подключение агента», «Показать
в журнале», «Перевыпустить ключ…», «Удалить клиента…» — оба последних
теперь с подтверждением (раньше срабатывали сразу); Delete — удаление.
«Прокси не запущен…» — `Notice(.info)` в `footer` первой секции, только
на «Ключах».

**MCP** — форма: сервер `StatusLabel`, два переключателя, адрес по сети
(«Скопировать адрес» — в контекстном меню), «Подключены сейчас».

**Удалено.** Вкладка «Журнал» — дубль «Логи → Доступ». «Показать в
журнале» открывает «Логи → Доступ»; отбор по клиенту появится вместе с
переделкой «Логов». Сохранённый индекс вкладки 2 ведёт на «Ключи».

**Добавлено в `UI/`.** `AdvancedSection(help:)` — «?» в заголовке блока;
`listPaneWidth()`, `detailPaneWidth()` — числа ушли из `CollectionsView`.

**Тест переписан.** `ClientLimitsLayoutTests`: вместо сетки с «?» у каждого
поля — блок «Для опытных» с одним «?», подсказка у каждого из шести полей,
число по умолчанию в пустом поле.

**Проверено глазами** — список, форма ключа, лимиты, MCP. Листы нового
ключа и подтверждения не открывались: создание ключа меняет доступ к базе.
Снимки — `docs/screens/after/light/35…37-clients-*.png`.

## 3.25. Безопасность — 30 сентября 2026

`SecurityView.swift`, `RootView.swift`, `ClientsView.swift`,
`ViewModels/SecurityViewModel.swift` (только статический помощник примера).

**Сводка** — форма: «На что стоит посмотреть» первой секцией (строки
`StatusLabel` по серьёзности с подсказкой второй строкой; пусто — «Всё в
порядке»); «Сводка» — `LabeledContent` со `StatusLabel`: сервер, прокси
(со ссылкой «Открыть» на «Доступ по сети»), ключи, журнал доступа;
«Экстренная остановка» — последней секцией, `role: .destructive`,
последствие — в `footer` и в подтверждении.

**Доступ по сети** — форма: «Прокси» (состояние, запуск/остановка, порт,
счётчики работающего прокси; «Трафик» — по режиму работающего прокси),
«Доступ по сети» (`radioGroup`, адреса — копируются из контекстного меню,
брандмауэр), «Шифрование» (TLS, отпечаток целиком с выделением и
«Скопировать отпечаток», срок, имена, «Сохранить сертификат…»,
«Выпустить заново…» — с прежним подтверждением).

**Перенесено и удалено.** Вкладка «Уведомления» — целиком в окне
«Настройки → Уведомления»; сохранённый индекс 2 ведёт на «Сводку».
«Как подключается клиент» (`curl …`) — в форму ключа на «Клиентах»; пример
строит статический `SecurityViewModel.connectionExample(configuration:)`,
форме ключа своя модель безопасности не нужна. Питоновская строка
«Клиент подключается так…» у прокси — удалена: пример на Python выдаётся
вместе с ключом.

**Проверено глазами** — обе вкладки. Снимки —
`docs/screens/after/light/38-security-summary.png`, `39-security-network.png`.

## 3.26. Задачи — 30 сентября 2026

`TasksView.swift`; попутно `DiagnosticsView.swift`, `TrashView.swift`,
`EvaluationView.swift`. Тип Б.

**Заменено.** Карточки «Выполняется» и «В очереди» со строками и кнопкой
«Отменить» в каждой → одна `Table` (выполняемые первыми): задача с
подробностью второй строкой, ход — `ProgressView`, состояние —
`StatusLabel`, приоритет, группа. «Отменить задачу» — тулбар, контекстное
меню и Delete; «Пауза / Продолжить» — кнопка тулбара, надпись и значок
меняются по состоянию. Пауза и «Осталось с прошлого запуска» — строками
над таблицей с «Продолжить» и «Забыть». Пусто —
`ContentUnavailableView("Нет задач", systemImage: "checklist")`. Порядок
очереди и правила — «?» в строке под таблицей.

**Исправлено по проверке.** `ContentUnavailableView` в стопке с подвалом
занимала лишь свою высоту, и подвал висел посреди окна. Заглушкам с
подвалом добавлено растяжение — здесь, в «Диагностике» (пустой разряд),
«Корзине» (пустой поиск) и «Оценке» (пустой набор).

**Проверено глазами** — пустое состояние: очередь на рабочей машине пуста.
Снимок — `docs/screens/after/light/40-tasks-empty.png`.

## 3.27. Логи — 30 сентября 2026

`LogsView.swift`, `RootView.swift`.

**События** — `LogView` на всю деталь (граница дня — строкой «── сегодня
──»); тулбар: `Picker` источника и уровня, `.searchable`, «Следить
за концом» — `Toggle(.button)`, `Menu` «Экспорт» (Скопировать, Сохранить…,
Журнал пересчётов…, Показать файл журнала в Finder), «Очистить…» —
`role: .destructive` с подтверждением (раньше очищало сразу). Журнал
пересчётов — лист со `StatusLabel` исхода вместо переключаемого блока.

**Доступ** — `Table` (время, клиент, канал, операция с видом доступа,
коллекция, итог, размер) с секциями по дням; тулбар: коллекция, «Только
запись» — `Toggle(.button)`, `.searchable`, «Ещё»: экспорт CSV/JSON,
«Архивы…» (лист), «Начать новый журнал…» с подтверждением. Контекстное
меню: «Скопировать параметры», «Показать только этого клиента». Отказы
MCP (без HTTP-кода) — причина `note` в колонке «Итог», `StatusLabel(.error)`.
Строк больше не 500: таблица ленивая.

**Сервер** — `LogView` на всю деталь; тулбар: «Следить за концом»,
«Скопировать», меню «Файлы» прошлых запусков; фильтр — `.searchable`;
пусто — `ContentUnavailableView`.

**Удалено.** Вкладка «Хранение» — сроки журналов уже в «Настройки
→ Хранение»; архивы журнала доступа — листом «Архивы…» на «Доступе».
Прежний индекс вкладки «Сервер» (3) ведёт на новый (2).

**Дедупликация доведена.** «Клиенты → Показать в журнале»
открывает «Логи → Доступ» с поиском по имени клиента: поиск журнала
доступа теперь приходит из `RootView` (`accessQuery`).

**Проверено глазами** — все три вкладки и переход из «Клиентов».
При проверке по ошибке открылось подтверждение «Перевыпустить ключ
«bionic»?» (промах координатами по контекстному меню) — закрыто
«Отменить», ключ не перевыпущен: префикс прежний.
Снимки — `docs/screens/after/light/41…44-logs-*.png`.

## 3.28. Окно строки меню, быстрый поиск, предупреждение о настройках — 30 сентября 2026

`MenuBarView.swift`, `QuickSearchPanel.swift`, `RootView.swift`,
`UI/SheetForm.swift`.

**Заменено.** Окно значка в строке меню: заголовок — `Label` системным
стилем, пауза синхронизации — `Notice`, MCP — `StatusLabel` вместо
нарисованной точки; быстрый поиск — `Picker` и поле с подписями для
VoiceOver, проблема — `Notice`, результаты — `List(.plain)` вместо
`ScrollView` со стопкой кнопок. Предупреждение о потерянных или
восстановленных настройках над экраном — `Notice` с «Понятно» и «Показать
снимок в Finder» вместо цветной плашки.

**Добавлено в `UI/`.** `menuBarPanel()` — размер всплывающего окна
(`MenuBarExtra` защёлкивает его при первом показе); `QuickSearchPanelSize` —
размер плавающей панели по горячей клавише (`NSPanel`).

Все экраны приложения теперь в стороже шрифтов: `Theme.Font` и
`.font(.system(size:))` в `Views/` остались только в самих `Theme.swift` и
`Components.swift`.
Снимок — `docs/screens/after/light/45-menubar.png`.

## 3.29. Удалены `Components.swift` и `Theme.swift` — 30 сентября 2026

Все экраны переведены, и старые компоненты больше нигде не используются:
`SectionCard`, `SheetShell`, `StatTile`, `HelpButton`, `LegacyAdvancedSection`,
`LegacyHowItWorks`, `SegmentedSelector`, `TableCard`/`TableRow`,
`MessageBanner`, `ConsoleView`, `LogBlock`, `StatusDot`, капсульные стили
кнопок (`chromaPrimary`, `chromaChoice`…), `chromaCheckbox`, `CheckRow`,
`MetadataTable` — и вся палитра, шрифты и отступы `Theme`.

**Перенесено** в `Views/ViewHelpers.swift` то, что живо и чисел не
содержит: `togglesDisclosure`, `copyable`, `QueueProgressRow`
.

**Тесты.** Удалены сторожа удалённого: `ShadowBudgetTests` (тени карточек
и свечение капсул), `ZZLayoutCheckTests` (замер своего флажка),
«начертание не меняет ширину» (`SteadyWeightLabel`), «стиль умеет
выбранное» (`CapsuleButtonStyle`). `TypographyScaleTests` проверяет теперь
**все** файлы `Views/` и `App/`, а не список переведённых: ни `Theme.`, ни
`.font(.system(size:)` там нет. `ChosenStateIsVisibleTests` — без
исключений.

## 3.30. Проверочный grep — чисто — 30 сентября 2026

Последние числа в экранах перенесены в `UI/`: ширина окна «Настройки» —
`settingsWindowWidth()`, короткие числовые поля — `numberFieldWidth()`,
лист импорта настроек — `SheetWidth.regular`. Подсветка найденной строки
таблицы в просмотре документа — системный `findHighlightColor` вместо
жёлтого с прозрачностью.

grep из инструкции по `Sources/ChromaDBManagerApp` без `UI/` находит
теперь только `.primaryButtonStyle()` — обёртку из `UI/Compat.swift`
(`.glassProminent` на 26, `.borderedProminent` на 14–15).

**Осознанные исключения** (записаны при своих шагах): геометрия ленивых
сеток — `enum Grid` в «Таблицах» и ширина колонки и высоты строк
в разметке «Оценки» (прибиты тестами); цвета ролей колонок в
«Таблицах» — разметка данных; AppKit-виды просмотра PDF и текста.

## 3.31. Итоговая проверка — 30 сентября 2026

Снимки при минимальном размере окна — `docs/screens/after/min/`.

**Минимальный размер окна.** `minWidth: 820, minHeight: 520` стоит на
детали ( инструкции), сайдбар — сверх неё, поэтому самое узкое окно —
1063×624 pt (со спрятанным сайдбаром — 820). Все экраны и вкладки сняты
при этом размере. Найдено и исправлено:

- **«Коллекции» и «Клиенты → Ключи» уезжали за правый край на 62 pt** —
  на всех вкладках, только на macOS 26. Сайдбар там плавает над деталью;
  `HSplitView` (AppKit) растягивал первую панель под него, а SwiftUI
  вдобавок ставил весь `HSplitView` в безопасную зону правее сайдбара —
  полоса под сайдбаром считалась дважды. Со спрятанным сайдбаром всё
  помещалось, что и подтвердило причину. Новый `UI/SectionSplit` ставит
  `HSplitView` правее сайдбара явным отступом (на 14–15 он нулевой);
  `listPaneWidth()`/`detailPaneWidth()` ушли в него. Потолок списка —
  280 вместо 320: при сужении окна `HSplitView` отдаёт место только
  детали, а список стоит на потолке.
- **Нижняя строка сайдбара** (состояние подключения) была прозрачной: при
  низком окне «Логи» просвечивали сквозь неё, и щелчок попадал в строку.
  Теперь `Compat.bottomBar`: на 26 — `safeAreaBar` (уехавшее под строку
  размывается), на 14–15 — `safeAreaInset` на материале `.bar` с
  разделителем.
- **«Оценка → Прогоны» без открытого прогона** — переключатель «История /
  Отчёт / Разметка» висел посреди окна: пустое состояние не занимало всю
  высоту.
- **«Оценка → Набор запросов»** — горизонтальная прокрутка на несколько
  точек: растянутая на широком окне колонка «Эталон» не отдавала место
  обратно. У «Эталона» и «Тегов» теперь потолок, тянется «Запрос».

Осталось как есть: на «Документах» с открытым инспектором таблице при
самом узком окне остаётся около 220 pt — она прокручивается внутри себя,
инспектор прячется кнопкой тулбара. Подзаголовки окна с длинными
вкладками («Установка», «Коллекции») система сокращает многоточием.

**Предупреждения.** Полная сборка с нуля — 0 предупреждений. Цель —
macOS 14, поэтому вызов API 15+ без проверки не соберётся вовсе; все
`#available` новее 13 — только в `UI/Compat.swift`.

**Главная кнопка.** Во всех местах, где в файле две `primaryButtonStyle()`
на одном экране, они в ветках `if/else` — видна одна.

**Кнопки в строках таблиц** — нет. Единственный элемент в ячейке — выбор
типа модели в «Моделях» (правка значения на месте).

**Разрушительное без подтверждения** — нашлось три удаления профилей,
которые человек настраивал сам: профиль поиска («Коллекции → Поиск»),
профиль сервера («Обзор → Подключение»), профиль сопоставления таблиц.
Теперь все три спрашивают «Удалить профиль «…»?» и говорят, что будет.
Без подтверждения оставлены удаление сохранённого фильтра и записи
истории поиска — мелочь из меню.

**VoiceOver.** Семь кнопок и меню со значком вместо надписи имели только
`.help` — VoiceOver прочёл бы имя символа. Теперь у них
`Label(…).labelStyle(.iconOnly)`: вид тот же, имя есть. Значок в строке
меню озвучивает состояние словами (`MenuBarSummary.headline`). Сканер AX
по всем 29 экранам и вкладкам (без обхода таблиц) не находит ни одного
элемента управления без имени, кроме системных стрелок прокрутки и кнопок
окна. Поля и переключатели форм связаны со своими подписями
(`AXTitleUIElement`) — проверено и на отдельной пробе с голым
`Form(.grouped)`: SwiftUI отдаёт их так же.

**Tab.** В системе выключена «Навигация с клавиатуры», поэтому Tab ходит
только по полям ввода. По ним на листе «Настройка источника» порядок —
сверху вниз, по кругу, Shift-Tab — обратно, прокрутка показывает поле с
фокусом. Полный проход по всем элементам — с включённой настройкой.

**Не проверено здесь:** тёмная тема, «Увеличить контраст», «Уменьшить
прозрачность», крупные значки сайдбара, полный Tab и живой VoiceOver —
это системные настройки; запуск на macOS 14 и 15.

## 4. Правки по скриншотам (v3) — 30 сентября 2026

Исходное задание — «CLAUDE-CODE-macOS-UI v3 - правки по скриншотам». Снимки
«после» — `docs/screens/after-v3/` (окно 1200×760, те же имена, что в
`after/light/`; листы, которые что-то запускают, — план синхронизации,
пересчёт, экспорт, проба модели, — не открывались).

Коммиты: `3feafd9` (окно, ширины, тулбар), `a135322` («Для опытных»,
инспекторы), `e24c77a` (таблицы, строка статуса, «Модели», настройки), плюс
исправления падения `0aca414`, `c4f6a96`, `daf27cd`.

**Сделано по пунктам v3.**

- — у форм снят `maxWidth: 760`. «Модели»: вкладки «Модели · Подключение ·
  Кэш · Замеры», у «Моделей» — одна таблица.
- — сайдбар 190–260, список раздела 220–340, инспектор 260–400 везде
  (`UI/FittingInspector`), колонки таблиц по одному правилу, порядок и ширины
  колонок помнит окно.
- — окно не меньше 900×560, первое открытие 1200×760 (`UI/WindowSize`).
  Инспектор сам уходит, когда таблице не хватает места, и возвращается.
  Вкладки «Настроек» — по содержимому, без прокрутки (232–647 pt).
- — все таблицы в одну строку; вторые строки — своими колонками; списки
  «Коллекций» и «Источников» — имя и короткая подпись.
- — «Для опытных» — `Section(isExpanded:)`; у таймаутов — стрелки.
- — `UI/InspectorField`, инспекторы без кнопок-дублей, `Notice` с цветным
  значком и обычным текстом.
- — подзаголовок окна убран (его текст — подсказка у пункта сайдбара);
  у «Коллекций» четыре вкладки; в тулбарах не больше трёх значков и меню;
  выделенных кнопок в тулбаре нет; счётчик диагностики — бейдж в сайдбаре;
  разряд находок — меню «Причина».
- — нижняя строка сайдбара «Локальная база»; гистограмма длин — Swift
  Charts; «Показать» — двойной щелчок и контекстное меню; «Клиенты → Ключи»
  без строки «Права», коллекции — листом; «Доступ по сети» — короткие
  подписи, адрес — в подписи секции; «Тип определён» — подсказкой;
  «Только запись» журнала — пунктом меню; `UI/TableFooter` — одна строка
  статуса.

**Отступления от v3 — и почему.**

- **Формы по центру на macOS 26 остались.** Сгруппированная форма на 26 сама
  держит секции шириной около 700 pt, как «Системные настройки»: проверено
  на отдельной пробе с голой `Form(.grouped)` — ни `contentMargins`, ни
  `frame(maxWidth: .infinity)`, ни `scrollContentBackground` этого не
  снимают. Своя форма вместо системной противоречила бы главному правилу. На
  14–15 формы растягиваются сами.
- **Вкладки — слева, а не по центру (`.principal`).** По центру они прыгали
  при каждом переключении: центр считается по свободному месту, а кнопки
  справа у вкладок разные. Слева, на месте заголовка, они неподвижны;
  заголовок из полосы тулбара убран (`toolbar(removing: .title)`, macOS 15+;
  на 14 он стоит после вкладок). Замечание заказчика: «меню скачет».
- **«Темы» — в «Обзоре», а не в «Метаданных».** Темы — о содержании
  коллекции, как и её состав; в «Метаданные» ушли схема, соответствие и
  служебные поля.
- **«Итог» журнала доступа не скрыт по умолчанию.** Там видны отказы — у MCP
  без кода ответа; спрятанная колонка спрятала бы именно ошибки. Вместо
  «—» у успешных — пустая ячейка.
- **Пояснение «Для опытных» — последней строкой секции.** У
  `Section(isExpanded:)` нет варианта с `footer`: пример из v3 не собирается.
- **Выбор коллекций ключа — поле поиска в листе, а не `.searchable`.** Лист
  без тулбара.
- **«Хранение» в «Настройках» (647 pt) не разделено.** Три коротких секции
  об одном — сколько чего хранить; помещается на любом экране.
- **Строка статуса — видом под таблицей, а не `safeAreaInset`.** Вид тот же;
  сама таблица при этом не уходит под строку.

**Падение значка строки меню.** Во время работы пришли отчёты о падении
(`NSStatusBarButton.setImage` → исключение AppKit посреди раскладки окна);
такие же были 29 сентября. `MenuBarExtra` ставил картинку кнопке значка при
обновлениях сцены. Постоянная картинка и сцена, не следящая за окружением,
не помогли — значок переведён на AppKit (`StatusItemController`,
`NSStatusItem` + `NSPopover` с тем же `MenuBarView`). Цена: значок больше не
меняет картинку по состоянию очереди; состояние словами — в окне значка.
Проверено 24 сменами размера окна вперемешку с разделами.

**Попутно.** `.badge` после `.tag` у пункта сайдбара прятал тег от списка —
щелчок по разделу ничего не выбирал (`0aca414`). Подпись «тип определён
приложением» уточнена: тип определяет пробный запрос, а не имя модели.

**grep из шапки v3** вне `UI/` и ширин колонок находит только `lineLimit(2+)`
не в таблицах — многострочные поля ввода (`axis: .vertical`), результаты
поиска и история (списки), примеры тем — и уже записанные исключения: сетку
разметки «Оценки», сетку «Таблиц», AppKit-просмотр.

## 4.1. Тёмная тема — 30 сентября 2026

Снимки — `docs/screens/after-v3/dark/` (те же экраны, что в `after-v3/`, и
вкладки «Настроек»). Свой цвет, выпадающий из темы, не нашёлся ни на одном
экране: всё системное. Инспектор «Диагностики» темнее таблицы — так
macOS 26 рисует колонку инспектора.

**Найдено и исправлено при проверке.**

- **Лист выбора коллекций ключа не открывался.** `.sheet` был привязан к
  секции формы, а на секции формы он не срабатывает — проверено в окне.
  Лист перенесён на форму.
- **По той же причине — шесть подтверждений, висевших на секциях**:
  экстренная остановка, «Открыть прокси в локальную сеть?», перевыпуск
  сертификата, переиндексация листа, остановка процесса прошлой сессии,
  удаление профиля сервера и профиля сопоставления. Теперь каждое — у своей
  кнопки или строки (у строк списка — с условием «именно эта», чтобы не
  открылось несколько). Проверено на «Открыть прокси в локальную сеть?»:
  вопрос появляется, «Отменить» оставляет доступ «Только этот Mac».
- «Первый вызов» в «Замерах» — колонка шире: «меньше секунды» обрезалось.

**Не вёрстка, а данные.** В «Темах» коллекции описания тем — это текст
рассуждения чат-модели («The user wants a short title…»), а не описание:
модель вернула не то, что просили, и приложение показало ответ как есть.

## 5. Правки по тёмным скриншотам (v4) — 30 сентября 2026

Задание — «CLAUDE-CODE-macOS-UI v4 - правки по тёмным скриншотам». Снимки —
`docs/screens/after-v4/dark/` (светлые — после переключения темы
заказчиком).

**Проверка отчёта: что не подтвердилось.**

- **A1 «формы узкой полосой — ограничение где-то в коде».** Не в коде:
  `maxWidth` у форм снят ещё в v3. На macOS 26 сгруппированная форма сама
  держит секции шириной около 700 pt (проба с голой `Form(.grouped)`).
  В «Коллекции → Обзор» деталь уже 700 pt — поэтому там «на всю ширину».
- **A2 «пустые полосы выше строк».** Замерено по пикселям снимка «Резервных
  копий»: строки с данными и пустые полосы — по ~29 px. Полосы чередуются
  (закрашенная, прозрачная), и пара выглядит как одна полоса двойной
  высоты. Высота строк нигде не переопределена.
- **B «кнопки-иконки без подписи» (молния «Подключения», спидометр
  «Моделей»).** Обе — `Label` с подписью, молния меняется на «Подключиться».
  Подпись не видна, потому что тулбар по умолчанию показывает только значки;
  она есть в подсказке и в режиме «Значки и текст».
- **B «Хранение → Папка — путь без действия».** «Показать в Finder» уже был
  в контекстном меню строки; кнопкой в строке он раздувал вкладку до 701 pt —
  оставлен в меню.
- **B «Следить за концом» — синяя залитая кнопка».** `.tint` и выделенного
  стиля нет — так macOS 26 рисует включённый переключатель в тулбаре, как и
  кнопку инспектора.

**Сделано.**

- A3 — дробные числа в локали интерфейса (`decimal(_:)`): «66,4», «5 282,5»;
  проценты тем — «1 документ · 20 %»; «5000» → «5 000» в «Хранении», лимиты с
  разрядами. Компоненты векторов оставлены с точкой — в списке через запятую
  десятичная запятая нечитаема.
- A4 — имена моделей обычным шрифтом во всех таблицах.
- A5 — «Записей в одном запросе» и «Размер одного запроса» (ответ сервера)
  перенесены в «Обзор → Состояние». Числовые поля — с рамкой и стрелками:
  таймауты, лимиты ключа, пределы в ГБ, `StepperRow` с простым числом
  (значение словами — «50 МБ» — осталось текстом со стрелками). «Корзина»:
  «Хранить» — меню (набор 7/14/30/90), «Предел, ГБ» — поле: каждое по
  правилу самого v4; один тип на секцию значил бы менять допустимые
  значения — это логика, оставлено.
- A6 — у всех коротких колонок потолок; главная текстовая — без ширины;
  ключи сохранённых колонок — `.v2`. «Итог» журнала доступа скрыт по
  умолчанию, но отказ виден в самой строке — операция красным с причиной в
  подсказке. «Копия» в резервных копиях скрыта (имя — в подсказке даты),
  «Состояние» целой копии — пустое.
- A7 — строки «Состав коллекции», «Темы», «Проверки», «Экстренная
  остановка» — с подписью о состоянии; синих кнопок в формах экранов нет
  (выделенные остались в листах); «Прогнать» — без Return.
- B — «Подбирать число тем автоматически»; выбранная, но отсутствующая в LM
  Studio модель показывается «… — нет в LM Studio»; «Источники» и «Ключи» —
  состояние точкой, ключи — «активность: позавчера»; инспектор источника —
  заголовок `.headline`, «Нарезка» и «Прошлый раз» по строкам; пустые
  инспекторы — `InspectorPlaceholder`; выбор типа модели — меню без рамки;
  «Замеры» — одна таблица на экран, выбор в тулбаре (скорость, эмбеддинг,
  нарезка, коллекции, строки из таблиц), «< 1 с»; «Сводка» — значки
  важности, «Доступ по сети…» кнопкой, остановка одной строкой; «Доступ по
  сети» — варианты строками, подпись «… (127.0.0.1).», подпись TLS о
  текущем режиме; журнал событий — от верха, перенос под текстом;
  «Основные» — «Строка меню» и «Быстрый поиск» раздельно.

**Найдено по ходу.** «Диагностика», открытая первой после запуска, писала
«Замечаний нет», а бейдж у «Источников» был пуст: находки читал только
список источников. Теперь их читают окно при запуске и сама «Диагностика».

**Светлая тема.** Снимки — `docs/screens/after-v4/light/` (30 экранов и
6 вкладок «Настроек»), те же имена, что в `dark/`. Своих цветов, выпадающих
из темы, нет. По ходу: «Настройки → Уведомления → Уведомлять» — варианты
строками, как «Доступ по сети»; в ряд они стояли по той же причине.

## 6. Третий проход (v5) — 1 октября 2026

Пункты 1 и 2 v5 (ширина форм и полосы под таблицами) не трогались по
решению заказчика — разобраны в Раздел 3:

- «Для опытных» на «Подключении» — подпись под карточкой: у `AdvancedSection`
  появился `footer` (подвал пустой секции сразу под раскрывающейся).
- «Резервные копии» — «Состояние» видна по умолчанию, только когда есть
  повреждённая копия (`defaultVisibility`; условие внутри описания колонок
  компилятор не осиливает).
- «Документы» — пометка значком (`pin.fill`, «понижен», «устарел»), слово — в
  подсказке и для VoiceOver. Ширина колонки — 72, а не 40: при 40 обрезался
  заголовок «Пометка». Проверено в окне 1200×760: заголовок целиком. Заодно
  вернулась потерянная ширина «Фрагмента» (без неё он сжимался до одного слова),
  а ID и «Источнику» подняты минимумы (110 и 140), чтобы имена файлов читались.
  Идеальные ширины на раскладку почти не влияют — таблица делит место по
  минимумам.
- «Темы коллекции» — в выборе модели только имя; «Модели нет в LM Studio — темы
  не назовутся.» — под секцией, «Найти темы заново» при этом неактивна;
  «Найдено тем: N» вместо «Темы найдены — ниже».
- Инспектор источника — всё `LabeledContent`: «Куда», «Файлов в манифесте»,
  «Записей», «Обновлён»; нарезка — своей секцией, строка на параметр
  (Стратегия, База, Диапазон, Чувствительность — у каждой стратегии свои).
  Столбиком — только «Путь».
- «Диагностика» — инспектор закрыт по умолчанию, открывается двойным щелчком
  по строке.
- «Ключи» — «Подключение агента (MCP)» — раскрывающаяся секция, как «Лимиты».
- «Сводка» — «Доступ по сети» ссылкой, без многоточия.
- «Настройки → Основные» — «Результатов в быстром поиске» полем со стрелками.
- «Хранение → Папка» — «Показать в Finder» в контекстном меню строки (было и
  раньше; v5 это допускает).

Снимки — `docs/screens/after-v5/light/`.

## 7. Ревью ветки — 1 октября 2026

Проверка `design...redesign-native` (только код редизайна; двадцать коммитов ядра
из `design` — вне её). Исправлено:

- «Темы коллекции» → «Удалить выбранные…» — вопрос висел на секции формы и не
  открывался: удалить отмеченные документы было нельзя. Вопрос — на кнопке.
- «Клиенты» → «Лимиты» → CORS: вопрос о `*` висел на `AdvancedSection` (это
  секция формы) — `*` молча пропадал. Вопрос — на поле.
- Лист нового ключа: «Настроить подключение агента» стирал ключ, и в блоке
  агента вместо него была заглушка, а «Прописать сервер в агента» — недоступна.
  Теперь ключ остаётся, пока открыто подключение агента этого ключа.
  «Скопировать ключ» / «Скопировать пример» отвечают «Скопировано» в самом листе:
  сообщение экрана скрыто под листом.
- Значок строки меню на AppKit: горячая клавиша и мост MCP поднимались только
  с главным окном (раньше — и с меню `MenuBarExtra`). Теперь — при запуске
  приложения; окно значка — запасной источник `openWindow`, если приложение
  запущено без окна.
- `LogView` следит за концом и по последней строке: буфер с пределом (вывод
  сервера — 1000 строк) перестаёт расти, и одно число строк слежение
  останавливало.
- Лист фильтра в «Для опытных» снова показывает и `where_document`, а не только
  `where`.

- Прокрутка к блоку «Подключение агента» — вернулась. Щелчок по
  заголовку, «Настроить подключение агента» из меню ключа и из листа нового
  ключа прокручивают форму к блоку. Сначала решил, что `ScrollViewReader` форму
  `.grouped` не прокручивает, — неверно: проба на отдельном приложении показала,
  что прокручивает и к строке за краем. Не работало время: прокрутка сразу
  после смены состояния (и даже по `onAppear` строки) приходит, пока секция
  ещё раскрывается, и ничего не делает. Теперь блок раскрывается своим
  состоянием через `withAnimation { … } completion:` (macOS 14), и прокрутка
  идёт по завершении анимации. Проверено в окне: заголовком и из контекстного
  меню (форма при этом заводится заново — путь через `onAppear`).

Проверено и не подтвердилось:

- `StepperRow`: число за пределом, которое после обрезки совпадает с прежним
  значением, в поле не остаётся. Проба — копия поля, значение 20 при пределе
  1…20: введено 777 → после Return и после Tab поле показывает 20. SwiftUI
  переписывает поле из привязки при каждом подтверждении. Код не менялся.

Второй проход ревью (1 октября 2026, вечер) — исправлено:

- Запуск: клавиша и мост MCP с прошлого прохода поднимались прямо в
  `applicationDidFinishLaunching`, а `startMenuBarSupport` заодно ставит
  политику Dock по тому, видно ли окно. Окна в этот момент ещё нет — у кого
  включено «Оставаться в строке меню», значок уходил бы из Dock на старте.
  Теперь — следующим ходом, как и размер первого окна.
- Окно значка как запасной `openWindow`: ставилось один раз («если пусто»), то
  есть от самого первого открытия, а окно значка строится заново каждый раз.
  Теперь обновляется при каждом открытии, но действия главного окна не
  перебивает.
- Лист ключа: при перевыпуске флаг «ключ отдан в форму» снимается новым
  ключом, а не заранее: не вышло перевыпустить — прежний лист не всплывает.
- «Модели → Замеры»: сохранённая часть «Строки из таблиц» при пустом списке
  таблиц подменяется коллекциями, а пикер оставался пустым — теперь он
  показывает то, что на экране.

Проверено и не подтвердилось: порядок «действие кнопки → обнуление состояния»
у подтверждений на `Binding(get:set:)` (тот же шаблон в старом коде работал);
цепочки из нескольких листов и вопросов на одном виде (были и раньше, до 11);
теги пикеров с опциональным выбором; типы `contextMenu(forSelectionType:)`;
Return на разрушительных кнопках; ключи и побочные действия настроек,
переехавших в окно «Настройки»; команды строки меню; обработчики появления
экранов и `onChange`.

## 8. Четвёртый проход (замечания без файла) — 3 октября 2026

- Ширина форм: предел ~700 pt по центру — поведение самой формы `.grouped`
  (проверено пробой на пустом окне ещё в пятом разделе). Оставлено; стандартный размер
  окна при первом открытии — 1100×760 вместо 1200×760, чтобы пустоты по бокам
  было меньше. Уже открывавшееся окно macOS восстанавливает в прежнем размере.
- «Коллекции → Обзор»: второй «Размер выборки, документов» (у тем, 10 000) —
  «Документов для поиска тем»; оценка качества тем — подписью под секцией
  «Темы», а не серой строкой в ней.
- «Диагностика → Замечено» — дата без года («17 авг., 0:34»), полностью — в
  подсказке и инспекторе.
- Инспектор источника — «≈ 512 токенов» вместо «512 ≈токенов».
- «Безопасность → На что стоит посмотреть»: обход ключей локальными
  программами — со значком предупреждения. Важность в ядре не менялась
  (`local-access` там — сведение, показывается всегда); значок выбирается в
  экране.

Полосы под таблицами — через строку, шаг 60 pt = две строки по 30: верно,
претензия v4/v5 снята.
- «Настройки → Источники → Умолчания нарезки» показывали строку ядра
  (`summaryText`: «база 512 ≈токенов») — теперь та же построчная разметка, что
  в инспекторе источника, одной строкой («база ≈ 512 токенов · …»).
  Построчное описание вынесено в `ChunkingConfiguration.parameterRows`
  (Views/ViewHelpers.swift); `summaryText` ядра остался для журнала событий.

Окончательные снимки — `docs/screens/final/light/` (окно 1100×760, 37 штук:
все разделы и вкладки, шесть вкладок «Настроек», окно значка в строке меню).

## 9. Полный проход (v6) — 4 октября 2026

**A. Системное.**
- A1 — горизонтальная полоса в «Моделях», «Наборе запросов», «Прогонах»,
  «Логи → Доступ» давали **сохранённые ширины** колонок прошлых раскладок:
  ключи всех таблиц сменены (`table.*.v2` → `.v3`, прогоны — `.v4`). Ширины в
  коде уже были по правилу (главная текстовая колонка без ширины). Проверено
  в окне при 1100 и 900 pt — полос нет.
- A2 — числа полем со стрелками: «Результатов» (Поиск), «Показывать план…»
  (что значит 0 — в подсказке), все дробные (`DecimalStepperRow` — теперь поле;
  единица — в подписи: «Таймаут, с», «Пауза между запросами, с»…), «Цель,
  знаков», «Не читать файлы больше, МБ», «Интервал, мин». Текстом со стрелками
  остались только значения словами, которые в поле не впишешь: «n_results × 3»,
  «не отбрасывать», «H2».
- A3 — окно при первом открытии 1100×720.
- A4 — «Подключено к …» больше не баннер над вкладками «Моделей» (это строка
  «Состояние» на «Подключении»; сообщение — в журнал). Баннер — ошибки и итог
  действий.
- A5 — предел кэша правится только в «Настройках → Хранение»; в «Кэше» —
  значение тем же счётом (ГБ = 1024³) и «Изменить в Настройках…», открывающая
  сразу эту вкладку.

**B. Реструктуризация.**
- B1 — вкладки «Обзор → Сервер» нет: строка процесса с «Перезапустить /
  Остановить… / Запустить» — в «Состояние → Сейчас» (вопрос об остановке — на
  кнопке). Сохранённый индекс 2 ведёт на «Состояние». `ServerView.swift` удалён.
- B2 — части прогонов («История / Отчёт / Разметка») — меню в тулбаре, как в
  «Замерах»; колонки истории: Название (пустое — дата), Дата, Набор, Запросов,
  Варианты (главная, без ширины).
- B3 — вариантов нет: пустое состояние на всю вкладку, без секции «Прогон».
- B4 — «Соответствие документов» показывается, только когда у схемы есть поля
  (или уже есть отчёт проверки).

**C. По экранам.**
- «Обзор»: свежая копия (до 7 дней) — строкой «Резервная копия» в «Сейчас»;
  в «Требует решения» — только старше недели или если копий нет.
- «Установка»: «Проверить заново» — значком в тулбаре (⌘R занят перезапуском
  сервера); путь к движку — моноширинным в одну строку; «Способ» — столбиком;
  «Открыть install.sh» — в подписи секции.
- «Управление данными»: переключатель — «Удалить и резервные копии»;
  моноширинным только путь; предупреждение одно — в подписи (про движок — там
  же).
- «Поиск»: пустое состояние «Введите запрос»; «Где искать: Только в этой
  коллекции / Во всех коллекциях / выбранные»; «История запросов» — в «⋯».
  **Не сделано:** результаты таблицей — у выдачи многострочный фрагмент,
  метаданные и действия, таблица их обрежет; `.defaultAction` у «Выполнить» —
  противоречит v4 (синяя кнопка в форме), ⌘↩ уже есть в меню «Коллекция».
- «Темы» — **ошибка данных исправлена в ядре**: `TopicClustering.parse`
  вырезает `<think>…</think>` и не принимает за описание рассуждение модели
  («The user wants…»), `plausibleSummary` проверяет и уже сохранённые отчёты
  при показе. «Экспорт отчёта о темах» — в «⋯»; повтор «Тем: N…» убран.
- «Набор запросов»: внизу — счёт, заметка набора — в «?».
- «Логи»: у «Следить за концом» есть `Label`; вид на macOS 14 — проверить там.
- «Настройки → Источники»: «Стратегия нового источника» — пикер; свои
  умолчания — секцией на стратегию, строка на параметр (как в инспекторе);
  «Забыть все умолчания…» — разрушительная, с вопросом.
- «Настройки → Хранение → Папка» — значок «Показать в Finder» в строке.
- Окно значка: высота по содержимому, результаты — списком своей высоты по мере
  поиска; первая строка — состояние сервера и счётчик задач, вторая — MCP.
  Своего фона у окна нет — серый цвет на снимке даёт материал `NSPopover`.

Снимки — `docs/screens/final/light/` (переснято при 1100×720, 36 штук).

## 10. Цвет кнопок — 4 октября 2026

Правило: **синий** — одно главное действие листа (срабатывает по Return);
**красный** — там, где принимается необратимое решение, а не там, где к нему
подводят. Стили — в `UI/Compat.swift`: `primaryButtonStyle()`,
`destructiveButtonStyle()` (красная заливка, без Return), `destructiveTextStyle()`.

- Синие: главные кнопки листов — как были. «Посчитать вектор» на «Стенде» —
  обычная (кнопка формы, v4).
- Красные (заливка): разрушительная главная кнопка листа — `SheetForm` с
  `isDestructive` («Удалить» коллекцию, «Сбросить» базу), «Пересчитать на
  месте», «Удалить из базы» в решениях источника (решение без вопроса после),
  экстренная остановка на «Безопасности» (тревожная кнопка).
- Красный текст: «Удалить все данные…» — самое разрушительное действие окна,
  ещё спросит подтверждение (кнопка в нём красная системно).
- Серые: кнопки, открывающие вопрос («Удалить профиль…», «Остановить…»
  сервер, «Забыть все умолчания…» и т. п.) — красная кнопка есть в самом
  вопросе. Пункты меню macOS красит сам.

Попутно — «Документы» при окне 1100: сохранённые ширины от окна 1200 давали
горизонтальную полосу. Колонка-значок «Пометка» → «Метка» (52 pt вместо 72),
«Фрагмент» с пределом 320 (иначе забирал всё место), минимумы ниже, ключ
`table.documents.v11`. При 1100 — без полосы, заголовки целиком. **При 900 с
открытым сайдбаром остаётся небольшая горизонтальная полоса**: таблица при
сужении окна ужимает не все колонки поровну, а подгонка минимумов дальше
делает 1100 хуже.
