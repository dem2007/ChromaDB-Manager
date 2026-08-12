import XCTest
@testable import ChromaCore

private func sampleConfiguration() -> AppConfiguration {
    var configuration = AppConfiguration()
    configuration.lmStudioBaseURL = "http://localhost:4321"
    configuration.defaultEmbeddingModel = "model-a"
    configuration.syncPreviewThresholdFiles = 7
    configuration.trashRetentionDays = 21
    configuration.serverProfiles = [
        ServerProfile(name: "рабочий", kind: .external, host: "10.0.0.5", port: 8000),
    ]
    configuration.dataSources = [
        DataSource(name: "docs", path: "/tmp/does-not-exist-docs", collectionName: "docs_col"),
    ]
    let (client, _) = ExternalClient.issue(name: "агент")
    configuration.externalClients = [client]
    return configuration
}

// MARK: - Rule 7: what must never be in the file

final class SettingsExportSecrecyTests: XCTestCase {
    /// The whole point of the feature, stated as a test: the exported bytes must
    /// not contain the key, its hash, or its recognisable prefix.
    func testNoKeyMaterialSurvivesTheExport() throws {
        var configuration = sampleConfiguration()
        let (client, key) = ExternalClient.issue(name: "агент")
        configuration.externalClients = [client]

        let bundle = SettingsTransfer.export(
            configuration: configuration, schemas: [:], savedFilters: [], appVersion: "1.0"
        )
        let text = try String(data: SettingsTransfer.encode(bundle), encoding: .utf8) ?? ""

        XCTAssertFalse(text.contains(key), "сам ключ в файле недопустим")
        XCTAssertFalse(text.contains(client.keyHash), "хэш ключа — это проверочное значение секрета, ему в файле тоже не место")
        XCTAssertFalse(text.contains(client.keyPrefix), "по префиксу ключ узнаётся")
        XCTAssertTrue(text.contains("агент"), "но сам клиент переносится — иначе права придётся настраивать заново")
    }

    /// A client without a key is already a solved problem in this app: it is
    /// exactly what the emergency stop leaves behind, and the access controller
    /// skips it.
    func testAnImportedClientCanAuthenticateNothing() {
        let configuration = sampleConfiguration()
        let bundle = SettingsTransfer.export(
            configuration: configuration, schemas: [:], savedFilters: [], appVersion: "1.0"
        )
        let imported = try! XCTUnwrap(bundle.clients.first)
        XCTAssertTrue(imported.isRevoked)
        XCTAssertFalse(imported.isEnabled)
        XCTAssertEqual(imported.permissions, configuration.externalClients[0].permissions)
    }

    func testTheLastSeenTimeOfAnotherMachineIsNotCarriedOver() {
        var configuration = sampleConfiguration()
        configuration.externalClients[0].lastSeenAt = Date()
        let bundle = SettingsTransfer.export(
            configuration: configuration, schemas: [:], savedFilters: [], appVersion: "1.0"
        )
        XCTAssertNil(bundle.clients.first?.lastSeenAt)
    }
}

// MARK: - What travels and what stays

final class TransferablePreferencesTests: XCTestCase {
    /// A file must not be able to open the app to the network. Everything about
    /// exposure fails closed, and an import is not an exception.
    func testExposureIsNotCarriedByTheFile() {
        var exporting = AppConfiguration()
        exporting.proxyExposure = .allInterfaces

        var importing = AppConfiguration()
        importing.proxyExposure = .loopback
        TransferablePreferences(from: exporting).apply(to: &importing)

        XCTAssertEqual(importing.proxyExposure, .loopback, "экспозиция прокси из файла не приходит")
    }

