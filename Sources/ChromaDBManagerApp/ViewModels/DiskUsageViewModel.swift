import Foundation
import ChromaCore

/// «Место на диске» на экране «Состояние».
///
/// Живёт дольше экрана: обход копий в десятки гигабайт — секунды, и
/// пересчитывать их на каждом возвращении на вкладку значило бы показывать
/// «считается…» вместо чисел. Пересчёт — по кнопке и после того, что меняет
/// объём: копии, корзины, кэша.
@MainActor
final class DiskUsageViewModel: ObservableObject {
    @Published private(set) var report: DiskUsageReport?
    @Published private(set) var isMeasuring = false
    private var pending = false

    /// Считает, если ещё не считали.
    func measureIfNeeded(_ app: AppEnvironment) {
        guard report == nil else { return }
        measure(app)
    }

    /// Просьба посреди подсчёта не теряется: копия, сделанная в эту секунду,
    /// должна попасть в числа, а не ждать следующего нажатия.
    func measure(_ app: AppEnvironment) {
        guard !isMeasuring else {
            pending = true
            return
        }
        isMeasuring = true
        // Та же папка, что копируют резервные копии: у сервера, которым
        // приложение управляет само, база тоже лежит здесь, на этом диске.
        let database = EnvironmentViewModel.databaseFolder(app)
        Task {
            let measured = await Task.detached(priority: .utility) {
                DiskUsage.measure(databaseURL: database)
            }.value
            report = measured
            isMeasuring = false
            if pending {
                pending = false
                measure(app)
            }
        }
    }
}
