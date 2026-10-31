import Foundation

/// What a target's entry in `project.pbxproj` says about building it
/// elsewhere: its folders, the files left out of them, its packages.
public struct TargetLayout: Equatable, Sendable {
    /// Synchronized folders, relative to the project's folder.
    public var folders: [String] = []
    /// Files in those folders that aren't in the target, relative to the project's folder.
    public var membershipExceptions: [String] = []
    public var packages: [PackageReference] = []

    /// Reads the project file, an old-style property list.
    public init(target: String, projectFile data: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else {
            throw SetupError("the project file isn't a property list")
        }
        guard let (targetID, entry) = objects.first(where: { $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == target }) else {
            throw SetupError("the project has no target \(target)")
        }
        for groupID in entry["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let group = objects[groupID], let path = group["path"] as? String else { continue }
            folders.append(path)
            for exceptionID in group["exceptions"] as? [String] ?? [] {
                guard let exception = objects[exceptionID], exception["target"] as? String == targetID else { continue }
                membershipExceptions += (exception["membershipExceptions"] as? [String] ?? []).map { "\(path)/\($0)" }
            }
        }
        var byPackage: [String: [String]] = [:]
        for productID in entry["packageProductDependencies"] as? [String] ?? [] {
            guard let product = objects[productID], let name = product["productName"] as? String,
                  let packageID = product["package"] as? String else { continue }
            byPackage[packageID, default: []].append(name)
        }
        packages = byPackage.keys.sorted().compactMap { id in
            objects[id].flatMap { PackageReference($0, products: byPackage[id] ?? []) }
        }
    }
}

/// A Swift package the app's target uses, as a package dependency.
public struct PackageReference: Equatable, Sendable {
    public var location: String
    public var isLocal: Bool
    /// The `.package(…)` arguments after the location; empty for a local one.
    public var requirement: String
    public var products: [String]

    /// The package's identity: its URL's or folder's last component.
    public var identity: String {
        let last = location.split(separator: "/").last.map(String.init) ?? location
        return (last.hasSuffix(".git") ? String(last.dropLast(4)) : last).lowercased()
    }

    init?(_ entry: [String: Any], products: [String]) {
        self.products = products
        switch entry["isa"] as? String {
        case "XCLocalSwiftPackageReference":
            guard let path = entry["relativePath"] as? String else { return nil }
            location = path
            isLocal = true
            requirement = ""
        case "XCRemoteSwiftPackageReference":
            guard let url = entry["repositoryURL"] as? String, let rule = entry["requirement"] as? [String: String] else { return nil }
            location = url
            isLocal = false
            switch rule["kind"] {
            case "upToNextMajorVersion": requirement = "from: \"\(rule["minimumVersion"] ?? "")\""
            case "upToNextMinorVersion": requirement = ".upToNextMinor(from: \"\(rule["minimumVersion"] ?? "")\")"
            case "exactVersion": requirement = "exact: \"\(rule["version"] ?? "")\""
            case "branch": requirement = "branch: \"\(rule["branch"] ?? "")\""
            case "revision": requirement = "revision: \"\(rule["revision"] ?? "")\""
            case "versionRange": requirement = "\"\(rule["minimumVersion"] ?? "")\"..<\"\(rule["maximumVersion"] ?? "")\""
            default: return nil
            }
        default:
            return nil
        }
    }
}

public struct SetupError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