    /// Both of these are consents given in person: one reaches the network, the
    /// other holds a macOS permission.
    func testConsentsAreNotCarriedByTheFile() {
        var exporting = AppConfiguration()
        exporting.checkUpdatesAutomatically = true
        exporting.notificationsEnabled = true

        var importing = AppConfiguration()
        TransferablePreferences(from: exporting).apply(to: &importing)

        XCTAssertFalse(importing.checkUpdatesAutomatically)
        XCTAssertFalse(importing.notificationsEnabled)
    }

    /// Importing where the other machine was connected would disconnect this
    /// one from its own database.
    func testTheCurrentConnectionIsNotCarriedByTheFile() {
        var exporting = AppConfiguration()
        exporting.mode = .server
        exporting.localDatabasePath = "/Volumes/other/chroma"
        exporting.selectedProfileID = UUID()

        var importing = AppConfiguration()
        importing.mode = .localDatabase
        importing.localDatabasePath = "/mine/chroma"
        let mine = importing.selectedProfileID
        TransferablePreferences(from: exporting).apply(to: &importing)

        XCTAssertEqual(importing.mode, .localDatabase)
        XCTAssertEqual(importing.localDatabasePath, "/mine/chroma")
        XCTAssertEqual(importing.selectedProfileID, mine)
    }

    func testTheOrdinaryPreferencesDoTravel() {
        let exporting = sampleConfiguration()
        var importing = AppConfiguration()
        TransferablePreferences(from: exporting).apply(to: &importing)

        XCTAssertEqual(importing.lmStudioBaseURL, "http://localhost:4321")
        XCTAssertEqual(importing.defaultEmbeddingModel, "model-a")
        XCTAssertEqual(importing.syncPreviewThresholdFiles, 7)
        XCTAssertEqual(importing.trashRetentionDays, 21)
    }
}

// MARK: - The plan shown before anything is written

final class SettingsImportPlanTests: XCTestCase {
    private func bundle(from configuration: AppConfiguration) -> SettingsBundle {
        SettingsTransfer.export(
            configuration: configuration, schemas: [:], savedFilters: [], appVersion: "1.0"
        )
    }

    func testEverythingIsNewOnAnEmptyMachine() {
        let plan = SettingsTransfer.plan(
            for: bundle(from: sampleConfiguration()),
            configuration: AppConfiguration(),
            schemas: [:],
            savedFilters: [],
            folderExists: { _ in true }
        )
        XCTAssertEqual(plan.profiles, SettingsImportPlan.Category(added: 1, replaced: 0))
        XCTAssertEqual(plan.sources, SettingsImportPlan.Category(added: 1, replaced: 0))
        XCTAssertEqual(plan.clients, SettingsImportPlan.Category(added: 1, replaced: 0))
        XCTAssertFalse(plan.replacesAnything)
    }

    func testReimportingOntoItselfReplacesRatherThanDuplicates() {
        let configuration = sampleConfiguration()
        let plan = SettingsTransfer.plan(
            for: bundle(from: configuration),
            configuration: configuration,
            schemas: [:],
            savedFilters: [],
            folderExists: { _ in true }
        )
        XCTAssertEqual(plan.profiles, SettingsImportPlan.Category(added: 0, replaced: 1))
        XCTAssertEqual(plan.sources, SettingsImportPlan.Category(added: 0, replaced: 1))
        XCTAssertTrue(plan.replacesAnything)
    }

    /// A source pointing at nothing looks like a source that works — right up
    /// to the first sync that finds no files.
    func testAFolderThatDoesNotExistHereIsNamed() {
        let plan = SettingsTransfer.plan(
            for: bundle(from: sampleConfiguration()),
            configuration: AppConfiguration(),
            schemas: [:],
            savedFilters: [],
            folderExists: { $0 != "/tmp/does-not-exist-docs" }
        )
        XCTAssertEqual(plan.missingFolders, ["/tmp/does-not-exist-docs"])
    }

