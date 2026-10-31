import DarkroomSetup
import Foundation

let repository = "https://github.com/alxgsv/darkroom"
let version = "0.1.0"

let usage = """
    usage: darkroom init [--project NAME.xcodeproj] [--target NAME] [--into DIR]
                         [--replace FILE]... [--local DARKROOM] [--no-build]

    Sets up a package of shots for a macOS app's Xcode target, in tools/shots
    by default: it builds the target's Swift files with its settings and
    renders the views you list to PNG, light and dark, without launching the app.

      --project   the Xcode project; the only one in this folder by default
      --target    the app's target; the one named like the project by default
      --into      where to put the package; tools/shots next to the project by default
      --replace   an app file to leave out and copy into Stand-ins/, to edit into a
                  version without the Keychain or the network; repeatable
      --local     depend on a darkroom checkout instead of \(repository)
      --no-build  skip the build that checks the setup
    """

struct Arguments {
    var project: String?
    var target: String?
    var into: String?
    var replace: [String] = []
    var local: String?
    var build = true

    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        guard rest.popFirst() == "init" else { throw SetupError(usage) }
        func value(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw SetupError("\(flag) needs a value") }
            return value
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--project": project = try value(argument)
            case "--target": target = try value(argument)
            case "--into": into = try value(argument)
            case "--replace": replace.append(try value(argument))
            case "--local": local = try value(argument)
            case "--no-build": build = false
            case "-h", "--help": throw SetupError(usage)
            default: throw SetupError("unknown argument \(argument)\n\n\(usage)")
            }
        }
    }
}

/// Runs a command and returns its standard output; standard error goes along
/// with it when `mergingErrors`, else nowhere.
func run(_ command: [String], in folder: URL? = nil, mergingErrors: Bool = false) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.currentDirectoryURL = folder
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = mergingErrors ? pipe : FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func json(_ command: [String]) throws -> Any {
    let result = try run(command)
    guard result.status == 0 else { throw SetupError("\(command.joined(separator: " ")) failed") }
    return try JSONSerialization.jsonObject(with: Data(result.output.utf8))
}

