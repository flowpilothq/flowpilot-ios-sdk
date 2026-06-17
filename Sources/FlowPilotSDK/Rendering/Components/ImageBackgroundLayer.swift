import SwiftUI

// MARK: - Image Background Layer

struct ImageBackgroundLayer: View {
    let image: ImageBackground

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: URL(string: image.src)) { phase in
                switch phase {
                case .success(let img):
                    img
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(
                            width: frameWidth(in: geo.size),
                            height: frameHeight(in: geo.size)
                        )
                        .position(
                            x: geo.size.width * (image.positionX ?? 50) / 100,
                            y: geo.size.height * (image.positionY ?? 50) / 100
                        )
                        .blur(radius: image.blur ?? 0)
                        // Scale up slightly when blurred to avoid visible edges
                        .scaleEffect(image.blur ?? 0 > 0 ? 1.1 : 1.0)

                case .failure:
                    Color.clear

                case .empty:
                    Color.clear

                @unknown default:
                    Color.clear
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var contentMode: ContentMode {
        switch image.fit {
        case .cover: return .fill
        case .contain: return .fit
        case .fill: return .fill
        case .tile: return .fit
        }
    }

    private func frameWidth(in size: CGSize) -> CGFloat? {
        image.fit == .fill ? size.width : nil
    }

    private func frameHeight(in size: CGSize) -> CGFloat? {
        image.fit == .fill ? size.height : nil
    }
}
