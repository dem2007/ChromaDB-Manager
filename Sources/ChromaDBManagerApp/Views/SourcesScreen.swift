import SwiftUI
import ChromaCore

/// Экран «Источники».
///
/// Раньше источники жили внутри «Эмбеддингов» — вместе с подключением к
/// LM Studio и выбором модели. Это два разных вопроса: «чем считать векторы»
/// и «что именно индексировать», и первый решают один раз, а второй — каждый
/// день. Теперь у каждого свой экран, а три разреза источников стали
/// вкладками одной темы.
///
/// Сам экран ничего не делает: он раскладывает уже существующие части по
/// вкладкам. Логика синхронизации, диагностики и стенда не изменилась ни на
/// строку — переехало только место, где на них смотрят.
struct SourcesScreen: View {
    @ObservedObject var model: SourcesViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator
    /// Разрез экрана: «Источники», «Диагностика», «Стенд».
    var tab: Int = 0
    /// Перейти на другую вкладку этого же экрана. Нужен карточке
    /// находок: диагностика — соседняя вкладка, и открывать поверх неё лист
    /// с тем же содержимым значило показывать одно и то же двумя способами.
    var openTab: (Int) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                switch tab {
                case 1:
                    DiagnosticsSection(model: model)
                case 2:
                    TestBenchSection(embeddings: embeddings)
                default:
                    SourcesSection(
                        model: model, embeddings: embeddings,
                        autoSync: autoSync, openDiagnostics: { openTab(1) }
                    )
                }
            }
            .padding(.top, 8)
            .pageContentPadding()
        }
    }
}