func setUp(_ arguments: Arguments) throws {
    let fm = FileManager.default
    let here = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)

    let project: URL
    if let path = arguments.project {
        project = URL(fileURLWithPath: path, relativeTo: here).standardizedFileURL
    } else {
        let found = try fm.contentsOfDirectory(atPath: here.path).filter { $0.hasSuffix(".xcodeproj") }
        guard found.count == 1 else {
            throw SetupError(found.isEmpty ? "no .xcodeproj here; pass --project" : "several projects here; pass --project")
        }
        project = here.appendingPathComponent(found[0])
    }
    let projectFolder = project.deletingLastPathComponent()
    let projectName = project.deletingPathExtension().lastPathComponent

    let listing = try json(["xcodebuild", "-list", "-json", "-project", project.path]) as? [String: Any]
    let targets = (listing?["project"] as? [String: Any])?["targets"] as? [String] ?? []
    guard let target = arguments.target ?? (targets.contains(projectName) ? projectName : targets.first) else {
        throw SetupError("\(project.lastPathComponent) has no targets")
    }
    guard targets.contains(target) else {
        throw SetupError("no target \(target); there are \(targets.joined(separator: ", "))")
    }

    let report = try json(["xcodebuild", "-showBuildSettings", "-json", "-project", project.path, "-target", target, "-configuration", "Debug"])
    guard let settings = ((report as? [[String: Any]])?.first?["buildSettings"]) as? [String: String] else {
        throw SetupError("couldn't read \(target)'s build settings")
    }
    guard (settings["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").contains("macosx") else {
        throw SetupError("\(target) doesn't build for macOS, and darkroom draws with AppKit")
    }

    let layout = try TargetLayout(target: target, projectFile: Data(contentsOf: project.appendingPathComponent("project.pbxproj")))
    guard !layout.folders.isEmpty else {
        throw SetupError("\(target) lists its files one by one; darkroom needs Xcode 16's folder-based targets")
    }

    let into = arguments.into.map { URL(fileURLWithPath: $0, relativeTo: here).standardizedFileURL }
        ?? projectFolder.appendingPathComponent("tools/shots", isDirectory: true)
    guard !fm.fileExists(atPath: into.path) else { throw SetupError("\(into.path) is there already") }
    let sources = into.appendingPathComponent("Sources/Shots", isDirectory: true)

    let name = target.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-") + "-shots"
    let darkroom: Scaffold.Darkroom = arguments.local.map {
        .local(path: URL(fileURLWithPath: $0, relativeTo: here).standardizedFileURL.path)
    } ?? .remote(url: repository, from: version)

    // Each folder is linked into the target under its own name.
    var links: [(name: String, folder: String)] = []
    for folder in layout.folders {
        var name = URL(fileURLWithPath: folder).lastPathComponent
        while links.contains(where: { $0.name == name }) { name += "-" }
        links.append((name, folder))
    }
    var scaffold = Scaffold(name: name, app: target, settings: PackageSettings(settings), links: links.map(\.name), darkroom: darkroom)

    /// A path relative to the project's folder, as the package names it.
    func inPackage(_ path: String) -> String? {
        links.first { path.hasPrefix($0.folder + "/") }.map { $0.name + path.dropFirst($0.folder.count) }
    }
    for link in links {
        let scan = try SourceScan(projectFolder.appendingPathComponent(link.folder))
        scaffold.entryPoints += scan.entryPoints.map { "\(link.name)/\($0)" }
        scaffold.other += scan.other.map { "\(link.name)/\($0)" }
        scaffold.hasContentView = scaffold.hasContentView || scan.hasContentView
    }
    scaffold.outsideTarget = layout.membershipExceptions.compactMap(inPackage)

    var standIns: [(file: String, text: String)] = []
    for path in arguments.replace {
        let candidates = [URL(fileURLWithPath: path, relativeTo: here)] + layout.folders.map {
            projectFolder.appendingPathComponent($0).appendingPathComponent(path)
        }
        guard let file = candidates.map(\.standardizedFileURL).first(where: { fm.fileExists(atPath: $0.path) }),
              let relative = inPackage(relativePath(from: projectFolder, to: file)) else {
            throw SetupError("--replace \(path): no such file in \(target)'s folders")
        }
        scaffold.replaced.append(relative)
        standIns.append((file.lastPathComponent, Scaffold.standIn(for: relative, original: try String(contentsOf: file, encoding: .utf8))))
    }

    // Relative paths only line up between folders that exist: /private/tmp
    // stays as it is until then, and becomes /tmp after.
    try fm.createDirectory(at: sources, withIntermediateDirectories: true)
    let place = relativePath(from: here, to: into)
    let projectFromPackage = relativePath(from: into, to: projectFolder)
    scaffold.packages = layout.packages.map { package in
        var package = package
        if package.isLocal { package.location = projectFromPackage + "/" + package.location }
        return package
    }

    try scaffold.packageSwift.write(to: into.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try Scaffold.gitignore.write(to: into.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try scaffold.shotsSwift.write(to: sources.appendingPathComponent("Shots.swift"), atomically: true, encoding: .utf8)
    for link in links {
        try fm.createSymbolicLink(
            atPath: sources.appendingPathComponent(link.name).path,
            withDestinationPath: relativePath(from: sources, to: projectFolder.appendingPathComponent(link.folder))
        )
    }
    if !standIns.isEmpty {
        let folder = sources.appendingPathComponent("Stand-ins", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for standIn in standIns {
            try standIn.text.write(to: folder.appendingPathComponent(standIn.file), atomically: true, encoding: .utf8)
        }
    }

    print("Set up \(place) for \(target):")
    print("  sources    \(links.map { "\($0.name)/ → \($0.folder)" }.joined(separator: ", "))")
    for exclusion in scaffold.exclusions {
        print("  left out   \(exclusion.paths.count) × \(exclusion.reason)")
    }
    print("  settings   \(scaffold.settings.swiftSettings.isEmpty ? "none" : scaffold.settings.swiftSettings.joined(separator: " "))")
    if !scaffold.packages.isEmpty {
        print("  packages   \(scaffold.packages.map(\.identity).joined(separator: ", "))")
    }
    for setting in scaffold.settings.unmapped {
        print("  carry over by hand, as .unsafeFlags: \(setting)")
    }
    if !standIns.isEmpty {
        print("  stand-ins  \(standIns.map { "Stand-ins/\($0.file)" }.joined(separator: ", ")): edit them, then swift build")
    }

    if arguments.build, standIns.isEmpty {
        print("Building…")
        let result = try run(["swift", "build"], in: into, mergingErrors: true)
        guard result.status == 0 else {
            print(result.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n"))
            throw SetupError("""
                the build failed. Usual causes: a symbol the left-out entry point defines, a file \
                that isn't in the target, or a package the app links some other way. Fix Package.swift \
                or add stand-ins, then swift build in \(place).
                """)
        }
        print("Built.")
    }
    print("""

        Next: put the app's views in \(place)/Sources/Shots/Shots.swift, then
          cd \(place) && swift run \(name)
        """)
}

do {
    try setUp(try Arguments(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("darkroom: \(error)\n".utf8))
    exit(1)
}
