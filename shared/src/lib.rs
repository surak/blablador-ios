//! What each Blablador model is for.
//!
//! `/v1/models` lists everything the router serves — chat models next to embedders, image and video models and
//! the molecular job APIs — and tells you nothing about which is which. Both the desktop app and `bla` need the
//! same answer to "can I chat with this?" and "which model draws a picture?", so the answer lives here once.
//!
//! The same table is `RemoteModel.isChatCapable` and `BlabladorAPI`'s constants in the Swift apps, and
//! `BlabladorApi` on Android. Keep the four in step.

#![forbid(unsafe_code)]

/// The five molecular job APIs: their protocol, forms and the check on what they hand back.
pub mod molecular;

/// The default chat model.
pub const DEFAULT_MODEL: &str = "deepseek-v4.1-flash-at-hzdr";
/// Blablador's quick model for small jobs: chat titles, picking out memories.
pub const FAST_MODEL: &str = "alias-fast";
/// Text to image. Only the second can edit a picture it is given.
pub const IMAGE_MODELS: &[&str] = &["alias-flux2", "alias-image"];
pub const IMAGE_EDIT_MODEL: &str = "alias-image";
/// Text to video with sound (MiniMax-H3).
pub const VIDEO_MODEL: &str = "alias-video";
/// Drama 3 speech, including cloned voices.
pub const SPEECH_MODEL: &str = "alias-voice-drama3";
pub const TRANSCRIPTION_MODEL: &str = "faster-whisper-large-v3";
pub const EMBEDDING_MODEL: &str = "alias-qwen3-4b-embeddings";
pub const RERANK_MODEL: &str = "alias-qwen3-4b-reranker";
/// LightOnOCR, for pictures of text.
pub const OCR_MODEL: &str = "alias-ocr";
/// VGGT-Ω: photos of a place in, a map and a point cloud out.
pub const VISUAL_GEOMETRY_MODEL: &str = "alias-visual-geometry";

/// The molecular models: asynchronous job APIs over `POST /responses`, not completions. A request queues work
/// that runs for minutes to hours, so they must never be offered as chat models.
pub const MOLECULAR_MODELS: &[&str] = &[
    "alias-esmfold2",
    "alias-bioemu2",
    "alias-rfdiffusion3",
    "alias-bindcraft",
    "alias-proteina-complexa",
];

/// What a model is good for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Chat,
    Image,
    Video,
    Speech,
    Transcription,
    Embedding,
    Rerank,
    Ocr,
    VisualGeometry,
    /// Folding, designing and sampling proteins. A job API, not a conversation.
    Molecular,
    /// Serves some other purpose; whatever it is, it isn't a conversation.
    Other,
}

impl Kind {
    /// What to call it in a list.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Chat => "chat",
            Kind::Image => "image",
            Kind::Video => "video",
            Kind::Speech => "speech",
            Kind::Transcription => "transcription",
            Kind::Embedding => "embeddings",
            Kind::Rerank => "reranking",
            Kind::Ocr => "OCR",
            Kind::VisualGeometry => "3D from photos",
            Kind::Molecular => "molecular (a job, not a chat)",
            Kind::Other => "not for chatting",
        }
    }
}

/// What this model id is for. Named models are matched first, because the loose rules below would misread some
/// of them — `alias-fast` and `alias-visual-geometry` are both ordinary chat completions underneath.
pub fn kind(id: &str) -> Kind {
    let lower = id.to_ascii_lowercase();
    if MOLECULAR_MODELS.contains(&lower.as_str()) {
        return Kind::Molecular;
    }
    if lower == VISUAL_GEOMETRY_MODEL {
        return Kind::VisualGeometry;
    }
    if lower == OCR_MODEL {
        return Kind::Ocr;
    }
    if lower == VIDEO_MODEL || lower.contains("video") {
        return Kind::Video;
    }
    if lower.contains("rerank") {
        return Kind::Rerank;
    }
    if lower.contains("embedding") {
        return Kind::Embedding;
    }
    if lower.contains("whisper") {
        return Kind::Transcription;
    }
    if lower.contains("voice") {
        return Kind::Speech;
    }
    if lower.contains("flux") || lower.contains("image") {
        return Kind::Image;
    }
    if lower.contains("davinci") || lower.contains("anonymizer") {
        return Kind::Other;
    }
    Kind::Chat
}

/// Whether a model can hold a conversation. Everything else in `/v1/models` is a tool of some other kind.
pub fn is_chat_capable(id: &str) -> bool {
    kind(id) == Kind::Chat
}

/// The chat models out of a `/v1/models` listing, in the order the router gave them.
pub fn chat_models<'a, I: IntoIterator<Item = &'a str>>(ids: I) -> Vec<&'a str> {
    ids.into_iter().filter(|id| is_chat_capable(id)).collect()
}

/// The image models the endpoint actually serves, in our order of preference.
pub fn image_models<'a>(ids: &'a [String]) -> Vec<&'a str> {
    IMAGE_MODELS
        .iter()
        .filter_map(|wanted| ids.iter().find(|id| id.eq_ignore_ascii_case(wanted)).map(|id| id.as_str()))
        .collect()
}

/// The model for small jobs: `alias-fast` on Blablador, the chat's own model anywhere else.
pub fn helper_model<'a>(endpoint: &str, chat_model: &'a str) -> &'a str {
    if endpoint.trim().trim_end_matches('/') == "https://api.blablador.fz-juelich.de/v1" {
        FAST_MODEL
    } else {
        chat_model
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn molecular_models_are_never_chat_models() {
        for id in MOLECULAR_MODELS {
            assert_eq!(kind(id), Kind::Molecular, "{id}");
            assert!(!is_chat_capable(id), "{id}");
            assert!(!is_chat_capable(&id.to_uppercase()), "{id} in capitals");
        }
    }

    #[test]
    fn ordinary_alias_models_still_chat() {
        // The giveaway is the name, not the "alias-" prefix.
        assert!(is_chat_capable(FAST_MODEL));
        assert!(is_chat_capable(DEFAULT_MODEL));
        assert!(is_chat_capable("alias-large"));
        assert_eq!(kind(VISUAL_GEOMETRY_MODEL), Kind::VisualGeometry);
    }

    #[test]
    fn tools_are_sorted_by_what_they_do() {
        assert_eq!(kind("alias-flux2"), Kind::Image);
        assert_eq!(kind("alias-video"), Kind::Video);
        assert_eq!(kind("alias-voice-drama3"), Kind::Speech);
        assert_eq!(kind("faster-whisper-large-v3"), Kind::Transcription);
        assert_eq!(kind("alias-qwen3-4b-embeddings"), Kind::Embedding);
        assert_eq!(kind("alias-qwen3-4b-reranker"), Kind::Rerank);
        assert_eq!(kind("alias-ocr"), Kind::Ocr);
    }

    #[test]
    fn picks_chat_and_image_models_out_of_a_listing() {
        let listing = ["alias-fast", "alias-esmfold2", "alias-flux2", "alias-qwen3-4b-embeddings"];
        assert_eq!(chat_models(listing), vec!["alias-fast"]);
        let owned: Vec<String> = listing.iter().map(|s| s.to_string()).collect();
        assert_eq!(image_models(&owned), vec!["alias-flux2"]);
    }

    #[test]
    fn helper_model_is_the_chat_model_off_blablador() {
        assert_eq!(helper_model("https://api.blablador.fz-juelich.de/v1/", "mine"), FAST_MODEL);
        assert_eq!(helper_model("http://localhost:8000/v1", "mine"), "mine");
    }
}
