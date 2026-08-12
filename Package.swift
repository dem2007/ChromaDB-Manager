// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChromaDBManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChromaDBManager", targets: ["ChromaDBManagerMain"]),
        // Вспомогательный файл MCP-сервера: его запускает агентское
        // приложение, а не человек, поэтому имя — как у команды, а не как
        // у программы с окном.
        .executable(name: "chromadb-mcp", targets: ["ChromaMCPHelper"]),
        .library(name: "ChromaCore", targets: ["ChromaCore"]),
    ],
    targets: [
        // Service layer: shell, HTTP, config, chunking. UI-free and unit-testable.
        .target(name: "ChromaCore", path: "Sources/ChromaCore"),
        // SwiftUI application: views + view models only.
        //
        // Библиотека, а не исполняемая цель: тестовый набор не может
        // импортировать исполняемую цель, и весь экранный слой оставался бы
        // непокрытым. Точка входа — в `ChromaDBManagerMain`, там одна
        // строка.
        .target(
            name: "ChromaDBManagerApp",
            dependencies: ["ChromaCore"],
            path: "Sources/ChromaDBManagerApp"
        ),
        .executableTarget(
            name: "ChromaDBManagerMain",
            dependencies: ["ChromaDBManagerApp"],
            path: "Sources/ChromaDBManagerMain"
        ),
        // Мост «агент ↔ приложение». Своей логики не имеет: инструменты, права
        // и доступ к базе живут в приложении, в одном экземпляре.
        .executableTarget(
            name: "ChromaMCPHelper",
            dependencies: ["ChromaCore"],
            path: "Sources/ChromaMCPHelper"
        ),
        .testTarget(
            name: "ChromaCoreTests",
            dependencies: ["ChromaCore"],
            path: "Tests/ChromaCoreTests",
            // Responses recorded from a live server; tests never hit the network.
            resources: [.copy("Fixtures")]
        ),
        // Слой экранов: модели экранов и их решения. Вьюхи как
        // таковые тестами не покрываются — там разметка, а не решения.
        .testTarget(
            name: "ChromaDBManagerAppTests",
            dependencies: ["ChromaDBManagerApp"],
            path: "Tests/ChromaDBManagerAppTests"
        ),
    ]
)
