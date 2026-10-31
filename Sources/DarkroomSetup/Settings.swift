/// The Xcode target's Swift settings, as a Swift package states them.
public struct PackageSettings: Equatable, Sendable {
    /// `.v5`, `.v6`…; nil leaves the tools version's default.
    public var languageMode: String?
    public var mainActorByDefault = false
    public var upcomingFeatures: [String] = []
    public var defines: [String] = []
    /// The macOS version the package needs: the app's, or darkroom's own if higher.
    public var macOS = "14.0"
    /// Settings that have no package equivalent, to be carried over by hand.
    public var unmapped: [String] = []

    /// What `SWIFT_APPROACHABLE_CONCURRENCY` turns on.
    static let approachableConcurrency = [
        "DisableOutwardActorInference", "GlobalActorIsolatedTypesUsability", "InferIsolatedConformances",
        "InferSendableFromCaptures", "NonisolatedNonsendingByDefault",
    ]

    /// On in the Swift 6 language mode already; naming them again warns.
    static let onInSwift6: Set<String> = [
        "BareSlashRegexLiterals", "ConciseMagicFile", "DeprecateApplicationMain", "DisableOutwardActorInference",
        "DynamicActorIsolation", "ForwardTrailingClosures", "GlobalActorIsolatedTypesUsability",
        "ImportObjcForwardDeclarations", "InferSendableFromCaptures", "IsolatedDefaultValues",
        "RegionBasedIsolation", "StrictConcurrency",
    ]

    /// Build settings whose feature isn't the setting's name in camel case.
    static let featureNames = ["IMPORT_OBJC_FORWARD_DECLS": "ImportObjcForwardDeclarations"]

    public init(_ settings: [String: String]) {
        languageMode = settings["SWIFT_VERSION"].flatMap(Self.languageMode)
        mainActorByDefault = settings["SWIFT_DEFAULT_ACTOR_ISOLATION"] == "MainActor"

        var features: [String] = []
        if settings["SWIFT_APPROACHABLE_CONCURRENCY"] == "YES" {
            features += Self.approachableConcurrency
        }
        let prefix = "SWIFT_UPCOMING_FEATURE_"
        for (key, value) in settings where key.hasPrefix(prefix) && value == "YES" {
            features.append(Self.featureName(String(key.dropFirst(prefix.count))))
        }
        if settings["SWIFT_STRICT_CONCURRENCY"] == "complete" {
            features.append("StrictConcurrency")
        }
        let swift6 = languageMode == ".v6"
        upcomingFeatures = Array(Set(features)).filter { !swift6 || !Self.onInSwift6.contains($0) }.sorted()

        defines = Self.list(settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
        if let target = settings["MACOSX_DEPLOYMENT_TARGET"], Self.version(target, isAtLeast: macOS) {
            macOS = target
        }
        let flags = Self.list(settings["OTHER_SWIFT_FLAGS"])
        if !flags.isEmpty {
            unmapped.append("OTHER_SWIFT_FLAGS = \(flags.joined(separator: " "))")
        }
    }

    /// `MEMBER_IMPORT_VISIBILITY` → `MemberImportVisibility`.
    static func featureName(_ setting: String) -> String {
        if let name = featureNames[setting] { return name }
        return setting.split(separator: "_").map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined()
    }

    static func languageMode(_ version: String) -> String? {
        switch version {
        case "4": return ".v4"
        case "4.2": return ".v4_2"
        case "5", "5.0": return ".v5"
        case "6", "6.0": return ".v6"
        default: return nil
        }
    }

    static func list(_ value: String?) -> [String] {
        (value ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "$(inherited)" }
    }

    static func version(_ a: String, isAtLeast b: String) -> Bool {
        let parts = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return true
    }

    /// The target's `swiftSettings:` entries.
    public var swiftSettings: [String] {
        var lines: [String] = []
        if let languageMode { lines.append(".swiftLanguageMode(\(languageMode))") }
        if mainActorByDefault { lines.append(".defaultIsolation(MainActor.self)") }
        lines += upcomingFeatures.map { ".enableUpcomingFeature(\"\($0)\")" }
        lines += defines.map { ".define(\"\($0)\")" }
        return lines
    }
}
