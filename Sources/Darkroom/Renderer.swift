import AppKit
import ScreenCaptureKit
import SwiftUI

/// Hosts a shot in a window far off screen, which never shows, and draws it
/// into a PNG.
@MainActor
enum Renderer {
    static func render<Context>(_ shot: Shot<Context>, context: Context, dark: Bool, wait: Duration) async throws -> Data {
        // Filling the window keeps it at the shot's size; the hosting view
        // would shrink it to a smaller view. A view's cached display leaves
        // out the window's own background.
        let hosting = NSHostingView(rootView: shot.view(context)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: shot.width, height: shot.height ?? 1000),
            styleMask: shot.window ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        // `.task` loads land in this time.
        try await Task.sleep(for: wait)
        var size = hosting.frame.size
        if shot.height == nil {
            size = NSSize(width: shot.width, height: hosting.fittingSize.height)
        }
        // The first window's lists keep the row heights they had before their
        // data came in, until the window is resized.
        window.setContentSize(NSSize(width: size.width + 1, height: size.height))
        try await Task.sleep(for: .milliseconds(200))
        window.setContentSize(size)
        try await Task.sleep(for: .milliseconds(300))
        if shot.window, #available(macOS 14.4, *) {
            return try await capture(window, shot: shot.name)
        }
        return try draw(hosting, shot: shot.name)
    }

    /// The window as the window server draws it: its title bar, toolbar and
    /// glass, which a view's cached display leaves out or blanks. A process
    /// may capture its own titled windows without the Screen Recording
    /// permission; borderless ones fail.
    @available(macOS 14.4, *)
    private static func capture(_ window: NSWindow, shot: String) async throws -> Data {
        let content = try await SCShareableContent.currentProcess
        guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw DarkroomError.render(shot)
        }
        let filter = SCContentFilter(desktopIndependentWindow: shared)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DarkroomError.render(shot)
        }
        return png
    }

    /// The view the way AppKit caches its display.
    private static func draw(_ view: NSView, shot: String) throws -> Data {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DarkroomError.render(shot)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw DarkroomError.render(shot)
        }
        return png
    }
}
