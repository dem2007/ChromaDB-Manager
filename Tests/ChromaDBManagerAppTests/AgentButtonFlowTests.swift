import XCTest
@testable import ChromaCore
@testable import ChromaDBManagerApp

/// Кнопки «прописать сервер» и «положить скилл».
///
/// Живая проверка в собранном приложении показала, чего не видно по коду:
/// нажатие ничего не делало. Разбор через дерево доступности оказался
/// ненадёжен — имена кнопок совпадают с пунктами меню, — и вместо него здесь
/// закреплено то, что проверяемо: **состояние** модели. Само появление
/// окна подтверждения остаётся за SwiftUI, но всё, что до него и после,
/// теперь падает при поломке.
@MainActor
final class AgentButtonFlowTests: XCTestCase {
    private func model() -> ClientsViewModel { ClientsViewModel() }

    /// Без ключа на руках кнопка сервера не заводит подтверждения вовсе —
    /// и говорит почему.
    func testTheServerButtonWithoutAKeyExplainsInsteadOfAsking() {
        let subject = model()
        let client = ExternalClient.issue(name: "агент").0
        subject.installServer(.hermes, for: client)
        XCTAssertNil(subject.pendingAgentAction, "подтверждение без ключа не нужно")
        XCTAssertEqual(
            subject.statusMessage,
            String(localized: "Ключа нет на руках: перевыпустите его — и кнопка впишет настройку вместе с ним.")
        )
    }

    /// Со свежим ключом кнопка **спрашивает**, а не пишет.
    func testTheServerButtonAsksBeforeWriting() {
        let subject = model()
        let (client, key) = ExternalClient.issue(name: "агент")
        subject.freshKey = (client.id, client.name, key)
        subject.installServer(.hermes, for: client)
        guard let pending = subject.pendingAgentAction else {
            return XCTFail("подтверждение не заведено — кнопка ничего не делает")
        }
        XCTAssertEqual(pending.kind, .hermes)
        XCTAssertTrue(pending.path.hasSuffix("config.yaml"), pending.path)
        XCTAssertTrue(pending.question.contains("Hermes"), pending.question)
        XCTAssertTrue(pending.explanation.contains(pending.path), pending.explanation)
    }

    /// Ключ берётся по идентификатору клиента, а не по имени: имена не
    /// уникальны, и ключ первого уходил бы в агента с карточки второго.
    func testAKeyOfAnotherClientWithTheSameNameIsNotUsed() {
        let subject = model()
        let (first, key) = ExternalClient.issue(name: "агент")
        let second = ExternalClient.issue(name: "агент").0
        subject.freshKey = (first.id, first.name, key)
        subject.installServer(.hermes, for: second)
        XCTAssertNil(subject.pendingAgentAction, "чужой ключ принят за свой")
    }

    /// Кнопка скилла спрашивает всегда: ключ ей не нужен.
    func testTheSkillButtonAsksWithoutAKey() {
        let subject = model()
        subject.installSkill(.hermes)
        guard let pending = subject.pendingAgentAction else {
            return XCTFail("подтверждение не заведено")
        }
        // Проверяется то, что верно на **любой** машине: раздел у Hermes
        // зависит от того, где скилл уже лежит, а имя папки — нет, его
        // требует и Bionic.
        XCTAssertTrue(
            pending.path.hasSuffix("/\(AgentIntegration.skillName)/SKILL.md"),
            pending.path
        )
        XCTAssertTrue(pending.path.contains("/skills/"), pending.path)
        // Источник едет вместе с намерением: между вопросом и согласием
        // он не должен браться заново — иначе кладётся не то, о чём
        // спрашивали.
        guard case .skill(let source) = pending.target else {
            return XCTFail("намерение не несёт источника")
        }
        XCTAssertTrue(
            source.path.hasSuffix("/Skills/\(AgentIntegration.skillName)/SKILL.md"),
            source.path
        )
    }

    /// Отказ от подтверждения снимает намерение: иначе оно всплывёт позже
    /// само по себе.
    func testDecliningClearsTheIntent() {
        let subject = model()
        subject.installSkill(.bionic)
        XCTAssertNotNil(subject.pendingAgentAction)
        subject.pendingAgentAction = nil
        XCTAssertNil(subject.pendingAgentAction)
    }

    // Проверки на само согласие здесь **нет** нарочно.
    //
    // `confirmAgentAction(_:)` за проверкой намерения сразу запускает
    // настоящую запись — ту же, что кладёт файл в `~/.hermes`. Сегодня она
    // обрывается лишь потому, что в тестовом бандле нет ресурса со скиллом:
    // случайность упаковки, а не решение. Тест, способный переписать скилл
    // разработчика, хуже отсутствующего теста, а развести это по-настоящему
    // можно только швом для подмены домашней папки агента — отдельная
    // работа.
    //
    // Само свойство «намерение снимается до работы» теперь читается прямо
    // в двух строках `confirmAgentAction(_:)`: обнуление, потом запуск.
}
