import Foundation

/// What in an app's folder a Swift package target can't take as it is.
public struct SourceScan: Equatable, Sendable {
    /// Files with the app's entry point (`@main`, `main.swift`): the shots
    /// executable has its own.
    public var entryPoints: [String] = []
    /// Everything that isn't Swift: asset catalogs, plists, entitlements,
    /// Objective-C. Folders like `.xcassets` count as one.
    public var other: [String] = []
    /// Whether the folder has a `ContentView`, to start the first shot from.
    public var hasContentView = false

    /// Paths are relative to `folder`.
    public init(_ folder: URL) throws {
        let folder = folder.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw SetupError("can't read \(folder.path)")
        }
        let base = folder.standardizedFileURL.path + "/"
        for case let url as URL in walk {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            let isFolder = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            if isFolder {
                if !url.pathExtension.isEmpty {
                    other.append(path)
                    walk.skipDescendants()
                }
            } else if url.pathExtension != "swift" {
                other.append(path)
            } else {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if url.lastPathComponent == "main.swift" || Self.isEntryPoint(text) {
                    entryPoints.append(path)
                } else if Self.declaresContentView(text) {
                    hasContentView = true
                }
            }
        }
        entryPoints.sort()
        other.sort()
    }

    static func isEntryPoint(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*@(main|NSApplicationMain|UIApplicationMain)\b"#, options: .regularExpression) != nil
    }

    static func declaresContentView(_ text: String) -> Bool {
        text.range(of: #"\bstruct\s+ContentView\s*:\s*View\b"#, options: .regularExpression) != nil
    }
}

/// `to` relative to the folder `from`, for a symbolic link in `from`.
public func relativePath(from: URL, to: URL) -> String {
    let a = from.standardizedFileURL.pathComponents
    let b = to.standardizedFileURL.pathComponents
    var common = 0
    while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
    let up = Array(repeating: "..", count: a.count - common)
    return (up + b[common...]).joined(separator: "/")
}
