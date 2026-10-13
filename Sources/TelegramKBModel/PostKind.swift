import Foundation

/// What a post *is*.
///
/// Deliberately separate from how it arrived — a forwarded video album replying to something is
/// all four at once, so the modifiers live on ``Post`` rather than being folded in here.
///
/// `CaseIterable` because two surfaces list the kinds — `tgkb_search_posts`' schema and
/// `tgkb query --kind`'s help — and both derive the list from here. Declaration order is the
/// order a client sees in the schema's `enum`.
public enum PostKind: String, Codable, Hashable, Sendable, CaseIterable {
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
    /// A chat export written by a Telegram client and loaded with `tgkb import`. The export marks
    /// up every media type it writes — a file, a voice message, a sticker — so `kind` is as
    /// complete as TDLib's, and it is the only source that reaches a group without logging in.
    case export
}