    func testWhatWillNeedItsSecretsAgainIsListed() {
        let plan = SettingsTransfer.plan(
            for: bundle(from: sampleConfiguration()),
            configuration: AppConfiguration(),
            schemas: [:],
            savedFilters: [],
            hasToken: { _ in false },
            folderExists: { _ in true }
        )
        XCTAssertEqual(plan.profilesNeedingToken, ["рабочий"])
        XCTAssertEqual(plan.clientsNeedingKey, ["агент"])
    }

    /// A client that keeps its local key is not waiting for a new one, and the
    /// plan must not claim otherwise.
    func testAClientThatKeepsItsLocalKeyIsNotListedAsNeedingOne() {
        let configuration = sampleConfiguration()
        let plan = SettingsTransfer.plan(
            for: bundle(from: configuration),
            configuration: configuration,
            schemas: [:],
            savedFilters: [],
            folderExists: { _ in true }
        )
        XCTAssertTrue(plan.clientsNeedingKey.isEmpty)
    }

    func testAProfileWhoseTokenIsAlreadyInThisKeychainIsNotListed() {
        let plan = SettingsTransfer.plan(
            for: bundle(from: sampleConfiguration()),
            configuration: AppConfiguration(),
            schemas: [:],
            savedFilters: [],
            hasToken: { _ in true },
            folderExists: { _ in true }
        )
        XCTAssertTrue(plan.profilesNeedingToken.isEmpty)
    }
}

// MARK: - Applying

final class SettingsImportApplyTests: XCTestCase {
    func testImportAddsWithoutRemovingWhatIsAlreadyHere() {
        var mine = AppConfiguration()
        mine.dataSources = [DataSource(name: "моё", path: "/mine", collectionName: "mine_col")]
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []

        let theirs = SettingsTransfer.export(
            configuration: sampleConfiguration(), schemas: [:], savedFilters: [], appVersion: "1.0"
        )
        SettingsTransfer.apply(theirs, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: false)

        XCTAssertEqual(mine.dataSources.count, 2, "импорт добавляет к своему, а не вместо него")
        XCTAssertTrue(mine.dataSources.contains { $0.name == "моё" })
        XCTAssertTrue(mine.dataSources.contains { $0.name == "docs" })
    }

    func testPreferencesAreOnlyTouchedWhenAsked() {
        var mine = AppConfiguration()
        mine.lmStudioBaseURL = "http://localhost:1234"
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []

        let theirs = SettingsTransfer.export(
            configuration: sampleConfiguration(), schemas: [:], savedFilters: [], appVersion: "1.0"
        )
        SettingsTransfer.apply(theirs, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: false)
        XCTAssertEqual(mine.lmStudioBaseURL, "http://localhost:1234")

        SettingsTransfer.apply(theirs, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: true)
        XCTAssertEqual(mine.lmStudioBaseURL, "http://localhost:4321")
    }

    func testTheSameFileImportedTwiceChangesNothingTheSecondTime() {
        var mine = AppConfiguration()
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        let theirs = SettingsTransfer.export(
            configuration: sampleConfiguration(), schemas: [:], savedFilters: [], appVersion: "1.0"
        )

        SettingsTransfer.apply(theirs, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: true)
        let afterFirst = mine.dataSources.count
        SettingsTransfer.apply(theirs, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: true)

        XCTAssertEqual(mine.dataSources.count, afterFirst, "повторный импорт не размножает источники")
        XCTAssertEqual(mine.serverProfiles.count, 1)
        XCTAssertEqual(mine.externalClients.count, 1)
    }

    /// Found by re-importing an export onto the machine that produced it: every
    /// client in the file is keyless, so a plain merge revoked a key that was
    /// working. The key belongs to the machine it was issued on and never
    /// travelled, so an import has no business clearing it.
    func testReimportingOnTheSameMachineKeepsAWorkingKey() {
        var mine = AppConfiguration()
        let (client, _) = ExternalClient.issue(name: "агент")
        mine.externalClients = [client]

        let file = SettingsTransfer.export(
            configuration: mine, schemas: [:], savedFilters: [], appVersion: "1.0"
        )
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        SettingsTransfer.apply(file, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: false)

        let after = try! XCTUnwrap(mine.externalClients.first)
        XCTAssertEqual(after.keyHash, client.keyHash, "ключ этой машины остаётся при ней")
        XCTAssertEqual(after.keyPrefix, client.keyPrefix)
        XCTAssertFalse(after.isRevoked)
        XCTAssertTrue(after.isEnabled)
    }

