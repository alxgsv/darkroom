import SwiftUI

/// One picture: a view as the app shows it, at a size, drawn light and dark.
///
/// `Context` is what `develop(_:prepare:finish:)`'s `prepare` makes before
/// the first shot, such as sample data in a temporary folder. Shots without
/// one take no argument.
@MainActor
public struct Shot<Context> {
    public let name: String
    public let about: String
    public let width: CGFloat
    /// Nil fits the view's own height.
    public let height: CGFloat?
    /// A titled window, drawn with its title bar, toolbar and sidebar, as the
    /// window server composites it. Otherwise the view alone.
    public let window: Bool
    let view: (Context) -> AnyView

    public init<V: View>(
        _ name: String, _ about: String = "",
        width: CGFloat, height: CGFloat? = nil, window: Bool = false,
        @ViewBuilder view: @escaping @MainActor (Context) -> V
    ) {
        self.name = name
        self.about = about
        self.width = width
        self.height = height
        self.window = window
        self.view = { AnyView(view($0)) }
    }
}

extension Shot where Context == Void {
    public init<V: View>(
        _ name: String, _ about: String = "",
        width: CGFloat, height: CGFloat? = nil, window: Bool = false,
        @ViewBuilder view: @escaping @MainActor () -> V
    ) {
        self.init(name, about, width: width, height: height, window: window) { _ in view() }
    }
}
