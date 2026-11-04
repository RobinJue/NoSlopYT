import Foundation

/// What a download keeps next to the video file so that it plays the way a streamed video does when there is no
/// connection: SponsorBlock auto-skip and the coloured marks in the seek bar, chapters, and captions.
///
/// All of it is public data about the video, fetched when the download starts (the device is online then). It is kept per
/// video, not per download: the qualities and the audio-only copy of one video share it. Each part is optional because
/// "not known" is not "none": a lookup that failed leaves its part nil, and the player then asks live as it always did,
/// while an empty list says that YouTube or SponsorBlock was asked and has nothing.
///
/// - `segments` are the SponsorBlock segments of every category, not only the ones the settings skip today: what to do
///   with each is decided when the video plays, so a later change of the settings still applies to a download. They are
///   only asked for while SponsorBlock is switched on; a download started with it off has none (not known).
/// - `chapters` are the ones the watch page shows.
/// - `captions` are caption tracks with their text, at least the one captions open with (see `CaptionTrackChoice`).
public struct DownloadExtras: Codable, Equatable, Sendable {
    public var segments: [SponsorSegment]?
    public var chapters: [Chapter]?
    public var captions: [StoredCaptions]?

    public init(segments: [SponsorSegment]? = nil, chapters: [Chapter]? = nil, captions: [StoredCaptions]? = nil) {
        self.segments = segments
        self.chapters = chapters
        self.captions = captions
    }

    /// How many caption tracks a download's extras may hold once the player adds the ones the viewer opens while the download
    /// plays online: a video with many languages does not grow a file of megabytes.
    public static let maxKeptCaptionTracks = 6

    /// Nothing is known: no part has an answer, not even an empty one.
    public var isEmpty: Bool {
        segments == nil && chapters == nil && captions == nil
    }

    /// These extras with what `newer` knows put over them. A part that `newer` does not know stays as it is, so a lookup
    /// that failed this time does not cost what an earlier one found. The segments and the chapters of `newer` replace
    /// the old ones (what is asked live is right, even when it is shorter); captions are replaced per track, and an empty
    /// list (the video has none) replaces all of them.
    public func merging(_ newer: DownloadExtras) -> DownloadExtras {
        DownloadExtras(
            segments: newer.segments ?? segments,
            chapters: newer.chapters ?? chapters,
            captions: Self.merged(captions, with: newer.captions)
        )
    }

    private static func merged(_ older: [StoredCaptions]?, with newer: [StoredCaptions]?) -> [StoredCaptions]? {
        guard let newer else { return older }
        guard !newer.isEmpty, let older, !older.isEmpty else { return newer }
        let replaced = Set(newer.map(\.track.id))
        return newer + older.filter { !replaced.contains($0.track.id) }
    }

    // MARK: Captions

    /// The caption tracks that have their text in here.
    public var captionTracks: [CaptionTrack] {
        (captions ?? []).map(\.track)
    }

    /// The text of `track`, if it is in here. Tracks are told apart by language and kind (`CaptionTrack.id`), not by
    /// address: the address is signed and runs out, the text does not.
    public func cues(for track: CaptionTrack) -> [CaptionCue]? {
        captions?.first { $0.track.id == track.id }?.cues
    }

    /// The tracks the player offers while it plays a download: those that the download kept the text of, which also work
    /// without a connection, then the live ones it does not have (once the stream info has arrived, `live` is not nil).
    /// A track that is both is the kept one, so a picker that holds the choice by value does not lose it when the live
    /// list arrives.
    public static func captionTracks(live: [CaptionTrack]?, kept: [CaptionTrack]) -> [CaptionTrack] {
        guard !kept.isEmpty else { return live ?? [] }
        let keptIDs = Set(kept.map(\.id))
        return kept + (live ?? []).filter { !keptIDs.contains($0.id) }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case segments, chapters, captions
    }

    /// Every key is optional, and a list keeps the elements that can be read: a sidecar written by another version, or
    /// with one damaged entry, still gives the rest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = Self.list(SponsorSegment.self, in: container, forKey: .segments)
        chapters = Self.list(Chapter.self, in: container, forKey: .chapters)
        captions = Self.list(StoredCaptions.self, in: container, forKey: .captions)
    }

    private static func list<Element: Decodable>(
        _ type: Element.Type,
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [Element]? {
        guard let elements = try? container.decodeIfPresent([Lossy<Element>].self, forKey: key) else { return nil }
        return elements.compactMap(\.value)
    }
}

/// A caption track with its text.
public struct StoredCaptions: Codable, Equatable, Sendable {
    public var track: CaptionTrack
    public var cues: [CaptionCue]

    public init(track: CaptionTrack, cues: [CaptionCue]) {
        self.track = track
        self.cues = cues
    }

    private enum CodingKeys: String, CodingKey {
        case track, cues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decode(CaptionTrack.self, forKey: .track)
        cues = (try? container.decodeIfPresent([Lossy<CaptionCue>].self, forKey: .cues))?.compactMap(\.value) ?? []
    }
}

/// An array element that decodes to nil instead of failing, so that the others still decode.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: any Decoder) throws {
        value = try? Element(from: decoder)
    }
}
