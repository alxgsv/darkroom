import Foundation
import Testing
@testable import DarkroomSetup

struct PackageSettingsTests {
    @Test func namesUpcomingFeaturesFromBuildSettings() {
        #expect(PackageSettings.featureName("MEMBER_IMPORT_VISIBILITY") == "MemberImportVisibility")
        #expect(PackageSettings.featureName("NONISOLATED_NONSENDING_BY_DEFAULT") == "NonisolatedNonsendingByDefault")
        #expect(PackageSettings.featureName("IMPORT_OBJC_FORWARD_DECLS") == "ImportObjcForwardDeclarations")
    }

    @Test func carriesOverAnAppTargetsSwiftSettings() {
        let settings = PackageSettings([
            "SWIFT_VERSION": "5.0",
            "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
            "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
            "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
            "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "NO",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
            "MACOSX_DEPLOYMENT_TARGET": "26.2",
        ])
        #expect(settings.swiftSettings == [
            ".swiftLanguageMode(.v5)",
            ".defaultIsolation(MainActor.self)",
            ".enableUpcomingFeature(\"DisableOutwardActorInference\")",
            ".enableUpcomingFeature(\"GlobalActorIsolatedTypesUsability\")",
            ".enableUpcomingFeature(\"InferIsolatedConformances\")",
            ".enableUpcomingFeature(\"InferSendableFromCaptures\")",
            ".enableUpcomingFeature(\"MemberImportVisibility\")",
            ".enableUpcomingFeature(\"NonisolatedNonsendingByDefault\")",
            ".define(\"DEBUG\")",
        ])
        #expect(settings.macOS == "26.2")
        #expect(settings.unmapped.isEmpty)
    }

    @Test func leavesOutFeaturesSwift6HasAlready() {
        let settings = PackageSettings(["SWIFT_VERSION": "6.0", "SWIFT_APPROACHABLE_CONCURRENCY": "YES"])
        #expect(settings.upcomingFeatures == ["InferIsolatedConformances", "NonisolatedNonsendingByDefault"])
    }

    @Test func keepsDarkroomsOwnMinimumAndFlagsWhatItCantCarry() {
        let settings = PackageSettings(["MACOSX_DEPLOYMENT_TARGET": "13.5", "OTHER_SWIFT_FLAGS": "$(inherited) -Xfrontend -warn-long-function-bodies=200"])
        #expect(settings.macOS == "14.0")
        #expect(settings.unmapped == ["OTHER_SWIFT_FLAGS = -Xfrontend -warn-long-function-bodies=200"])
    }
}

