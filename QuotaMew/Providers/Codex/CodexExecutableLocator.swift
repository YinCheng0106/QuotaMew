import AppKit
import Darwin
import Foundation

struct CodexRuntimeDiscovery: Equatable, Sendable {
    let chatGPTApplication: DiagnosticHostApplicationState
    let runtimeSource: DiagnosticRuntimeSource
    let runtimeDetected: Bool
    let failureCategory: DiagnosticFailureCategory?
}

final class CodexExecutableLocator: @unchecked Sendable {
    typealias ApplicationURLLookup = @Sendable (String) -> URL?

    static let chatGPTBundleIdentifier = "com.openai.codex"
    static let codexBundleIdentifier = chatGPTBundleIdentifier
    private static let bundledExecutablePath = "Contents/Resources/codex"
    private static let packagePath = "Contents/Resources/codex-cli"
    private static let packageManifestName = "codex-package.json"
    private static let packagedExecutablePath = "bin/codex"
    private static let maximumManifestBytes = 4_096

    private struct PackageManifest: Decodable {
        let layoutVersion: Int
        let variant: String
        let entrypoint: String
    }

    private enum ApplicationKind {
        case chatGPT
        case legacyCodex

        var bundleName: String {
            switch self {
            case .chatGPT: "ChatGPT.app"
            case .legacyCodex: "Codex.app"
            }
        }
    }

    private enum Source {
        case application(URL, ApplicationKind)
        case standalone(URL)
    }

    private let chatGPTApplicationURLs: [URL]
    private let applicationURLs: [URL]
    private let applicationURLLookup: ApplicationURLLookup
    private let standaloneURLs: [URL]
    private let lock = NSLock()
    private var cachedSource: Source?

    init(
        chatGPTApplicationURLs: [URL] = CodexExecutableLocator.defaultChatGPTApplicationURLs(),
        applicationURLs: [URL] = CodexExecutableLocator.defaultApplicationURLs(),
        applicationURLLookup: @escaping ApplicationURLLookup = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        standaloneURLs: [URL] = CodexExecutableLocator.defaultStandaloneURLs(),
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.chatGPTApplicationURLs = chatGPTApplicationURLs
        self.applicationURLs = applicationURLs
        self.applicationURLLookup = applicationURLLookup
        self.standaloneURLs = standaloneURLs + Self.pathCandidateURLs(searchPath)
    }

    // Test and explicit-injection compatibility: these are standalone candidates.
    convenience init(candidateURLs: [URL]) {
        self.init(
            chatGPTApplicationURLs: [], applicationURLs: [], applicationURLLookup: { _ in nil },
            standaloneURLs: candidateURLs, searchPath: ""
        )
    }

    func locate() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedSource, let executable = Self.resolve(cachedSource) {
            return executable
        }
        cachedSource = nil

        for appURL in chatGPTApplicationURLs {
            let source = Source.application(appURL, .chatGPT)
            if let executable = Self.resolve(source) {
                cachedSource = source
                return executable
            }
        }

        let workspaceAppURL = applicationURLLookup(Self.chatGPTBundleIdentifier)
        if let workspaceAppURL {
            let source = Source.application(workspaceAppURL, .chatGPT)
            if let executable = Self.resolve(source) {
                cachedSource = source
                return executable
            }
        }

        for appURL in applicationURLs {
            let source = Source.application(appURL, .legacyCodex)
            if let executable = Self.resolve(source) {
                cachedSource = source
                return executable
            }
        }

        if let workspaceAppURL {
            let source = Source.application(workspaceAppURL, .legacyCodex)
            if let executable = Self.resolve(source) {
                cachedSource = source
                return executable
            }
        }

