//! Knowledge bases (RAG): documents cut into overlapping passages, embedded with Blablador, searched by
//! cosine similarity and re-ranked. Mirrors KnowledgeBase.swift.

use crate::api::{self, Api};
use crate::model::Citation;
use crate::{extract, storage};
use anyhow::{anyhow, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const CANDIDATES: usize = 24;
pub const RESULTS: usize = 6;
const CHUNK_LENGTH: usize = 1_200;
const CHUNK_OVERLAP: usize = 200;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Document {
    pub id: Uuid,
    pub name: String,
    pub chunks: usize,
    pub added: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct KnowledgeBase {
    pub id: Uuid,
    pub name: String,
    pub documents: Vec<Document>,
    pub embedding_model: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Chunk {
    document: Uuid,
    page: Option<u32>,
    text: String,
}

/// A base's passages and their normalized vectors, `dimension` floats each.
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Store {
    chunks: Vec<Chunk>,
    vectors: Vec<f32>,
    dimension: usize,
}

fn root() -> PathBuf {
    storage::path("Knowledge")
}

fn store_path(id: Uuid) -> PathBuf {
    root().join(format!("{id}.json"))
}

pub fn load_bases() -> Vec<KnowledgeBase> {
    storage::read_json(&root().join("bases.json")).unwrap_or_default()
}

pub fn save_bases(bases: &[KnowledgeBase]) {
    storage::write_json(&root().join("bases.json"), &bases);
}

pub fn load_store(id: Uuid) -> Store {
    storage::read_json(&store_path(id)).unwrap_or_default()
}

fn save_store(id: Uuid, store: &Store) {
    storage::write_json(&store_path(id), store);
}

pub fn delete_base(id: Uuid) {
    let _ = std::fs::remove_file(store_path(id));
}

pub fn remove_document(base: Uuid, document: Uuid) {
    let store = load_store(base);
    let mut kept = Store { dimension: store.dimension, ..Default::default() };
    for (position, chunk) in store.chunks.into_iter().enumerate() {
        if chunk.document != document {
            kept.vectors.extend_from_slice(&store.vectors[position * store.dimension..(position + 1) * store.dimension]);
            kept.chunks.push(chunk);
        }
    }
    save_store(base, &kept);
}

fn normalized(vector: Vec<f32>) -> Vec<f32> {
    let norm = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm > 0.0 { vector.into_iter().map(|v| v / norm).collect() } else { vector }
}

/// Undoes extract.rs's "[Page n]" markers.
fn pages(text: &str) -> Vec<(Option<u32>, String)> {
    let marker = regex::Regex::new(r"(?m)^\[Page (\d+)\]\n").unwrap();
    let matches: Vec<_> = marker.captures_iter(text).collect();
    if matches.is_empty() {
        return vec![(None, text.to_string())];
    }
    matches
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let start = m.get(0).unwrap().end();
            let end = matches.get(i + 1).map(|n| n.get(0).unwrap().start()).unwrap_or(text.len());
            (m[1].parse().ok(), text[start..end].to_string())
        })
        .collect()
}

/// Splits text into overlapping passages, preferring paragraph and sentence boundaries.
pub fn split(text: &str) -> Vec<String> {
    let clean = regex::Regex::new(r"[ \t]+").unwrap().replace_all(text, " ").trim().to_string();
    let chars: Vec<char> = clean.chars().collect();
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < chars.len() {
        let mut end = (start + CHUNK_LENGTH).min(chars.len());
        if end < chars.len() {
            let window: String = chars[start + CHUNK_LENGTH / 2..end].iter().collect();
            let cut = window.rfind("\n\n").map(|i| i + 2).or_else(|| window.rfind(". ").map(|i| i + 2)).or_else(|| window.rfind('\n').map(|i| i + 1));
            if let Some(cut) = cut {
                end = start + CHUNK_LENGTH / 2 + window[..cut].chars().count();
            }
        }
        let chunk: String = chars[start..end].iter().collect::<String>().trim().to_string();
        if chunk.chars().count() > 20 {
            chunks.push(chunk);
        }
        if end >= chars.len() {
            break;
        }
        let next = end.saturating_sub(CHUNK_OVERLAP).max(start);
        start = if next > start { next } else { end };
    }
    chunks
}

/// Blablador answers 500 when a request carries too many tokens, so halve the batch until it fits.
async fn embed(api: &Api, texts: &[String], model: &str) -> Result<Vec<Vec<f32>>> {
    match api.embeddings(texts, model).await {
        Err(error) if api::http_status(&error).is_some_and(|s| s >= 500) && texts.len() > 1 => {
            let middle = texts.len() / 2;
            let mut first = Box::pin(embed(api, &texts[..middle], model)).await?;
            first.extend(Box::pin(embed(api, &texts[middle..], model)).await?);
            Ok(first)
        }
        other => other,
    }
}

/// Reads, splits and embeds a file into a base. `progress` gets a percentage. Returns the new document and the
/// embedding model used (it falls back when the default doesn't answer and nothing is indexed yet).
pub async fn index(api: &Api, base: &KnowledgeBase, file: &Path, progress: impl Fn(u32)) -> Result<(Document, String)> {
    let text = extract::text_of(file)?;
    let name = file.file_name().unwrap_or_default().to_string_lossy().to_string();
    let id = Uuid::new_v4();
    let chunks: Vec<Chunk> = pages(&text)
        .into_iter()
        .flat_map(|(page, text)| split(&text).into_iter().map(move |text| Chunk { document: id, page, text }))
        .collect();
    if chunks.is_empty() {
        return Err(anyhow!("{name} has no text."));
    }
    let mut store = load_store(base.id);
    let mut model = base.embedding_model.clone();
    let mut vectors = Vec::new();
    let mut dimension = 0;
    for (number, batch) in chunks.chunks(4).enumerate() {
        progress((number * 4 * 100 / chunks.len()) as u32);
        let texts: Vec<String> = batch.iter().map(|c| format!("{name}\n{}", c.text)).collect();
        let embeddings = match embed(api, &texts, &model).await {
            Err(error)
                if api::http_status(&error).is_some_and(|s| s >= 500)
                    && vectors.is_empty()
                    && store.chunks.is_empty()
                    && model != api::FALLBACK_EMBEDDING_MODEL =>
            {
                model = api::FALLBACK_EMBEDDING_MODEL.into();
                embed(api, &texts, &model).await?
            }
            other => other?,
        };
        for embedding in embeddings {
            dimension = embedding.len();
            vectors.extend(normalized(embedding));
        }
    }
    if store.dimension != 0 && store.dimension != dimension {
        return Err(anyhow!("Embedding size changed; create a new knowledge base."));
    }
    let count = chunks.len();
    store.chunks.extend(chunks);
    store.vectors.extend(vectors);
    store.dimension = dimension;
    save_store(base.id, &store);
    Ok((Document { id, name, chunks: count, added: Utc::now() }, model))
}

/// The passages most relevant to `query` across `bases`.
pub async fn search(api: &Api, query: &str, bases: &[KnowledgeBase]) -> Result<Vec<Citation>> {
    let mut candidates: Vec<(f32, Citation)> = Vec::new();
    let mut by_model: HashMap<&str, Vec<&KnowledgeBase>> = HashMap::new();
    for base in bases {
        by_model.entry(&base.embedding_model).or_default().push(base);
    }
    for (model, bases) in by_model {
        // Qwen3 embeddings expect an instruction on the query side only.
        let instruction = format!("Instruct: Given a question, retrieve passages from documents that answer it\nQuery: {query}");
        let Some(vector) = api.embeddings(&[instruction], model).await?.into_iter().next() else { continue };
        let vector = normalized(vector);
        for base in bases {
            let store = load_store(base.id);
            if store.dimension != vector.len() || store.chunks.is_empty() {
                continue;
            }
            let names: HashMap<Uuid, &str> = base.documents.iter().map(|d| (d.id, d.name.as_str())).collect();
            for (position, chunk) in store.chunks.iter().enumerate() {
                let row = &store.vectors[position * store.dimension..(position + 1) * store.dimension];
                let score: f32 = row.iter().zip(&vector).map(|(a, b)| a * b).sum();
                let document = names.get(&chunk.document).copied().unwrap_or("Document").to_string();
                candidates.push((score, Citation { document, page: chunk.page, text: chunk.text.clone() }));
            }
        }
    }
    candidates.sort_by(|a, b| b.0.total_cmp(&a.0));
    let top: Vec<Citation> = candidates.into_iter().take(CANDIDATES).map(|(_, c)| c).collect();
    if top.len() <= RESULTS {
        return Ok(top);
    }
    let texts: Vec<String> = top.iter().map(|c| c.text.clone()).collect();
    match api.rerank(query, &texts).await {
        Ok(order) => Ok(order.into_iter().filter_map(|i| top.get(i).cloned()).take(RESULTS).collect()),
        Err(_) => Ok(top.into_iter().take(RESULTS).collect()),
    }
}

/// Context block for the system prompt, numbered [K1], [K2]… to match the citations.
pub fn context(citations: &[Citation]) -> String {
    let passages: Vec<String> = citations
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let page = c.page.map(|p| format!(", page {p}")).unwrap_or_default();
            format!("[K{}] {}{}:\n{}", i + 1, c.document, page, c.text)
        })
        .collect();
    format!(
        "Excerpts from the user's knowledge base that may be relevant to the latest message. Use them to answer and cite them inline as [K1], [K2]. If they don't contain the answer, say so instead of guessing.\n\n{}",
        passages.join("\n\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_with_overlap() {
        let text = "Sentence number one is here. ".repeat(200);
        let chunks = split(&text);
        assert!(chunks.len() > 3);
        assert!(chunks.iter().all(|c| c.chars().count() <= CHUNK_LENGTH));
        assert!(chunks[0].ends_with('.'));
    }

    #[test]
    fn finds_pages() {
        let found = pages("[Page 1]\nfirst\n[Page 3]\nthird\n");
        assert_eq!(found.len(), 2);
        assert_eq!(found[1], (Some(3), "third\n".to_string()));
    }
}
