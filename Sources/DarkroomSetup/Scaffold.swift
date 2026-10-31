/// The files `darkroom init` writes: a package whose executable target holds
/// links to the app's folders and a `Shots.swift` of shots.
public struct Scaffold: Sendable {
    public enum Darkroom: Sendable {
        case remote(url: String, from: String)
        case local(path: String)
    }

    /// The package and its executable, e.g. `notes-shots`.
    public var name: String
    /// The Xcode target's name.
    public var app: String
    public var settings: PackageSettings
    /// Links in `Sources/Shots`, named after the app's folders.
    public var links: [String]
    /// The rest are relative to `Sources/Shots`, so they start with a link's name.
    public var entryPoints: [String] = []
    public var replaced: [String] = []
    public var outsideTarget: [String] = []
    public var other: [String] = []
    /// The app's packages, local ones' paths relative to the new package.
    public var packages: [PackageReference] = []
    public var darkroom: Darkroom
    public var hasContentView = false

    public init(name: String, app: String, settings: PackageSettings, links: [String], darkroom: Darkroom) {
        self.name = name
        self.app = app
        self.settings = settings
        self.links = links
        self.darkroom = darkroom
    }

    public static let gitignore = "/.build\n/.swiftpm\n"

    /// How to run the shots, for whoever opens the folder, people and coding agents alike.
    public var readme: String {
        let standIns = replaced.isEmpty ? "" : """

            `Sources/Shots/Stand-ins/` replaces the app files that would reach the
            Keychain, the network or other apps, so the shots never do.

            """
        return """
            # \(name)

            Renders \(app)'s views to PNG, light and dark, without launching the app,
            with [darkroom](\(Self.repository)).

            ```sh
            swift run \(name)                      # every shot, light and dark
            swift run \(name) <shot> --appearance dark --out /tmp/shots
            swift run \(name) --list
            ```

            Each PNG's path is printed as it's written. Nothing shows on screen and
            nothing takes focus, so the app can keep running.

            The shots are in `Sources/Shots/Shots.swift`.
            \(links.map { "`Sources/Shots/\($0)`" }.joined(separator: ", ")) \(links.count == 1 ? "links" : "link") to \(app)'s sources,
            built with its Xcode target's Swift settings as `Package.swift` states them.
            Rebuild after changing the app.
            \(standIns)
            """
    }

    static let repository = "https://github.com/alxgsv/darkroom"

    /// What the target leaves out and why, each path once, under its first reason.
    public var exclusions: [(reason: String, paths: [String])] {
        var seen: Set<String> = []
        return [
            ("The app's entry point: Shots.swift has this executable's.", entryPoints),
            ("Stand-ins/ replaces these.", replaced),
            ("Not in the Xcode target.", outsideTarget),
            ("Not Swift.", other),
        ].compactMap { reason, paths in
            let paths = paths.filter { seen.insert($0).inserted }
            return paths.isEmpty ? nil : (reason, paths)
        }
    }

    public var packageSwift: String {
        var dependencies: [String]
        switch darkroom {
        case .remote(let url, let version): dependencies = [".package(url: \"\(url)\", from: \"\(version)\")"]
        case .local(let path): dependencies = [".package(path: \"\(path)\")"]
        }
        dependencies += packages.map { package in
            package.isLocal
                ? ".package(path: \"\(package.location)\")"
                : ".package(url: \"\(package.location)\", \(package.requirement))"
        }
        let products = [".product(name: \"Darkroom\", package: \"darkroom\")"] + packages.flatMap { package in
            package.products.map { ".product(name: \"\($0)\", package: \"\(package.identity)\")" }
        }

        let exclude = exclusions.flatMap { ["// \($0.reason)"] + $0.paths.map { "\"\($0)\"," } }

        let swiftSettings = settings.swiftSettings.map { "\($0)," } + [
            "// The app's warnings are its Xcode build's to report.",
            ".unsafeFlags([\"-suppress-warnings\"]),",
        ]
        let folders = links.count == 1 ? "\(links[0])/ links" : links.map { "\($0)/" }.joined(separator: ", ") + " link"
        return """
            // swift-tools-version: 6.2

            import PackageDescription

            let package = Package(
                name: "\(name)",
                platforms: [.macOS("\(settings.macOS)")],
                products: [
                    .executable(name: "\(name)", targets: ["Shots"]),
                ],
                dependencies: [
            \(Self.lines(dependencies.map { "\($0)," }, indent: 8))
                ],
                targets: [
                    // \(folders) to \(app)'s sources, built with its Xcode target's Swift settings.
                    .executableTarget(
                        name: "Shots",
                        dependencies: [
            \(Self.lines(products.map { "\($0)," }, indent: 16))
                        ],
                        path: "Sources/Shots",
                        exclude: [
            \(Self.lines(exclude, indent: 16))
                        ],
                        swiftSettings: [
            \(Self.lines(swiftSettings, indent: 16))
                        ]
                    ),
                ]
            )

            """
    }

    public var shotsSwift: String {
        let shot = hasContentView
            ? """
                        Shot("window", "The main window", width: 900, height: 600, window: true) {
                            ContentView()
                        },
            """
            : """
                        Shot("example", "Replace with one of the app's views", width: 400) {
                            Text("One of \(app)'s views goes here.").padding()
                        },
            """
        return """
            import Darkroom
            import SwiftUI

            // Each shot is one of the app's views, drawn light and dark. `window: true`
            // draws a whole window, its title bar, toolbar and sidebar included.
            // Views that read the Keychain, the network or shared state need stand-ins
            // and sample data first: https://github.com/alxgsv/darkroom
            @main
            @MainActor
            enum Main {
                static func main() {
                    develop([
            \(shot)
                    ])
                }
            }

            """
    }

    /// An app file to edit into a stand-in, which won't build until it is.
    public static func standIn(for path: String, original: String) -> String {
        """
        #error("A stand-in for \(path), which this package leaves out. Keep what the app calls, answer from sample data instead of the Keychain, the network or other apps, then delete this line.")

        \(original)
        """
    }

    private static func lines(_ lines: [String], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        return lines.map { pad + $0 }.joined(separator: "\n")
    }
}
