import SwiftUI

#if canImport(UIKit)
/// A UIKit-backed vertical scroll view that wraps SwiftUI content.
///
/// Unlike SwiftUI's `ScrollView`, this uses `UIScrollView` directly, which allows
/// nested same-direction scrolling to coexist with a parent SwiftUI `ScrollView`.
/// UIKit's `UIScrollView` handles gesture recognition independently, so a vertical
/// `UIKitScrollView` inside a vertical SwiftUI `ScrollView` will both scroll correctly —
/// the inner view scrolls first, and once it reaches its bounds, the outer view takes over.
struct UIKitScrollView<Content: View>: UIViewRepresentable {
    let axes: Axis.Set
    let content: Content

    init(axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = axes.contains(.vertical)
        scrollView.alwaysBounceHorizontal = axes.contains(.horizontal)
        scrollView.showsVerticalScrollIndicator = axes.contains(.vertical)
        scrollView.showsHorizontalScrollIndicator = axes.contains(.horizontal)

        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        scrollView.addSubview(hostingController.view)
        context.coordinator.hostingController = hostingController

        let contentView = hostingController.view!

        // Pin hosted content to scroll view's content layout guide
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
        ])

        // Content width matches scroll view width (vertical scroll only, no horizontal)
        contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController?.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var hostingController: UIHostingController<Content>?
    }
}
#endif