struct TargetLayoutTests {
    static let project = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objects = {
                G1 /* Notes */ = { isa = PBXFileSystemSynchronizedRootGroup; exceptions = (E1, E2); path = Notes; sourceTree = "<group>"; };
                E1 /* Exceptions for "Notes" folder in "Notes" target */ = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Info.plist, Debug/Tools.swift); target = T1 /* Notes */; };
                E2 /* Exceptions for "Notes" folder in "NotesTests" target */ = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Model.swift); target = T2 /* NotesTests */; };
                T1 /* Notes */ = { isa = PBXNativeTarget; name = Notes; fileSystemSynchronizedGroups = (G1); packageProductDependencies = (D1, D2, D3); };
                T2 /* NotesTests */ = { isa = PBXNativeTarget; name = NotesTests; };
                P1 = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/example/Markdown.git"; requirement = { kind = upToNextMajorVersion; minimumVersion = 1.2.0; }; };
                P2 = { isa = XCLocalSwiftPackageReference; relativePath = Packages/Store; };
                D1 = { isa = XCSwiftPackageProductDependency; package = P1; productName = Markdown; };
                D2 = { isa = XCSwiftPackageProductDependency; package = P1; productName = MarkdownUI; };
                D3 = { isa = XCSwiftPackageProductDependency; package = P2; productName = Store; };
            };
            rootObject = R1;
        }
        """

    @Test func readsTheTargetsFoldersExceptionsAndPackages() throws {
        let layout = try TargetLayout(target: "Notes", projectFile: Data(Self.project.utf8))
        #expect(layout.folders == ["Notes"])
        #expect(layout.membershipExceptions == ["Notes/Info.plist", "Notes/Debug/Tools.swift"])
        #expect(layout.packages.map(\.identity) == ["markdown", "store"])
        #expect(layout.packages[0].requirement == "from: \"1.2.0\"")
        #expect(layout.packages[0].products == ["Markdown", "MarkdownUI"])
        #expect(layout.packages[1].isLocal)
        #expect(layout.packages[1].location == "Packages/Store")
    }

    @Test func failsForATargetThatIsntThere() {
        #expect(throws: SetupError.self) { try TargetLayout(target: "Widget", projectFile: Data(Self.project.utf8)) }
    }
}

struct SourceScanTests {
    @Test func findsTheEntryPointAndWhatIsntSwift() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [
            "NotesApp.swift": "import SwiftUI\n\n@main\nstruct NotesApp: App {}\n",
            "Views/ContentView.swift": "struct ContentView: View {}\n",
            "Views/Row.swift": "// @main is mentioned, not used\nstruct Row {}\n",
            "Assets.xcassets/Contents.json": "{}",
            "Info.plist": "",
            "Legacy/Bridge.m": "",
        ]
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let scan = try SourceScan(folder)
        #expect(scan.entryPoints == ["NotesApp.swift"])
        #expect(scan.other == ["Assets.xcassets", "Info.plist", "Legacy/Bridge.m"])
        #expect(scan.hasContentView)
    }

    @Test func findsAProjectInASubfolderButNotInBuildOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in ["notes/Notes.xcodeproj", ".build/checkouts/Other.xcodeproj", "Pods/Pods.xcodeproj", "a/b/c/Deep.xcodeproj"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        #expect(xcodeProjects(in: folder).map(\.lastPathComponent) == ["Notes.xcodeproj"])
    }

    @Test func relatesPaths() {
        let from = URL(fileURLWithPath: "/work/notes/tools/shots/Sources/Shots")
        #expect(relativePath(from: from, to: URL(fileURLWithPath: "/work/notes/Notes")) == "../../../../Notes")
        #expect(relativePath(from: URL(fileURLWithPath: "/work/notes"), to: URL(fileURLWithPath: "/work/notes/tools/shots")) == "tools/shots")
    }
}

struct ScaffoldTests {
    @Test func listsEachLeftOutFileOnceUnderItsFirstReason() {
        var scaffold = Scaffold(name: "notes-shots", app: "Notes", settings: PackageSettings([:]), links: ["Notes"], darkroom: .local(path: "/darkroom"))
        scaffold.entryPoints = ["Notes/NotesApp.swift"]
        scaffold.outsideTarget = ["Notes/Info.plist"]
        scaffold.other = ["Notes/Assets.xcassets", "Notes/Info.plist"]
        #expect(scaffold.exclusions.map(\.paths) == [["Notes/NotesApp.swift"], ["Notes/Info.plist"], ["Notes/Assets.xcassets"]])
        #expect(scaffold.packageSwift.contains(".package(path: \"/darkroom\")"))
        #expect(scaffold.packageSwift.components(separatedBy: "\"Notes/Info.plist\"").count == 2)
    }

    @Test func explainsHowToRunTheShots() {
        var scaffold = Scaffold(name: "notes-shots", app: "Notes", settings: PackageSettings([:]), links: ["Notes"], darkroom: .local(path: "/darkroom"))
        #expect(scaffold.readme.contains("swift run notes-shots --list"))
        #expect(scaffold.readme.contains("`Sources/Shots/Notes` links to Notes's sources"))
        #expect(!scaffold.readme.contains("Stand-ins"))
        scaffold.replaced = ["Notes/Sync.swift"]
        #expect(scaffold.readme.contains("Stand-ins"))
    }

    @Test func dependsOnTheAppsPackages() throws {
        var scaffold = Scaffold(name: "notes-shots", app: "Notes", settings: PackageSettings([:]), links: ["Notes"], darkroom: .remote(url: "https://github.com/alxgsv/darkroom", from: "0.1.0"))
        scaffold.packages = try TargetLayout(target: "Notes", projectFile: Data(TargetLayoutTests.project.utf8)).packages
        let text = scaffold.packageSwift
        #expect(text.contains(".package(url: \"https://github.com/alxgsv/darkroom\", from: \"0.1.0\")"))
        #expect(text.contains(".package(url: \"https://github.com/example/Markdown.git\", from: \"1.2.0\")"))
        #expect(text.contains(".product(name: \"MarkdownUI\", package: \"markdown\")"))
        #expect(text.contains(".package(path: \"Packages/Store\")"))
    }
}