        for url in standaloneURLs {
            let source = Source.standalone(url)
            if let executable = Self.resolve(source) {
                cachedSource = source
                return executable
            }
        }
        // Misses are not cached, so a later installation can be discovered.
        return nil
    }

    func diagnosticSnapshot() -> CodexRuntimeDiscovery {
        let executable = locate()
        let workspaceURL = applicationURLLookup(Self.chatGPTBundleIdentifier)
        let chatGPTURLs = chatGPTApplicationURLs + [workspaceURL].compactMap { $0 }
        let chatGPTBundle = chatGPTURLs.lazy.compactMap { url in
            Self.applicationBundle(at: url, kind: .chatGPT)
        }.first
        let locatedSource = lock.withLock { cachedSource }

        let runtimeSource: DiagnosticRuntimeSource
        switch locatedSource {
        case .application(_, .chatGPT):
            runtimeSource = .chatGPTApplication
        case .application(_, .legacyCodex):
            runtimeSource = .legacyCodexApplication
        case .standalone:
            runtimeSource = .standaloneCodex
        case nil:
            if executable != nil {
                // Explicit executable injection is handled by CodexAppServerClient.
                runtimeSource = .standaloneCodex
            } else {
                runtimeSource = .notDetected
            }
        }

        let hasInvalidCandidate: Bool
        if executable == nil {
            let appBundles = chatGPTURLs.compactMap {
                Self.applicationBundle(at: $0, kind: .chatGPT)
            } + applicationURLs.compactMap {
                Self.applicationBundle(at: $0, kind: .legacyCodex)
            }
            let bundledCandidates = appBundles.flatMap { bundle in
                let package = bundle.bundleURL.appending(path: Self.packagePath)
                return [
                    Self.manifestEntrypoint(in: package),
                    package.appending(path: Self.packagedExecutablePath),
                    bundle.bundleURL.appending(path: Self.bundledExecutablePath)
                ].compactMap { $0 }
            }
            hasInvalidCandidate = (bundledCandidates + standaloneURLs).contains {
                FileManager.default.fileExists(atPath: $0.path)
            }
        } else {
            hasInvalidCandidate = false
        }

        return CodexRuntimeDiscovery(
            chatGPTApplication: DiagnosticHostApplicationState(
                application: .chatGPT,
                isDetected: chatGPTBundle != nil,
                version: DiagnosticVersion(
                    chatGPTBundle?.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String
                )
            ),
            runtimeSource: runtimeSource,
            runtimeDetected: executable != nil,
            failureCategory: hasInvalidCandidate ? .runtimeNotExecutable : nil
        )
    }

    static func defaultChatGPTApplicationURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            homeDirectory.appending(path: "Applications/ChatGPT.app", directoryHint: .isDirectory)
        ]
    }

    static func defaultApplicationURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            homeDirectory.appending(path: "Applications/Codex.app", directoryHint: .isDirectory)
        ]
    }

    static func defaultStandaloneURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            homeDirectory.appending(path: ".local/bin/codex"),
            homeDirectory.appending(path: ".bun/bin/codex")
        ]
    }

    private static func resolve(_ source: Source) -> URL? {
        switch source {
        case .application(let appURL, let kind):
            return executable(in: appURL, kind: kind)
        case .standalone(let url):
            guard !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
                return nil
            }
            return validatedExecutable(url)
        }
    }

    private static func executable(in applicationURL: URL, kind: ApplicationKind) -> URL? {
        guard let bundle = applicationBundle(at: applicationURL, kind: kind) else { return nil }
        if kind == .chatGPT {
            let package = bundle.bundleURL.appending(path: packagePath, directoryHint: .isDirectory)
            if let entrypoint = manifestEntrypoint(in: package),
               let executable = validatedPackagedExecutable(entrypoint, in: package) {
                return executable
            }
            let knownEntrypoint = package.appending(
                path: packagedExecutablePath, directoryHint: .notDirectory
            )
            if let executable = validatedPackagedExecutable(knownEntrypoint, in: package) {
                return executable
            }
        }
        return validatedExecutable(
            bundle.bundleURL.appending(path: bundledExecutablePath, directoryHint: .notDirectory)
        )
    }

    private static func manifestEntrypoint(in package: URL) -> URL? {
        let manifestURL = package.appending(path: packageManifestName, directoryHint: .notDirectory)
        guard let packagePath = canonicalPackagePath(package),
              let manifestPath = canonicalPath(manifestURL.path),
              isInside(manifestPath, root: packagePath),
              hasTrustedAncestry(manifestURL),
              hasTrustedAncestry(URL(fileURLWithPath: manifestPath)),
              let attributes = try? FileManager.default.attributesOfItem(atPath: manifestPath),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= Int64(maximumManifestBytes),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: manifestPath))
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumManifestBytes + 1),
              data.count <= maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data),
              manifest.layoutVersion == 1, manifest.variant == "codex",
              !manifest.entrypoint.hasPrefix("/"),
              !manifest.entrypoint.utf8.contains(0) else { return nil }
        let components = manifest.entrypoint.split(
            separator: "/", omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return package.appending(path: manifest.entrypoint, directoryHint: .notDirectory)
    }

    private static func validatedPackagedExecutable(_ candidate: URL, in package: URL) -> URL? {
        guard let packagePath = canonicalPackagePath(package),
              let candidatePath = canonicalPath(candidate.path),
              isInside(candidatePath, root: packagePath),
              let executable = validatedExecutable(candidate) else { return nil }
        return executable
    }

    private static func canonicalPackagePath(_ package: URL) -> String? {
        let application = package.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let applicationPath = canonicalPath(application.path),
              let packagePath = canonicalPath(package.path),
              packagePath == applicationPath + "/Contents/Resources/codex-cli",
              hasTrustedAncestry(package),
              hasTrustedAncestry(URL(fileURLWithPath: packagePath)) else { return nil }
        return packagePath
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path.hasPrefix(root + "/")
    }

    private static func applicationBundle(
        at applicationURL: URL,
        kind: ApplicationKind
    ) -> Bundle? {
        guard applicationURL.isFileURL, applicationURL.path.hasPrefix("/"),
              hasTrustedAncestry(applicationURL),
              let resolvedPath = canonicalPath(applicationURL.path) else { return nil }
        let resolvedApp = URL(fileURLWithPath: resolvedPath, isDirectory: true)

        // ChatGPT.app and legacy Codex.app share a bundle identifier, so validate both identity parts.
        guard resolvedApp.lastPathComponent == kind.bundleName,
              resolvedApp.pathExtension == "app",
              let bundle = Bundle(url: resolvedApp),
              bundle.bundleIdentifier == codexBundleIdentifier else { return nil }
        return bundle
    }

    private static func validatedExecutable(_ candidate: URL) -> URL? {
        guard candidate.isFileURL, candidate.path.hasPrefix("/"),
              let resolvedPath = canonicalPath(candidate.path) else { return nil }
        let resolved = URL(fileURLWithPath: resolvedPath)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: resolved.path),
              hasTrustedAncestry(candidate), hasTrustedAncestry(resolved) else { return nil }
        return resolved
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard !path.utf8.contains(0), let pointer = path.withCString({ realpath($0, nil) }) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func pathCandidateURLs(_ searchPath: String) -> [URL] {
        guard searchPath.utf8.count <= 32_768 else { return [] }
        var seen: Set<String> = []
        return searchPath.split(separator: ":", omittingEmptySubsequences: false)
            .prefix(128)
            .compactMap { component in
                let path = String(component)
                guard path.hasPrefix("/"),
                      !path.split(separator: "/").contains(".."),
                      seen.insert(path).inserted else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true).appending(path: "codex")
            }
    }

    private static func hasTrustedAncestry(_ url: URL) -> Bool {
        var current = url
        for _ in 0..<128 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == 0 || owner.uint32Value == geteuid(),
                  let permissions = attributes[.posixPermissions] as? NSNumber else { return false }

            if attributes[.type] as? FileAttributeType != .typeSymbolicLink {
                guard permissions.intValue & 0o002 == 0 else { return false }
                if permissions.intValue & 0o020 != 0 {
                    let group = attributes[.groupOwnerAccountName] as? String
                    guard group == "admin" || group == "wheel" else { return false }
                }
            }
            if current.path == "/" { return true }
            current.deleteLastPathComponent()
        }
        return false
    }
}
