import Foundation

/// What a post *is*.
///
/// Deliberately separate from how it arrived — a forwarded video album replying to something is
/// all four at once, so the modifiers live on ``Post`` rather than being folded in here.
public enum PostKind: String, Codable, Hashable, Sendable {
    case text, photo, album, video, videoNote, audio, voice
    case document, poll, sticker, location, giveaway
    /// The source rendered something we do not recognise. Distinct from `formatSource == .absent`,
    /// which means the source cannot express kind at all.
    case unknown
}

/// Which ingestion source supplied ``Post/kind``.
///
/// Exists because the signal is **TDLib-complete and web-sparse**: of 625 sampled web posts,
/// document, audio, voice, sticker, location and round video appeared zero times. A consumer
/// must be able to tell "this is not a document" from "this source cannot say" — `artanl` falls
/// back to its own inference on `.absent` rather than trusting a default.
public enum FormatSource: String, Codable, Hashable, Sendable {
    case tdlib, web, absent
}
