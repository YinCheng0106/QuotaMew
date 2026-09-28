import Darwin
import Foundation
import XCTest
@testable import QuotaMew

final class CodexExecutableLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "CodexExecutableLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testDefaultChatGPTApplicationLocationsAreSystemThenUserApplications() {
        let candidates = CodexExecutableLocator.defaultChatGPTApplicationURLs(homeDirectory: root)

        XCTAssertEqual(candidates, [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            root.appending(path: "Applications/ChatGPT.app", directoryHint: .isDirectory)
        ])
    }

    func testDefaultApplicationLocationsAreSystemThenUserApplications() {
        let candidates = CodexExecutableLocator.defaultApplicationURLs(homeDirectory: root)

        XCTAssertEqual(candidates, [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            root.appending(path: "Applications/Codex.app", directoryHint: .isDirectory)
        ])
    }

    func testChatGPTAppHasHighestPriority() throws {
        let chatGPTApp = try makeDesktopApp(
            at: root.appending(path: "Applications/ChatGPT.app"), name: "ChatGPT"
        )
        let systemApp = try makeCodexApp(at: root.appending(path: "Applications/Codex.app"))
        let standalone = try makeExecutable(at: root.appending(path: "bin/codex"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [chatGPTApp], applicationURLs: [systemApp],
            standaloneURLs: [standalone]
        )

        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: chatGPTApp)))
    }

    func testPackagedChatGPTRuntimePrecedesLegacyAndStandalone() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        let packaged = try makePackagedRuntime(in: app)
        let standalone = try makeExecutable(at: root.appending(path: "bin/codex"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [app], applicationURLs: [], standaloneURLs: [standalone]
        )

        XCTAssertEqual(locator.locate(), resolved(packaged))
        XCTAssertEqual(locator.diagnosticSnapshot().runtimeSource, .chatGPTApplication)
    }

    func testValidManifestEntrypointIsUsedBeforeKnownPackagedPath() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        _ = try makePackagedRuntime(in: app, entrypoint: "bin/custom-codex")
        let known = try makeExecutable(at: package(in: app).appending(path: "bin/codex"))
        let locator = makeLocator(chatGPTApplicationURLs: [app], applicationURLs: [])

        XCTAssertEqual(locator.locate(), resolved(package(in: app).appending(path: "bin/custom-codex")))
        XCTAssertNotEqual(locator.locate(), resolved(known))
    }

    func testMalformedAndUnsupportedManifestsUseKnownPackagedFallback() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        let known = try makePackagedRuntime(in: app)
        let manifest = package(in: app).appending(path: "codex-package.json")
        let locator = makeLocator(chatGPTApplicationURLs: [app], applicationURLs: [])

        try Data("{".utf8).write(to: manifest)
        XCTAssertEqual(locator.locate(), resolved(known))

        try writeManifest(in: app, entrypoint: "bin/codex", layoutVersion: 2)
        XCTAssertEqual(locator.locate(), resolved(known))

        try Data(repeating: 0x20, count: 4_097).write(to: manifest)
        XCTAssertEqual(locator.locate(), resolved(known))
    }

    func testManifestCannotUseAbsoluteOrTraversalEntrypoint() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        let known = try makePackagedRuntime(in: app)
        let outside = try makeExecutable(at: root.appending(path: "outside/codex"))
        let locator = makeLocator(chatGPTApplicationURLs: [app], applicationURLs: [])

        try writeManifest(in: app, entrypoint: outside.path)
        XCTAssertEqual(locator.locate(), resolved(known))

        try writeManifest(in: app, entrypoint: "../../../../../../outside/codex")
        XCTAssertEqual(locator.locate(), resolved(known))
    }

    func testManifestSymlinkCannotEscapePackageRoot() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        let known = try makePackagedRuntime(in: app)
        let outside = try makeExecutable(at: root.appending(path: "outside/codex"))
        let link = package(in: app).appending(path: "bin/escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try writeManifest(in: app, entrypoint: "bin/escape")

        XCTAssertEqual(
            makeLocator(chatGPTApplicationURLs: [app], applicationURLs: []).locate(),
            resolved(known)
        )
    }

    func testNonExecutablePackagedRuntimeIsRejectedAndReported() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        try FileManager.default.removeItem(at: bundledExecutable(in: app))
        _ = try makePackagedRuntime(in: app, permissions: 0o644)
        let locator = makeLocator(chatGPTApplicationURLs: [app], applicationURLs: [])

        XCTAssertNil(locator.locate())
        let diagnostics = locator.diagnosticSnapshot()
        XCTAssertTrue(diagnostics.chatGPTApplication.isDetected)
        XCTAssertFalse(diagnostics.runtimeDetected)
        XCTAssertEqual(diagnostics.failureCategory, .runtimeNotExecutable)
    }

    func testCachedLegacyRuntimeTransitionsToPackagedRuntimeAfterDesktopUpdate() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        let locator = makeLocator(chatGPTApplicationURLs: [app], applicationURLs: [])
        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: app)))

        try FileManager.default.removeItem(at: bundledExecutable(in: app))
        let packaged = try makePackagedRuntime(in: app)
        XCTAssertEqual(locator.locate(), resolved(packaged))
    }

    func testNSWorkspaceFindsPackagedRuntimeAtNonstandardLocation() throws {
        let app = try makeDesktopApp(at: root.appending(path: "Elsewhere/ChatGPT.app"), name: "ChatGPT")
        try FileManager.default.removeItem(at: bundledExecutable(in: app))
        let packaged = try makePackagedRuntime(in: app)
        let lookup = LookupStub(result: app)
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], workspaceLookup: lookup.call
        )

        XCTAssertEqual(locator.locate(), resolved(packaged))
        XCTAssertEqual(locator.diagnosticSnapshot().runtimeSource, .chatGPTApplication)
    }

    func testRejectsPackagedRuntimeWithUntrustedWritableAncestry() throws {
        let app = try makeDesktopApp(at: root.appending(path: "ChatGPT.app"), name: "ChatGPT")
        try FileManager.default.removeItem(at: bundledExecutable(in: app))
        _ = try makePackagedRuntime(in: app)
        let bin = package(in: app).appending(path: "bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: bin.path)

        XCTAssertNil(makeLocator(chatGPTApplicationURLs: [app], applicationURLs: []).locate())
    }

    func testDiagnosticSnapshotReportsChatGPTWithoutExposingItsPath() throws {
        let chatGPTApp = try makeDesktopApp(
            at: root.appending(path: "Private User Folder/ChatGPT.app"),
            name: "ChatGPT",
            version: "26.818.1"
        )
        let locator = makeLocator(
            chatGPTApplicationURLs: [chatGPTApp],
            applicationURLs: []
        )

        let diagnostics = locator.diagnosticSnapshot()

        XCTAssertTrue(diagnostics.chatGPTApplication.isDetected)
        XCTAssertEqual(diagnostics.chatGPTApplication.version, DiagnosticVersion("26.818.1"))
        XCTAssertEqual(diagnostics.runtimeSource, .chatGPTApplication)
        XCTAssertTrue(diagnostics.runtimeDetected)
        XCTAssertNil(diagnostics.failureCategory)
    }

    func testDiagnosticSnapshotDistinguishesInstalledAppFromMissingRuntime() throws {
        let chatGPTApp = try makeDesktopApp(
            at: root.appending(path: "Applications/ChatGPT.app"),
            name: "ChatGPT",
            executablePermissions: 0o644
        )
        let locator = makeLocator(
            chatGPTApplicationURLs: [chatGPTApp],
            applicationURLs: []
        )

        let diagnostics = locator.diagnosticSnapshot()

        XCTAssertTrue(diagnostics.chatGPTApplication.isDetected)
        XCTAssertFalse(diagnostics.runtimeDetected)
        XCTAssertEqual(diagnostics.runtimeSource, .notDetected)
        XCTAssertEqual(diagnostics.failureCategory, .runtimeNotExecutable)
    }

    func testNSWorkspaceDiscoveredChatGPTAppPrecedesLegacyCodexAndStandalone() throws {
        let workspaceApp = try makeDesktopApp(
            at: root.appending(path: "Elsewhere/ChatGPT.app"), name: "ChatGPT"
        )
        let legacyApp = try makeCodexApp(at: root.appending(path: "Applications/Codex.app"))
        let standalone = try makeExecutable(at: root.appending(path: "bin/codex"))
        let lookup = LookupStub(result: workspaceApp)
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [legacyApp],
            workspaceLookup: lookup.call,
            standaloneURLs: [standalone]
        )

        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: workspaceApp)))
        XCTAssertEqual(lookup.identifiers, [CodexExecutableLocator.chatGPTBundleIdentifier])
    }

    func testLegacyCodexAppIsUsedWhenChatGPTIsUnavailable() throws {
        let workspaceApp = try makeCodexApp(at: root.appending(path: "Custom/Codex.app"))
        let standalone = try makeExecutable(at: root.appending(path: "bin/codex"))
        let lookup = LookupStub(result: workspaceApp)
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], workspaceLookup: lookup.call,
            standaloneURLs: [standalone]
        )

        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: workspaceApp)))
        XCTAssertEqual(lookup.identifiers, [CodexExecutableLocator.chatGPTBundleIdentifier])
    }

    func testStandaloneCLIIsUsedWhenNoDesktopAppExists() throws {
        let standalone = try makeExecutable(at: root.appending(path: "bin/codex"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], standaloneURLs: [standalone]
        )

        XCTAssertEqual(locator.locate(), resolved(standalone))
    }

    func testAbsolutePATHDiscoveryIsLastFallback() throws {
        let pathExecutable = try makeExecutable(at: root.appending(path: "custom bin/codex"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], standaloneURLs: [],
            searchPath: pathExecutable.deletingLastPathComponent().path
        )

        XCTAssertEqual(locator.locate(), resolved(pathExecutable))
    }

    func testStandaloneCLIPrecedesPATHFallback() throws {
        let standalone = try makeExecutable(at: root.appending(path: "standalone/codex"))
        let pathExecutable = try makeExecutable(at: root.appending(path: "path/codex"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], standaloneURLs: [standalone],
            searchPath: pathExecutable.deletingLastPathComponent().path
        )

        XCTAssertEqual(locator.locate(), resolved(standalone))
    }

    func testMissingExecutableReturnsNilAndMissIsNotCached() throws {
        let executable = root.appending(path: "bin/codex")
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], standaloneURLs: [executable]
        )
        XCTAssertNil(locator.locate())

        try makeExecutable(at: executable)
        XCTAssertEqual(locator.locate(), resolved(executable))
    }

    func testRejectsNonExecutableFileAndDirectory() throws {
        let file = try makeExecutable(at: root.appending(path: "file/codex"), permissions: 0o644)
        let directory = root.appending(path: "directory/codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], standaloneURLs: [file, directory]
        )

        XCTAssertNil(locator.locate())
    }

    func testStaleCachedChatGPTRuntimeFallsBackToLegacyCodexApp() throws {
        let app = try makeDesktopApp(
            at: root.appending(path: "Applications/ChatGPT.app"), name: "ChatGPT"
        )
        let legacyApp = try makeCodexApp(at: root.appending(path: "Applications/Codex.app"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [app], applicationURLs: [legacyApp]
        )
        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: app)))

        try FileManager.default.removeItem(at: app)
        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: legacyApp)))
    }

    func testValidCachedDesktopPathDoesNotRepeatWorkspaceDiscovery() throws {
        let app = try makeDesktopApp(
            at: root.appending(path: "Custom/ChatGPT.app"), name: "ChatGPT"
        )
        let lookup = LookupStub(result: app)
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], workspaceLookup: lookup.call
        )

        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: app)))
        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: app)))
        XCTAssertEqual(lookup.identifiers.count, 1)
    }

    func testNSWorkspaceResultIsQueriedAgainAfterCachedAppIsMoved() throws {
        let first = try makeDesktopApp(
            at: root.appending(path: "First/ChatGPT.app"), name: "ChatGPT"
        )
        let second = try makeDesktopApp(
            at: root.appending(path: "Second/ChatGPT.app"), name: "ChatGPT"
        )
        let lookup = LookupStub(result: first)
        let locator = makeLocator(
            chatGPTApplicationURLs: [], applicationURLs: [], workspaceLookup: lookup.call
        )
        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: first)))

        try FileManager.default.removeItem(at: first)
        lookup.result = second
        XCTAssertEqual(locator.locate(), resolved(bundledExecutable(in: second)))
        XCTAssertEqual(lookup.identifiers.count, 2)
    }

    func testInvalidNonExecutableChatGPTRuntimeFallsBackToStandaloneCLI() throws {
        let chatGPTApp = try makeDesktopApp(
            at: root.appending(path: "Applications/ChatGPT.app"),
            name: "ChatGPT",
            executablePermissions: 0o644
        )
        let standalone = try makeExecutable(at: root.appending(path: "bin/codex"))
        let locator = makeLocator(
            chatGPTApplicationURLs: [chatGPTApp], applicationURLs: [],
            standaloneURLs: [standalone]
        )

        XCTAssertEqual(locator.locate(), resolved(standalone))
    }

    func testNoSupportedRuntimeReturnsNil() {
        let locator = makeLocator(chatGPTApplicationURLs: [], applicationURLs: [])

        XCTAssertNil(locator.locate())
    }

    func testRejectsDesktopAppWithWrongBundleIdentifier() throws {
        let app = try makeCodexApp(
            at: root.appending(path: "Applications/Codex.app"),
            bundleIdentifier: "example.untrusted.codex"
        )
        XCTAssertNil(makeLocator(chatGPTApplicationURLs: [], applicationURLs: [app]).locate())
    }

    func testResolvesBundledExecutableSymlink() throws {
        let app = try makeCodexApp(at: root.appending(path: "Applications/Codex.app"))
        let executable = bundledExecutable(in: app)
        let target = try makeExecutable(at: app.appending(path: "Contents/Resources/codex-real"))
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: target)

        XCTAssertEqual(
            makeLocator(chatGPTApplicationURLs: [], applicationURLs: [app]).locate(),
            resolved(target)
        )
    }

    private func makeLocator(
        chatGPTApplicationURLs: [URL] = [],
        applicationURLs: [URL],
        workspaceApp: URL? = nil,
        workspaceLookup: CodexExecutableLocator.ApplicationURLLookup? = nil,
        standaloneURLs: [URL] = [],
        searchPath: String = ""
    ) -> CodexExecutableLocator {
        CodexExecutableLocator(
            chatGPTApplicationURLs: chatGPTApplicationURLs,
            applicationURLs: applicationURLs,
            applicationURLLookup: workspaceLookup ?? { _ in workspaceApp },
            standaloneURLs: standaloneURLs,
            searchPath: searchPath
        )
    }

    @discardableResult
    private func makeExecutable(at url: URL, permissions: Int = 0o755) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path
        )
        return url
    }

    private func makeCodexApp(
        at url: URL,
        bundleIdentifier: String = CodexExecutableLocator.codexBundleIdentifier
    ) throws -> URL {
        try makeDesktopApp(
            at: url, name: "Codex", bundleIdentifier: bundleIdentifier
        )
    }

    private func makeDesktopApp(
        at url: URL,
        name: String,
        bundleIdentifier: String = CodexExecutableLocator.chatGPTBundleIdentifier,
        executablePermissions: Int = 0o755,
        version: String = "1.0.0"
    ) throws -> URL {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": name,
            "CFBundleShortVersionString": version
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: contents.appending(path: "Info.plist"))
        try makeExecutable(
            at: bundledExecutable(in: url), permissions: executablePermissions
        )
        return url
    }

    private func bundledExecutable(in app: URL) -> URL {
        app.appending(path: "Contents/Resources/codex")
    }

    private func package(in app: URL) -> URL {
        app.appending(path: "Contents/Resources/codex-cli")
    }

    @discardableResult
    private func makePackagedRuntime(
        in app: URL,
        entrypoint: String = "bin/codex",
        permissions: Int = 0o755
    ) throws -> URL {
        let executable = try makeExecutable(
            at: package(in: app).appending(path: entrypoint), permissions: permissions
        )
        try writeManifest(in: app, entrypoint: entrypoint)
        return executable
    }

    private func writeManifest(
        in app: URL,
        entrypoint: String,
        layoutVersion: Int = 1
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "layoutVersion": layoutVersion,
            "version": "0.158.0-alpha.2.1",
            "target": "aarch64-apple-darwin",
            "variant": "codex",
            "entrypoint": entrypoint,
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path"
        ])
        try data.write(to: package(in: app).appending(path: "codex-package.json"))
    }

    private func resolved(_ url: URL) -> URL {
        guard let pointer = url.path.withCString({ realpath($0, nil) }) else { return url }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }
}

private final class LookupStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: URL?
    private var _identifiers: [String] = []

    init(result: URL?) { _result = result }

    var result: URL? {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var identifiers: [String] { lock.withLock { _identifiers } }

    func call(_ identifier: String) -> URL? {
        lock.withLock {
            _identifiers.append(identifier)
            return _result
        }
    }
}
