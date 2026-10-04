import Foundation

enum ClaudeSettingsEditability: Equatable, Sendable { case editable, shadowed, managed, unknown }

enum ClaudeStatusLineSettingsSource: Sendable {
    case absent, user, sharedProject, localProject, commandLine, managed, unknown
}

struct ClaudeStatusLineSettingsEvidence: Sendable {
    let effectiveSource: ClaudeStatusLineSettingsSource
    let sourcesAndTrustKnown: Bool
    let allowManagedHooksOnly: Bool?
    let disableAllHooksOutsideManaged: Bool?

    var userSettingsEditability: ClaudeSettingsEditability {
        if effectiveSource == .managed || allowManagedHooksOnly == true || disableAllHooksOutsideManaged == true {
            return .managed
        }
        guard sourcesAndTrustKnown, allowManagedHooksOnly == false,
              disableAllHooksOutsideManaged == false else { return .unknown }
        switch effectiveSource {
        case .absent, .user: return .editable
        case .sharedProject, .localProject, .commandLine: return .shadowed
        case .managed: return .managed
        case .unknown: return .unknown
        }
    }
}

// Caller-supplied evidence only. M2A does not inspect any real Claude settings source.
struct ClaudeBridgeSetupPreview: Sendable {
    let editability: ClaudeSettingsEditability
    let originalSettings: Data
    let proposedSettings: Data
    let hasExistingRenderer: Bool
    var changedKeys: [String] {
        hasExistingRenderer ? ["statusLine.command"] : ["statusLine.type", "statusLine.command"]
    }

    static func make(
        originalSettings: Data, helperPath: String, downstreamReference: String,
        editability: ClaudeSettingsEditability
    ) throws -> Self {
        guard originalSettings.count <= 65_536,
              var settings = try JSONSerialization.jsonObject(with: originalSettings) as? [String: Any] else {
            throw ClaudeContractError.invalidInput
        }
        var statusLine: [String: Any]
        if let existing = settings["statusLine"] {
            guard let object = existing as? [String: Any], object["type"] as? String == "command",
                  let command = object["command"] as? String, !command.isEmpty else {
                throw ClaudeContractError.invalidInput
            }
            statusLine = object
        } else { statusLine = ["type": "command"] }
        let existing = statusLine["command"] != nil
        // Proposed shell syntax contains only setup-owned, quoted paths. The original
        // opaque command goes in a future owner-only reference file, never in JSON stdin.
        let command = quote(helperPath) + (existing ? " --downstream-file " + quote(downstreamReference) : "")
        statusLine["command"] = command
        settings["statusLine"] = statusLine
        return .init(editability: editability, originalSettings: originalSettings,
                     proposedSettings: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
                     hasExistingRenderer: existing)
    }

    var mayProposeActivation: Bool { editability == .editable }
    var rollbackBytes: Data { originalSettings }

    // Future rollback must compare the current settings to the integration it installed.
    // Refuse a conflicting edit rather than overwriting it with an old whole-file backup.
    func rollback(currentSettings: Data) throws -> Data {
        guard currentSettings == proposedSettings else { throw ClaudeContractError.invalidInput }
        return originalSettings
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
