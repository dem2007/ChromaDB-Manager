import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

///, — когда экран предлагает перезагрузить модель.
///
/// Три условия, и каждое в одиночку отключает кнопку. Ошибись в любом — кнопка
/// либо не появится никогда, либо появится там, где грузить нечего; узнал бы об
/// этом человек, а не сборка.
@MainActor
final class ModelReloadGateTests: XCTestCase {
    /// Модель экрана с заведомо ненайденным `lms`: так проверяется условие
    /// «без CLI кнопки нет», не завися от того, что стоит на машине сборки.
    private func modelWithoutCLI() -> EmbeddingsViewModel {
        let viewModel = EmbeddingsViewModel()
        viewModel.loader = LMStudioLoader(paths: ["/нет/такого/lms"])
        return viewModel
    }

    private func modelWithCLI() throws -> (EmbeddingsViewModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("lms")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let viewModel = EmbeddingsViewModel()
        viewModel.loader = LMStudioLoader(paths: [executable.path])
        return (viewModel, directory)
    }

    private var loadedBelowCeiling: LMStudioModel {
        LMStudioModel(id: "liquid/lfm2-24b-a2b", kind: .chat,
                      contextLength: 128_000, loadedContextLength: 8192)
    }

    func testTheButtonAppearsForAModelLoadedBelowItsCeiling() throws {
        let (viewModel, directory) = try modelWithCLI()
        defer { try? FileManager.default.removeItem(at: directory) }

        let range = viewModel.reloadableContext(loadedBelowCeiling)
        XCTAssertEqual(range?.from, 8192)
        XCTAssertEqual(range?.to, 128_000)
    }

    /// Кнопка без `lms` — обещание, которого приложение не выполнит.
    func testWithoutTheCLIThereIsNoButton() {
        XCTAssertNil(modelWithoutCLI().reloadableContext(loadedBelowCeiling))
    }

    /// Модель на своём потолке перезагружать незачем: именно так выглядит
    /// экземпляр «…:2», созданный прошлой попыткой.
    func testAModelAtItsCeilingIsNotOffered() throws {
        let (viewModel, directory) = try modelWithCLI()
        defer { try? FileManager.default.removeItem(at: directory) }

        let atCeiling = LMStudioModel(id: "liquid/lfm2-24b-a2b:2", kind: .chat,
                                      contextLength: 128_000, loadedContextLength: 128_000)
        XCTAssertNil(viewModel.reloadableContext(atCeiling))
    }

    /// Незагруженная модель тоже не предлагается: перезагружать нечего.
    func testAModelThatIsNotLoadedIsNotOffered() throws {
        let (viewModel, directory) = try modelWithCLI()
        defer { try? FileManager.default.removeItem(at: directory) }

        let idle = LMStudioModel(id: "microsoft/phi-4", kind: .chat, contextLength: 131_072)
        XCTAssertNil(viewModel.reloadableContext(idle))
    }

    /// Ничего не грузится, пока не попросили.
    ///
    /// Обратная ветка — «пока грузится одна, вторую не предлагать» — тестом
    /// не покрыта: состояние живёт ровно столько, сколько идёт чужая команда,
    /// и ловить его пришлось бы таймингом. Это единственное непроверенное
    /// условие из четырёх.
    func testNothingIsLoadingUntilAsked() throws {
        let (viewModel, directory) = try modelWithCLI()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(viewModel.loadingModel)
        XCTAssertNotNil(viewModel.reloadableContext(loadedBelowCeiling))
    }

    // MARK: - Подтверждение

    /// Нажатие ставит подтверждение — то самое, которое до не
    /// показывалось никогда, потому что рядом стоял второй `.alert`.
    func testPressingTheButtonAsksFirst() throws {
        let (viewModel, directory) = try modelWithCLI()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(viewModel.pendingAction)
        viewModel.requestLoad(loadedBelowCeiling)

        guard case .load(let model, let from, let to)? = viewModel.pendingAction else {
            return XCTFail("ожидалось подтверждение загрузки, получено \(String(describing: viewModel.pendingAction))")
        }
        XCTAssertEqual(model, "liquid/lfm2-24b-a2b")
        XCTAssertEqual(from, 8192)
        XCTAssertEqual(to, 128_000)
    }

    /// А там, где кнопки нет, ничего не спрашивается и подавно.
    func testAModelWithNothingToDoAsksNothing() {
        let viewModel = modelWithoutCLI()
        viewModel.requestLoad(loadedBelowCeiling)
        XCTAssertNil(viewModel.pendingAction)
    }

    /// Два повода подтверждения — одно свойство: `.alert` на виде может быть
    /// только один, и разводить их по разным свойствам значит вернуть.
    func testTheTwoConfirmationsShareOneProperty() throws {
        let (viewModel, directory) = try modelWithCLI()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.requestLoad(loadedBelowCeiling)
        XCTAssertNotNil(viewModel.pendingAction)
        viewModel.cancelPendingAction()
        XCTAssertNil(viewModel.pendingAction)
    }
}