    /// The other side of the same rule: on a machine that never had this
    /// client, it arrives with no key and can authenticate nothing.
    func testTheSameClientOnAFreshMachineArrivesWithoutAKey() {
        var theirs = AppConfiguration()
        let (client, _) = ExternalClient.issue(name: "агент")
        theirs.externalClients = [client]
        let file = SettingsTransfer.export(
            configuration: theirs, schemas: [:], savedFilters: [], appVersion: "1.0"
        )

        var mine = AppConfiguration()
        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        SettingsTransfer.apply(file, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: false)

        XCTAssertTrue(try! XCTUnwrap(mine.externalClients.first).isRevoked)
    }

    /// Permissions are what an import is for, so they do come from the file
    /// even when the key stays local.
    func testPermissionsStillComeFromTheFile() {
        var mine = AppConfiguration()
        let (client, _) = ExternalClient.issue(name: "агент")
        mine.externalClients = [client]

        var edited = mine
        edited.externalClients[0].name = "агент, переименованный"
        let file = SettingsTransfer.export(
            configuration: edited, schemas: [:], savedFilters: [], appVersion: "1.0"
        )

        var schemas: [String: MetadataSchema] = [:]
        var filters: [SavedFilter] = []
        SettingsTransfer.apply(file, to: &mine, schemas: &schemas, savedFilters: &filters, includePreferences: false)

        XCTAssertEqual(mine.externalClients.first?.name, "агент, переименованный")
        XCTAssertFalse(try! XCTUnwrap(mine.externalClients.first).isRevoked)
    }
}

// MARK: - The file itself

final class SettingsBundleCodingTests: XCTestCase {
    func testABundleSurvivesARoundTrip() throws {
        let original = SettingsTransfer.export(
            configuration: sampleConfiguration(), schemas: [:], savedFilters: [], appVersion: "1.2.3"
        )
        let restored = try SettingsTransfer.decode(try SettingsTransfer.encode(original))

        XCTAssertEqual(restored.schemaVersion, SettingsBundle.currentSchemaVersion)
        XCTAssertEqual(restored.appVersion, "1.2.3")
        XCTAssertEqual(restored.preferences, original.preferences)
        XCTAssertEqual(restored.sources.map(\.name), ["docs"])
    }

    /// Half the settings of a newer build is worse than none of them, because
    /// the half that arrived looks complete.
    func testAFileFromANewerBuildIsRefusedWholeRatherThanReadInPart() throws {
        var bundle = SettingsTransfer.export(
            configuration: sampleConfiguration(), schemas: [:], savedFilters: [], appVersion: "9.0"
        )
        bundle.schemaVersion = SettingsBundle.currentSchemaVersion + 1
        let data = try SettingsTransfer.encode(bundle)

        XCTAssertThrowsError(try SettingsTransfer.decode(data)) { error in
            XCTAssertEqual(
                error as? SettingsTransferError,
                .newerSchema(found: SettingsBundle.currentSchemaVersion + 1,
                             supported: SettingsBundle.currentSchemaVersion)
            )
        }
    }

    func testSomethingThatIsNotABundleIsRefusedWithAnExplanation() {
        let data = Data(#"{"hello": "world"}"#.utf8)
        XCTAssertThrowsError(try SettingsTransfer.decode(data)) { error in
            guard case .unreadable = error as? SettingsTransferError else {
                return XCTFail("ожидалась ошибка чтения, получено \(error)")
            }
        }
    }
}
