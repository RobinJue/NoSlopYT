import SwiftUI
import UIKit

/// An image loaded from the network. It fills whatever frame its parent gives it (clipped, centred) and shows a
/// neutral placeholder until the pixels arrive, so a list never jumps.
///
/// Loading goes through `URLSession.shared`, whose `URLCache` (configured at launch) keeps the encoded bytes on
/// disk; decoded images are additionally kept in an in-memory `NSCache` so scrolling back is instant.
struct RemoteImage: View {
    let url: URL?
    let contentMode: ContentMode

    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        // A cache hit is shown on the first frame, without a placeholder flash.
        _image = State(initialValue: url.flatMap { RemoteImageCache.shared.image(for: $0) })
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle().fill(Color(.secondarySystemFill))
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if let cached = RemoteImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = nil
        guard let loaded = await RemoteImageCache.fetch(url), !Task.isCancelled else { return }
        RemoteImageCache.shared.insert(loaded, for: url)
        image = loaded
    }
}

/// Decoded images by URL, bounded by count and by approximate decoded size.
@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let storage: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    func image(for url: URL) -> UIImage? {
        storage.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        storage.setObject(image, forKey: url as NSURL, cost: Int(pixels * 4))
    }

    /// Downloads and decodes the image; nil on any failure (the placeholder stays).
    static func fetch(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let decoded = UIImage(data: data) else { return nil }
        // Decode off the main thread so scrolling never waits for it.
        return await decoded.byPreparingForDisplay() ?? decoded
    }
}

#Preview {
    RemoteImage(url: URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"))
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .padding()
}
