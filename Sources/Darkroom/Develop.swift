import AppKit

/// Renders the shots named on the command line, or all of them, to PNG, and
/// exits. Call it from the shots executable's `@main` type.
@MainActor
public func develop(_ shots: [Shot<Void>]) -> Never {
    develop(shots, prepare: {})
}

/// Renders the shots with what `prepare` makes, then hands that to `finish`,
/// for example to delete a temporary folder of sample data.
@MainActor
public func develop<Context>(
    _ shots: [Shot<Context>],
    prepare: @escaping @MainActor () async throws -> Context,
    finish: @escaping @MainActor (Context) -> Void = { _ in }
) -> Never {
    let options: Options
    do {
        options = try Options(Array(CommandLine.arguments.dropFirst()), shots: shots.map(\.name))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n\n\(Options.usage)\n".utf8))
        exit(2)
    }
    if options.help {
        print(Options.usage)
        exit(0)
    }
    if options.list {
        let width = shots.map(\.name.count).max() ?? 0
        for shot in shots {
            print(shot.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + shot.about)
        }
        exit(0)
    }
    // No Dock icon, no menu bar, never frontmost: the app itself may be
    // running, and its user working in it.
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task {
        do {
            try await run(shots.filter { options.shots.contains($0.name) }, options: options, prepare: prepare, finish: finish)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(ProcessInfo.processInfo.processName): \(error)\n".utf8))
            exit(1)
        }
    }
    NSApplication.shared.run()
    exit(0)
}

@MainActor
private func run<Context>(
    _ shots: [Shot<Context>], options: Options,
    prepare: () async throws -> Context, finish: (Context) -> Void
) async throws {
    // `@AppStorage` in the app's views reads this executable's own defaults;
    // they start empty on every run, so shots don't depend on the last one.
    if Bundle.main.bundleIdentifier == nil {
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
    }
    try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    let context = try await prepare()
    defer { finish(context) }
    for shot in shots {
        for dark in options.appearances {
            let png = try await Renderer.render(shot, context: context, dark: dark, wait: options.wait)
            let url = options.out.appendingPathComponent("\(shot.name)-\(dark ? "dark" : "light").png")
            try png.write(to: url)
            print(url.path)
        }
    }
}

struct Options {
    var shots: Set<String>
    var appearances = [false, true]
    var out = FileManager.default.temporaryDirectory
        .appendingPathComponent(ProcessInfo.processInfo.processName, isDirectory: true)
    var wait: Duration = .seconds(2.5)
    var list = false
    var help = false

    static var usage: String {
        let name = ProcessInfo.processInfo.processName
        return """
            usage: \(name) [shot ...] [--out DIR] [--appearance light|dark|both] [--wait SECONDS]
                   \(name) --list

            Renders the shots (all of them by default) to DIR/<shot>-<light|dark>.png
            and prints each file's path. DIR defaults to $TMPDIR/\(name).
            """
    }

    init(_ arguments: [String], shots all: [String]) throws {
        var names: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--list": list = true
            case "-h", "--help": help = true
            case "--out":
                out = URL(fileURLWithPath: try Self.value(of: argument, in: &rest), isDirectory: true)
            case "--appearance":
                switch try Self.value(of: argument, in: &rest) {
                case "light": appearances = [false]
                case "dark": appearances = [true]
                case "both": appearances = [false, true]
                case let other: throw DarkroomError.usage("--appearance takes light, dark or both, not \(other)")
                }
            case "--wait":
                let text = try Self.value(of: argument, in: &rest)
                guard let seconds = Double(text), seconds >= 0 else {
                    throw DarkroomError.usage("--wait takes seconds, not \(text)")
                }
                wait = .seconds(seconds)
            case let flag where flag.hasPrefix("-"):
                throw DarkroomError.usage("unknown option \(flag)")
            default:
                guard all.contains(argument) else {
                    throw DarkroomError.usage("no shot \(argument); there are \(all.joined(separator: ", "))")
                }
                names.append(argument)
            }
        }
        shots = Set(names.isEmpty ? all : names)
    }

    private static func value(of flag: String, in rest: inout ArraySlice<String>) throws -> String {
        guard let value = rest.popFirst() else { throw DarkroomError.usage("\(flag) needs a value") }
        return value
    }
}

enum DarkroomError: Error, CustomStringConvertible {
    case usage(String)
    case render(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .render(let shot): return "couldn't draw \(shot)"
        }
    }
}
