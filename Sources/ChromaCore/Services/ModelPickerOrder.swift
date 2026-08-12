import Foundation

/// Порядок моделей в выпадающих списках, где нужен не любой тип.
///
/// **Почему порядок, а не фильтр.** До этого список для LLM-чанкинга показывал
/// только `.chat`, и модель, тип которой определён неверно, из него просто
/// исчезала — вместе со всякой возможностью её выбрать и исправить положение.
/// Сортировка решает ту же задачу («нужное сверху»), не отнимая доступа
/// к остальному.
public enum ModelPickerOrder {
    /// Нужный тип впереди, дальше — по убыванию правдоподобия.
    ///
    /// `.chat` и `.reranking` идут вместе вторым эшелоном: обе порождающие,
    /// и человек, ошибшийся типом, найдёт свою модель сразу под нужными.
    /// `.embedding` — последними: для полей, где нужна порождающая модель,
    /// они подходят меньше всего, но и прятать их незачем.
    public static func rank(_ kind: LMStudioModelKind, preferring preferred: LMStudioModelKind) -> Int {
        if kind == preferred { return 0 }
        switch kind {
        case .chat, .reranking: return 1
        case .unknown: return 2
        case .embedding: return 3
        }
    }

    public static func sorted(
        _ models: [LMStudioModel], preferring preferred: LMStudioModelKind
    ) -> [LMStudioModel] {
        models.sorted { (rank($0.kind, preferring: preferred), $0.id) < (rank($1.kind, preferring: preferred), $1.id) }
    }

    /// Порядок в таблице «Модели»: это перечень установленного, а не выбор
    /// под задачу, поэтому группируется по типу — эмбеддинги, переранжировщики,
    /// остальное.
    public static func tableSorted(_ models: [LMStudioModel]) -> [LMStudioModel] {
        func rank(_ kind: LMStudioModelKind) -> Int {
            switch kind {
            case .embedding: return 0
            case .reranking: return 1
            default: return 2
            }
        }
        return models.sorted { (rank($0.kind), $0.id) < (rank($1.kind), $1.id) }
    }
}
