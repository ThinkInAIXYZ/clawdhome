use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::commands::fs::read_file;
use crate::commands::vectorstore::vector_search;

const DEFAULT_MAX_RESULTS: usize = 10;
const DEFAULT_MAX_RELATED_ITEMS: usize = 5;
const MAX_RESULTS: usize = 50;
const MAX_RELATED_ITEMS: usize = 10;
const MAX_RELATED_CONTENT_CHARS: usize = 12_000;
const SNIPPET_CONTEXT: usize = 80;
const MAX_RAG_HIGHLIGHTS: usize = 12;
const STOP_WORDS: &[&str] = &[
    "的", "是", "了", "什么", "在", "有", "和", "与", "对", "从", "the", "is", "a", "an", "what",
    "how", "are", "was", "were", "do", "does", "did", "be", "been", "being", "have", "has", "had",
    "it", "its", "in", "on", "at", "to", "for", "of", "with", "by", "this", "that", "these",
    "those",
];
const SUMMARY_SECTION_KEYWORDS: &[&str] = &[
    "概述",
    "定义",
    "摘要",
    "简介",
    "总结",
    "overview",
    "summary",
    "definition",
    "introduction",
];
const RAG_RELATED_KEYWORDS: &[&str] = &[
    "rag",
    "检索增强生成",
    "检索增强",
    "retrieval",
    "vector",
    "embedding",
    "嵌入",
    "向量",
    "权限",
    "脱敏",
    "加密",
    "graphrag",
    "知识图谱",
    "知识库污染",
    "知识杀毒",
    "安全围栏",
    "提示词注入",
    "敏感数据",
    "rbac",
    "审计",
    "hybrid",
    "rerank",
    "重排",
    "bm25",
];

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum SearchQueryInput {
    Single(String),
    Multiple(Vec<String>),
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnowledgeBaseRankingOptions {
    pub ranker: Option<String>,
    pub score_threshold: Option<f32>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct KnowledgeBaseEmbeddingConfig {
    pub enabled: bool,
    pub endpoint: String,
    #[serde(rename = "apiKey")]
    pub api_key: String,
    pub model: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct KnowledgeBaseQueryExtensions {
    pub retrieval_mode: Option<String>,
    pub embedding_config: Option<KnowledgeBaseEmbeddingConfig>,
    pub allowed_path_prefixes: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnowledgeBaseDocumentExtensions {
    pub allowed_path_prefixes: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum KnowledgeBaseFilter {
    Compound(KnowledgeBaseCompoundFilter),
    Comparison(KnowledgeBaseComparisonFilter),
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnowledgeBaseCompoundFilter {
    #[serde(rename = "type")]
    pub operator: String,
    pub filters: Vec<KnowledgeBaseFilter>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnowledgeBaseComparisonFilter {
    pub key: String,
    #[serde(rename = "type")]
    pub operator: String,
    pub value: Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnowledgeBaseQueryRequest {
    pub query: SearchQueryInput,
    pub filters: Option<KnowledgeBaseFilter>,
    pub max_num_results: Option<usize>,
    pub ranking_options: Option<KnowledgeBaseRankingOptions>,
    pub rewrite_query: Option<bool>,
    pub extensions: Option<KnowledgeBaseQueryExtensions>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct KnowledgeBaseDocumentRequest {
    #[serde(rename = "fileId")]
    pub file_id: Option<String>,
    pub path: Option<String>,
    pub filename: Option<String>,
    pub directory: Option<String>,
    pub source: Option<String>,
    pub max_related_items: Option<usize>,
    pub include_related_content: Option<bool>,
    pub extensions: Option<KnowledgeBaseDocumentExtensions>,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseContentChunk {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseQueryResultAttributes {
    pub path: String,
    pub title: String,
    pub source: String,
    pub directory: String,
    #[serde(rename = "type")]
    pub doc_type: String,
    pub title_match: bool,
    pub retrieval_mode: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseQueryResultItem {
    pub file_id: String,
    pub filename: String,
    pub score: f32,
    pub attributes: KnowledgeBaseQueryResultAttributes,
    pub content: Vec<KnowledgeBaseContentChunk>,
    pub summary: String,
    pub rag_related_info: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseQueryResponse {
    pub object: &'static str,
    pub search_query: Vec<String>,
    pub data: Vec<KnowledgeBaseQueryResultItem>,
    pub has_more: bool,
    pub next_page: Option<String>,
    pub summary: String,
    pub rag_related_info: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseDocumentAttributes {
    pub path: String,
    pub title: String,
    pub source: String,
    pub directory: String,
    #[serde(rename = "type")]
    pub doc_type: String,
    pub tags: Vec<String>,
    pub sources: Vec<String>,
    pub related: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseDocumentItem {
    pub file_id: String,
    pub filename: String,
    pub attributes: KnowledgeBaseDocumentAttributes,
    pub content_text: String,
    pub summary: String,
    pub rag_related_info: Vec<String>,
    pub outbound_wikilinks: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseRelatedDocumentItem {
    pub file_id: String,
    pub filename: String,
    pub score: f32,
    pub relation_reasons: Vec<String>,
    pub attributes: KnowledgeBaseDocumentAttributes,
    pub content_preview: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_text: Option<String>,
    pub summary: String,
    pub rag_related_info: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBaseDocumentResponse {
    pub object: &'static str,
    pub document: KnowledgeBaseDocumentItem,
    pub related: Vec<KnowledgeBaseRelatedDocumentItem>,
}

#[derive(Debug, Clone, Deserialize)]
struct HttpKnowledgeBaseQueryPayload {
    #[serde(rename = "projectPath")]
    project_path: Option<String>,
    #[serde(flatten)]
    request: KnowledgeBaseQueryRequest,
}

#[derive(Debug, Clone, Deserialize)]
struct HttpKnowledgeBaseDocumentPayload {
    #[serde(rename = "projectPath")]
    project_path: Option<String>,
    #[serde(flatten)]
    request: KnowledgeBaseDocumentRequest,
}

#[derive(Debug, Clone)]
pub struct HttpQueryError {
    pub status: u16,
    pub message: String,
}

#[derive(Debug, Clone)]
struct ParsedFrontmatter {
    title: Option<String>,
    doc_type: Option<String>,
    tags: Vec<String>,
    sources: Vec<String>,
    related: Vec<String>,
}

#[derive(Debug, Clone)]
struct MarkdownSection {
    heading: String,
    lines: Vec<String>,
}

#[derive(Debug, Clone)]
struct KnowledgeBaseDocument {
    relative_path: String,
    filename: String,
    title: String,
    content: String,
    source: String,
    directory: String,
    doc_type: String,
    tags: Vec<String>,
    sources: Vec<String>,
    related: Vec<String>,
    filter_attributes: Map<String, Value>,
}

#[derive(Debug, Clone)]
struct CandidateResult {
    document: KnowledgeBaseDocument,
    keyword_score: f32,
    semantic_score: f32,
    title_match: bool,
    snippet: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RetrievalMode {
    Keyword,
    Vector,
    Hybrid,
}

#[derive(Debug, Clone)]
struct RelatedDocumentCandidate {
    document: KnowledgeBaseDocument,
    score: f32,
    reasons: Vec<String>,
}

#[tauri::command]
pub async fn knowledge_base_query(
    project_path: String,
    request: KnowledgeBaseQueryRequest,
) -> Result<KnowledgeBaseQueryResponse, String> {
    query_knowledge_base_internal(&project_path, request)
        .await
        .map_err(|error| error.message)
}

#[tauri::command]
pub fn knowledge_base_document(
    project_path: String,
    request: KnowledgeBaseDocumentRequest,
) -> Result<KnowledgeBaseDocumentResponse, String> {
    get_knowledge_base_document_internal(&project_path, request).map_err(|error| error.message)
}

pub fn handle_http_query(
    body: &str,
    fallback_project_path: Option<&str>,
) -> Result<KnowledgeBaseQueryResponse, HttpQueryError> {
    let payload: HttpKnowledgeBaseQueryPayload =
        serde_json::from_str(body).map_err(|error| HttpQueryError {
            status: 400,
            message: format!("Invalid JSON: {error}"),
        })?;

    let project_path = payload
        .project_path
        .filter(|value| !value.trim().is_empty())
        .or_else(|| fallback_project_path.map(|value| value.to_string()))
        .ok_or_else(|| HttpQueryError {
            status: 400,
            message: "projectPath is required (set via POST /project or include in request body)"
                .to_string(),
        })?;

    tauri::async_runtime::block_on(query_knowledge_base_internal(
        &project_path,
        payload.request,
    ))
}

pub fn handle_http_document(
    body: &str,
    fallback_project_path: Option<&str>,
) -> Result<KnowledgeBaseDocumentResponse, HttpQueryError> {
    let payload: HttpKnowledgeBaseDocumentPayload =
        serde_json::from_str(body).map_err(|error| HttpQueryError {
            status: 400,
            message: format!("Invalid JSON: {error}"),
        })?;

    let project_path = payload
        .project_path
        .filter(|value| !value.trim().is_empty())
        .or_else(|| fallback_project_path.map(|value| value.to_string()))
        .ok_or_else(|| HttpQueryError {
            status: 400,
            message: "projectPath is required (set via POST /project or include in request body)"
                .to_string(),
        })?;

    get_knowledge_base_document_internal(&project_path, payload.request)
}

pub fn validate_project_path_input(project_path: &str) -> Result<(), String> {
    validate_project_path(project_path).map_err(|error| error.message)
}

pub fn normalize_ingest_source_path_input(
    project_path: &str,
    source_path: &str,
) -> Result<String, String> {
    validate_project_path(project_path).map_err(|error| error.message.clone())?;

    let trimmed = source_path.trim();
    if trimmed.is_empty() {
        return Err("sourcePath is required".to_string());
    }

    let project_root = Path::new(project_path);
    let sources_root = project_root.join("raw").join("sources");
    let candidate = if Path::new(trimmed).is_absolute() {
        PathBuf::from(trimmed)
    } else {
        project_root.join(trimmed)
    };

    if !candidate.exists() {
        return Err(format!("sourcePath does not exist: {}", candidate.display()));
    }
    if !candidate.is_file() {
        return Err(format!("sourcePath is not a file: {}", candidate.display()));
    }

    let lexical_candidate = normalize_path_lexically(&candidate);
    let lexical_sources_root = normalize_path_lexically(&sources_root);
    if !lexical_candidate.starts_with(&lexical_sources_root) {
        return Err(format!(
            "sourcePath must be inside project raw/sources: {}",
            candidate.display()
        ));
    }

    Ok(candidate.to_string_lossy().to_string())
}

fn normalize_path_lexically(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            std::path::Component::RootDir => normalized.push(component.as_os_str()),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            std::path::Component::Normal(value) => normalized.push(value),
        }
    }
    normalized
}

async fn query_knowledge_base_internal(
    project_path: &str,
    request: KnowledgeBaseQueryRequest,
) -> Result<KnowledgeBaseQueryResponse, HttpQueryError> {
    validate_project_path(project_path)?;
    let queries = normalize_search_queries(&request.query);
    if queries.is_empty() {
        return Ok(empty_response());
    }

    let max_num_results = clamp_max_num_results(request.max_num_results, DEFAULT_MAX_RESULTS);
    let score_threshold = normalize_score(
        request
            .ranking_options
            .as_ref()
            .and_then(|options| options.score_threshold)
            .unwrap_or(0.0),
    );
    let retrieval_mode = resolve_retrieval_mode(request.extensions.as_ref())?;
    let embedding_config = normalize_embedding_config(request.extensions.as_ref());

    let documents =
        load_knowledge_base_documents(project_path).map_err(|error| HttpQueryError {
            status: 500,
            message: error,
        })?;
    let allowed_path_prefixes =
        normalize_allowed_path_prefixes(project_path, request.extensions.as_ref());
    let documents = filter_documents_by_allowed_prefixes(documents, &allowed_path_prefixes);
    let mut candidates: HashMap<String, CandidateResult> = HashMap::new();

    if retrieval_mode != RetrievalMode::Vector {
        for query in &queries {
            apply_keyword_matches(query, &documents, request.filters.as_ref(), &mut candidates);
        }
    }

    if retrieval_mode != RetrievalMode::Keyword {
        if let Some(config) = embedding_config.as_ref() {
            apply_semantic_matches(
                project_path,
                &queries,
                &documents,
                request.filters.as_ref(),
                config,
                max_num_results,
                &mut candidates,
            )
            .await?;
        }
    }

    let mut ranked: Vec<KnowledgeBaseQueryResultItem> = candidates
        .into_values()
        .map(to_result_item)
        .filter(|item| item.score >= score_threshold)
        .collect();

    ranked.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                right
                    .attributes
                    .title_match
                    .cmp(&left.attributes.title_match)
            })
            .then_with(|| left.file_id.cmp(&right.file_id))
    });

    let has_more = ranked.len() > max_num_results;
    ranked.truncate(max_num_results);

    Ok(KnowledgeBaseQueryResponse {
        object: "vector_store.search_results.page",
        search_query: queries,
        summary: build_response_summary(&ranked),
        rag_related_info: collect_response_rag_related_info(&ranked),
        data: ranked,
        has_more,
        next_page: None,
    })
}

fn get_knowledge_base_document_internal(
    project_path: &str,
    request: KnowledgeBaseDocumentRequest,
) -> Result<KnowledgeBaseDocumentResponse, HttpQueryError> {
    validate_project_path(project_path)?;
    let documents =
        load_knowledge_base_documents(project_path).map_err(|error| HttpQueryError {
            status: 500,
            message: error,
        })?;
    let allowed_path_prefixes =
        normalize_document_allowed_path_prefixes(project_path, request.extensions.as_ref());
    let documents = filter_documents_by_allowed_prefixes(documents, &allowed_path_prefixes);

    let target = resolve_document_request(project_path, &documents, &request)?;
    let max_related_items = clamp_max_related_items(request.max_related_items);
    let include_related_content = request.include_related_content.unwrap_or(false);

    Ok(build_document_response(
        &target,
        &documents,
        max_related_items,
        include_related_content,
    ))
}

fn resolve_document_request(
    project_path: &str,
    documents: &[KnowledgeBaseDocument],
    request: &KnowledgeBaseDocumentRequest,
) -> Result<KnowledgeBaseDocument, HttpQueryError> {
    if let Some(identifier) = request
        .file_id
        .as_ref()
        .or(request.path.as_ref())
        .map(|value| normalize_requested_document_path(project_path, value))
        .filter(|value| !value.is_empty())
    {
        return documents
            .iter()
            .find(|document| document.relative_path == identifier)
            .cloned()
            .ok_or_else(|| HttpQueryError {
                status: 404,
                message: format!("Document not found for path '{}'", identifier),
            });
    }

    let filename = request
        .filename
        .as_ref()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| HttpQueryError {
            status: 400,
            message: "fileId, path, or filename is required".to_string(),
        })?;

    let directory_filter = request
        .directory
        .as_ref()
        .map(|value| normalize_path(value.trim()))
        .filter(|value| !value.is_empty());
    let source_filter = request
        .source
        .as_ref()
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty());

    let matches: Vec<KnowledgeBaseDocument> = documents
        .iter()
        .filter(|document| document.filename == filename)
        .filter(|document| {
            directory_filter
                .as_ref()
                .is_none_or(|directory| document.directory == *directory)
        })
        .filter(|document| {
            source_filter
                .as_ref()
                .is_none_or(|source| document.source.eq_ignore_ascii_case(source))
        })
        .cloned()
        .collect();

    match matches.len() {
        0 => Err(HttpQueryError {
            status: 404,
            message: format!("Document not found for filename '{}'", filename),
        }),
        1 => Ok(matches[0].clone()),
        _ => Err(HttpQueryError {
            status: 409,
            message: format!(
                "Multiple documents match filename '{}'. Provide fileId or path. Candidates: {}",
                filename,
                matches
                    .iter()
                    .map(|document| document.relative_path.clone())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }),
    }
}

fn build_document_response(
    target: &KnowledgeBaseDocument,
    documents: &[KnowledgeBaseDocument],
    max_related_items: usize,
    include_related_content: bool,
) -> KnowledgeBaseDocumentResponse {
    KnowledgeBaseDocumentResponse {
        object: "vector_store.document",
        document: KnowledgeBaseDocumentItem {
            file_id: target.relative_path.clone(),
            filename: target.filename.clone(),
            attributes: document_attributes(target),
            content_text: target.content.clone(),
            summary: extract_document_summary(&target.content, &target.title),
            rag_related_info: extract_rag_related_info(&target.content, &target.title),
            outbound_wikilinks: extract_wikilink_targets(&target.content),
        },
        related: collect_related_documents(
            target,
            documents,
            max_related_items,
            include_related_content,
        ),
    }
}

fn document_attributes(document: &KnowledgeBaseDocument) -> KnowledgeBaseDocumentAttributes {
    KnowledgeBaseDocumentAttributes {
        path: document.relative_path.clone(),
        title: document.title.clone(),
        source: document.source.clone(),
        directory: document.directory.clone(),
        doc_type: document.doc_type.clone(),
        tags: document.tags.clone(),
        sources: document.sources.clone(),
        related: document.related.clone(),
    }
}

fn collect_related_documents(
    target: &KnowledgeBaseDocument,
    documents: &[KnowledgeBaseDocument],
    max_related_items: usize,
    include_related_content: bool,
) -> Vec<KnowledgeBaseRelatedDocumentItem> {
    let alias_map = build_document_alias_map(documents);
    let mut candidates: HashMap<String, RelatedDocumentCandidate> = HashMap::new();
    let target_reference_keys = document_reference_keys(target);

    for related in &target.related {
        for document in resolve_reference_documents(related, documents, &alias_map) {
            add_related_candidate(
                &mut candidates,
                target,
                document,
                1.0,
                format!("frontmatter.related -> {}", related),
            );
        }
    }

    for source in &target.sources {
        for document in resolve_reference_documents(source, documents, &alias_map) {
            add_related_candidate(
                &mut candidates,
                target,
                document,
                0.92,
                format!("frontmatter.sources -> {}", source),
            );
        }
    }

    for wikilink in extract_wikilink_targets(&target.content) {
        for document in resolve_reference_documents(&wikilink, documents, &alias_map) {
            add_related_candidate(
                &mut candidates,
                target,
                document,
                0.95,
                format!("wikilink -> {}", wikilink),
            );
        }
    }

    for document in documents {
        if document.relative_path == target.relative_path {
            continue;
        }

        for related in &document.related {
            if reference_targets_document(related, &target_reference_keys) {
                add_related_candidate(
                    &mut candidates,
                    target,
                    document,
                    0.88,
                    format!("backlink via frontmatter.related -> {}", related),
                );
            }
        }

        for source in &document.sources {
            if reference_targets_document(source, &target_reference_keys) {
                add_related_candidate(
                    &mut candidates,
                    target,
                    document,
                    0.84,
                    format!("backlink via frontmatter.sources -> {}", source),
                );
            }
        }

        for wikilink in extract_wikilink_targets(&document.content) {
            if reference_targets_document(&wikilink, &target_reference_keys) {
                add_related_candidate(
                    &mut candidates,
                    target,
                    document,
                    0.86,
                    format!("backlink via wikilink -> {}", wikilink),
                );
            }
        }

        let shared_sources = shared_values(&target.sources, &document.sources);
        if !shared_sources.is_empty() {
            add_related_candidate(
                &mut candidates,
                target,
                document,
                0.72,
                format!("shared sources -> {}", shared_sources.join(", ")),
            );
        }

        let shared_tags = shared_values(&target.tags, &document.tags);
        if !shared_tags.is_empty() {
            add_related_candidate(
                &mut candidates,
                target,
                document,
                0.45,
                format!("shared tags -> {}", shared_tags.join(", ")),
            );
        }
    }

    let mut ranked: Vec<KnowledgeBaseRelatedDocumentItem> = candidates
        .into_values()
        .map(|candidate| KnowledgeBaseRelatedDocumentItem {
            file_id: candidate.document.relative_path.clone(),
            filename: candidate.document.filename.clone(),
            score: normalize_score(candidate.score),
            relation_reasons: candidate.reasons,
            attributes: document_attributes(&candidate.document),
            content_preview: build_document_preview(&candidate.document.content),
            content_text: include_related_content
                .then(|| truncate_text(&candidate.document.content, MAX_RELATED_CONTENT_CHARS)),
            summary: extract_document_summary(
                &candidate.document.content,
                &candidate.document.title,
            ),
            rag_related_info: extract_rag_related_info(
                &candidate.document.content,
                &candidate.document.title,
            ),
        })
        .collect();

    ranked.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                right
                    .relation_reasons
                    .len()
                    .cmp(&left.relation_reasons.len())
            })
            .then_with(|| left.file_id.cmp(&right.file_id))
    });
    ranked.truncate(max_related_items);
    ranked
}

fn add_related_candidate(
    candidates: &mut HashMap<String, RelatedDocumentCandidate>,
    target: &KnowledgeBaseDocument,
    document: &KnowledgeBaseDocument,
    score: f32,
    reason: String,
) {
    if document.relative_path == target.relative_path {
        return;
    }

    let entry = candidates
        .entry(document.relative_path.clone())
        .or_insert_with(|| RelatedDocumentCandidate {
            document: document.clone(),
            score: 0.0,
            reasons: Vec::new(),
        });

    entry.score = normalize_score(entry.score + score);
    if !entry.reasons.iter().any(|value| value == &reason) {
        entry.reasons.push(reason);
    }
}

fn build_document_alias_map(documents: &[KnowledgeBaseDocument]) -> HashMap<String, Vec<String>> {
    let mut aliases: HashMap<String, Vec<String>> = HashMap::new();

    for document in documents {
        for key in document_reference_keys(document) {
            aliases
                .entry(key)
                .or_default()
                .push(document.relative_path.clone());
        }
    }

    aliases
}

fn resolve_reference_documents<'a>(
    reference: &str,
    documents: &'a [KnowledgeBaseDocument],
    alias_map: &HashMap<String, Vec<String>>,
) -> Vec<&'a KnowledgeBaseDocument> {
    let mut seen = HashSet::new();
    let mut matched = Vec::new();

    for key in reference_lookup_keys(reference) {
        let Some(paths) = alias_map.get(&key) else {
            continue;
        };
        for path in paths {
            if !seen.insert(path.clone()) {
                continue;
            }
            if let Some(document) = documents
                .iter()
                .find(|document| document.relative_path == *path)
            {
                matched.push(document);
            }
        }
    }

    matched
}

fn reference_targets_document(reference: &str, target_reference_keys: &[String]) -> bool {
    let lookup = reference_lookup_keys(reference);
    lookup
        .iter()
        .any(|value| target_reference_keys.iter().any(|target| target == value))
}

fn document_reference_keys(document: &KnowledgeBaseDocument) -> Vec<String> {
    let mut values = Vec::new();
    let mut seen = HashSet::new();

    push_reference_key(
        &mut values,
        &mut seen,
        normalize_path(&document.relative_path).to_lowercase(),
    );
    push_reference_key(
        &mut values,
        &mut seen,
        strip_known_extension(&normalize_path(&document.relative_path)).to_lowercase(),
    );
    push_reference_key(&mut values, &mut seen, document.filename.to_lowercase());
    push_reference_key(
        &mut values,
        &mut seen,
        strip_known_extension(&document.filename).to_lowercase(),
    );
    push_reference_key(
        &mut values,
        &mut seen,
        normalize_reference_value(&document.title).unwrap_or_default(),
    );

    if let Some(stripped) = strip_known_prefix(&document.relative_path, "wiki/") {
        push_reference_key(
            &mut values,
            &mut seen,
            strip_known_extension(&stripped).to_lowercase(),
        );
    }
    if let Some(stripped) = strip_known_prefix(&document.relative_path, "raw/sources/") {
        push_reference_key(
            &mut values,
            &mut seen,
            strip_known_extension(&stripped).to_lowercase(),
        );
    }

    values
}

fn reference_lookup_keys(reference: &str) -> Vec<String> {
    let Some(normalized) = normalize_reference_value(reference) else {
        return Vec::new();
    };

    let mut values = Vec::new();
    let mut seen = HashSet::new();

    push_reference_key(&mut values, &mut seen, normalized.clone());
    push_reference_key(
        &mut values,
        &mut seen,
        strip_known_extension(&normalized).to_string(),
    );

    let normalized_path = normalize_path(&normalized);
    if let Some(filename) = Path::new(&normalized_path)
        .file_name()
        .and_then(|value| value.to_str())
    {
        push_reference_key(&mut values, &mut seen, filename.to_lowercase());
        push_reference_key(
            &mut values,
            &mut seen,
            strip_known_extension(filename).to_lowercase(),
        );
    }

    if let Some(stripped) = strip_known_prefix(&normalized_path, "wiki/") {
        push_reference_key(
            &mut values,
            &mut seen,
            strip_known_extension(&stripped).to_lowercase(),
        );
    }
    if let Some(stripped) = strip_known_prefix(&normalized_path, "raw/sources/") {
        push_reference_key(
            &mut values,
            &mut seen,
            strip_known_extension(&stripped).to_lowercase(),
        );
    }

    values
}

fn push_reference_key(output: &mut Vec<String>, seen: &mut HashSet<String>, value: String) {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return;
    }
    let normalized = trimmed.to_lowercase();
    if seen.insert(normalized.clone()) {
        output.push(normalized);
    }
}

fn normalize_reference_value(value: &str) -> Option<String> {
    normalize_reference_display(value).map(|value| value.to_lowercase())
}

fn normalize_reference_display(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    let mut normalized = trimmed
        .trim_start_matches("[[")
        .trim_end_matches("]]")
        .trim();

    if let Some((before_alias, _)) = normalized.split_once('|') {
        normalized = before_alias.trim();
    }
    if let Some((before_heading, _)) = normalized.split_once('#') {
        normalized = before_heading.trim();
    }

    let normalized = normalize_path(normalized).trim().to_string();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

fn normalize_requested_document_path(project_path: &str, value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let path = Path::new(trimmed);
    if path.is_absolute() {
        if let Ok(relative) = path.strip_prefix(project_path) {
            return normalize_path(relative.to_string_lossy().as_ref());
        }
    }

    normalize_path(trimmed.trim_start_matches("./"))
}

fn strip_known_extension(value: &str) -> &str {
    if let Some(stripped) = value.strip_suffix(".md") {
        return stripped;
    }
    if let Some(stripped) = value.strip_suffix(".markdown") {
        return stripped;
    }
    value
}

fn strip_known_prefix(value: &str, prefix: &str) -> Option<String> {
    let normalized = normalize_path(value);
    normalized
        .strip_prefix(prefix)
        .map(|value| value.to_string())
}

fn shared_values(left: &[String], right: &[String]) -> Vec<String> {
    let right_values: HashSet<String> = right
        .iter()
        .filter_map(|value| normalize_reference_value(value))
        .collect();

    let mut values = Vec::new();
    let mut seen = HashSet::new();
    for value in left {
        let Some(normalized) = normalize_reference_value(value) else {
            continue;
        };
        if right_values.contains(&normalized) && seen.insert(normalized.clone()) {
            values.push(normalized);
        }
    }
    values
}

fn empty_response() -> KnowledgeBaseQueryResponse {
    KnowledgeBaseQueryResponse {
        object: "vector_store.search_results.page",
        search_query: Vec::new(),
        data: Vec::new(),
        has_more: false,
        next_page: None,
        summary: String::new(),
        rag_related_info: Vec::new(),
    }
}

fn resolve_retrieval_mode(
    extensions: Option<&KnowledgeBaseQueryExtensions>,
) -> Result<RetrievalMode, HttpQueryError> {
    let has_embedding = normalize_embedding_config(extensions).is_some();
    let requested = extensions
        .and_then(|value| value.retrieval_mode.as_ref())
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty());

    match requested.as_deref() {
        Some("keyword") => Ok(RetrievalMode::Keyword),
        Some("vector") => {
            if has_embedding {
                Ok(RetrievalMode::Vector)
            } else {
                Err(HttpQueryError {
                    status: 400,
                    message:
                        "extensions.embedding_config is required when retrieval_mode is 'vector'"
                            .to_string(),
                })
            }
        }
        Some("hybrid") => {
            if has_embedding {
                Ok(RetrievalMode::Hybrid)
            } else {
                Err(HttpQueryError {
                    status: 400,
                    message:
                        "extensions.embedding_config is required when retrieval_mode is 'hybrid'"
                            .to_string(),
                })
            }
        }
        Some(other) => Err(HttpQueryError {
            status: 400,
            message: format!("Unsupported retrieval_mode '{other}'"),
        }),
        None => {
            if has_embedding {
                Ok(RetrievalMode::Hybrid)
            } else {
                Ok(RetrievalMode::Keyword)
            }
        }
    }
}

fn normalize_embedding_config(
    extensions: Option<&KnowledgeBaseQueryExtensions>,
) -> Option<KnowledgeBaseEmbeddingConfig> {
    let config = extensions?.embedding_config.as_ref()?;
    if !config.enabled || config.endpoint.trim().is_empty() || config.model.trim().is_empty() {
        return None;
    }

    Some(KnowledgeBaseEmbeddingConfig {
        enabled: true,
        endpoint: config.endpoint.trim().to_string(),
        api_key: config.api_key.clone(),
        model: config.model.trim().to_string(),
    })
}

fn normalize_allowed_path_prefixes(
    project_path: &str,
    extensions: Option<&KnowledgeBaseQueryExtensions>,
) -> Vec<String> {
    extensions
        .and_then(|value| value.allowed_path_prefixes.as_deref())
        .map(|values| normalize_allowed_path_prefix_list(project_path, values))
        .unwrap_or_default()
}

fn normalize_document_allowed_path_prefixes(
    project_path: &str,
    extensions: Option<&KnowledgeBaseDocumentExtensions>,
) -> Vec<String> {
    extensions
        .and_then(|value| value.allowed_path_prefixes.as_deref())
        .map(|values| normalize_allowed_path_prefix_list(project_path, values))
        .unwrap_or_default()
}

fn normalize_allowed_path_prefix_list(project_path: &str, values: &[String]) -> Vec<String> {
    let mut normalized = Vec::new();
    let mut seen = HashSet::new();

    for value in values {
        let prefix = normalize_requested_document_path(project_path, value)
            .trim_matches('/')
            .to_string();
        if prefix.is_empty() {
            continue;
        }
        if seen.insert(prefix.clone()) {
            normalized.push(prefix);
        }
    }

    normalized
}

fn filter_documents_by_allowed_prefixes(
    documents: Vec<KnowledgeBaseDocument>,
    allowed_path_prefixes: &[String],
) -> Vec<KnowledgeBaseDocument> {
    if allowed_path_prefixes.is_empty() {
        return documents;
    }

    documents
        .into_iter()
        .filter(|document| {
            path_matches_allowed_prefixes(&document.relative_path, allowed_path_prefixes)
        })
        .collect()
}

fn path_matches_allowed_prefixes(path: &str, allowed_path_prefixes: &[String]) -> bool {
    let normalized_path = normalize_path(path);
    allowed_path_prefixes.iter().any(|prefix| {
        normalized_path == *prefix || normalized_path.starts_with(&format!("{prefix}/"))
    })
}

async fn fetch_embedding(
    text: &str,
    embedding_config: &KnowledgeBaseEmbeddingConfig,
) -> Result<Option<Vec<f32>>, HttpQueryError> {
    if text.trim().is_empty() {
        return Ok(None);
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| HttpQueryError {
            status: 500,
            message: format!("Failed to initialize embedding client: {error}"),
        })?;

    let mut request = client.post(&embedding_config.endpoint).json(&json!({
        "model": embedding_config.model,
        "input": text.chars().take(2000).collect::<String>(),
    }));
    if !embedding_config.api_key.trim().is_empty() {
        request = request.bearer_auth(embedding_config.api_key.trim());
    }

    let response = request.send().await.map_err(|error| HttpQueryError {
        status: 502,
        message: format!("Embedding request failed: {error}"),
    })?;
    if !response.status().is_success() {
        return Err(HttpQueryError {
            status: 502,
            message: format!("Embedding request failed with status {}", response.status()),
        });
    }

    let payload: Value = response.json().await.map_err(|error| HttpQueryError {
        status: 502,
        message: format!("Invalid embedding response: {error}"),
    })?;
    let Some(values) = payload
        .get("data")
        .and_then(|value| value.as_array())
        .and_then(|items| items.first())
        .and_then(|item| item.get("embedding"))
        .and_then(|value| value.as_array())
    else {
        return Ok(None);
    };

    let mut embedding = Vec::with_capacity(values.len());
    for value in values {
        let Some(number) = value.as_f64() else {
            return Err(HttpQueryError {
                status: 502,
                message: "Embedding response contains non-numeric values".to_string(),
            });
        };
        embedding.push(number as f32);
    }

    Ok(Some(embedding))
}

fn validate_project_path(project_path: &str) -> Result<(), HttpQueryError> {
    let path = Path::new(project_path);
    if !path.exists() {
        return Err(HttpQueryError {
            status: 400,
            message: format!(
                "projectPath does not exist: {}",
                normalize_path(project_path)
            ),
        });
    }
    if !path.is_dir() {
        return Err(HttpQueryError {
            status: 400,
            message: format!(
                "projectPath is not a directory: {}",
                normalize_path(project_path)
            ),
        });
    }

    let wiki_root = path.join("wiki");
    let raw_root = path.join("raw").join("sources");
    if !wiki_root.exists() && !raw_root.exists() {
        return Err(HttpQueryError {
            status: 400,
            message: "projectPath must contain 'wiki/' or 'raw/sources/'".to_string(),
        });
    }

    Ok(())
}

fn load_knowledge_base_documents(project_path: &str) -> Result<Vec<KnowledgeBaseDocument>, String> {
    let mut documents = Vec::new();
    let root = Path::new(project_path);

    let wiki_root = root.join("wiki");
    if wiki_root.exists() {
        let mut wiki_files = Vec::new();
        collect_files(&wiki_root, true, &mut wiki_files)?;
        wiki_files.sort();
        for file_path in wiki_files {
            let Ok(content) = fs::read_to_string(&file_path) else {
                continue;
            };
            documents.push(build_document(root, &file_path, "wiki", content));
        }
    }

    let raw_root = root.join("raw").join("sources");
    if raw_root.exists() {
        let mut raw_files = Vec::new();
        collect_files(&raw_root, false, &mut raw_files)?;
        raw_files.sort();
        for file_path in raw_files {
            if !is_indexable_raw_file(&file_path) {
                continue;
            }
            let Ok(content) = read_file(normalize_path(file_path.to_string_lossy().as_ref()))
            else {
                continue;
            };
            if is_placeholder_content(&content) {
                continue;
            }
            documents.push(build_document(root, &file_path, "raw", content));
        }
    }

    Ok(documents)
}

fn collect_files(
    root: &Path,
    markdown_only: bool,
    output: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let entries = fs::read_dir(root)
        .map_err(|error| format!("Failed to read directory '{}': {error}", root.display()))?;

    for entry in entries {
        let entry = entry.map_err(|error| format!("Failed to read directory entry: {error}"))?;
        let path = entry.path();
        if should_skip_path(&path) {
            continue;
        }
        if path.is_dir() {
            collect_files(&path, markdown_only, output)?;
            continue;
        }

        if markdown_only {
            let is_markdown = path
                .extension()
                .and_then(|value| value.to_str())
                .map(|value| value.eq_ignore_ascii_case("md"))
                .unwrap_or(false);
            if !is_markdown {
                continue;
            }
        }

        output.push(path);
    }

    Ok(())
}

fn build_document(
    project_root: &Path,
    file_path: &Path,
    source: &str,
    content: String,
) -> KnowledgeBaseDocument {
    let relative_path = normalize_path(
        file_path
            .strip_prefix(project_root)
            .unwrap_or(file_path)
            .to_string_lossy()
            .as_ref(),
    );
    let filename = file_path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_string();
    let directory = Path::new(&relative_path)
        .parent()
        .map(|value| normalize_path(value.to_string_lossy().as_ref()))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| ".".to_string());

    let metadata = parse_frontmatter(&content);
    let title = metadata
        .title
        .clone()
        .filter(|value| !value.is_empty())
        .or_else(|| extract_heading_title(&content))
        .unwrap_or_else(|| fallback_title(file_path));
    let doc_type = metadata
        .doc_type
        .clone()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            if source == "wiki" {
                "other".to_string()
            } else {
                "source".to_string()
            }
        });

    let mut filter_attributes = Map::new();
    filter_attributes.insert("path".to_string(), json!(relative_path));
    filter_attributes.insert("filename".to_string(), json!(filename));
    filter_attributes.insert("title".to_string(), json!(title));
    filter_attributes.insert("source".to_string(), json!(source));
    filter_attributes.insert("directory".to_string(), json!(directory));
    filter_attributes.insert("type".to_string(), json!(doc_type));
    filter_attributes.insert("tags".to_string(), json!(metadata.tags.clone()));
    filter_attributes.insert("sources".to_string(), json!(metadata.sources.clone()));
    filter_attributes.insert("related".to_string(), json!(metadata.related.clone()));

    KnowledgeBaseDocument {
        relative_path,
        filename,
        title,
        content,
        source: source.to_string(),
        directory,
        doc_type,
        tags: metadata.tags,
        sources: metadata.sources,
        related: metadata.related,
        filter_attributes,
    }
}

fn apply_keyword_matches(
    query: &str,
    documents: &[KnowledgeBaseDocument],
    filter: Option<&KnowledgeBaseFilter>,
    candidates: &mut HashMap<String, CandidateResult>,
) {
    let tokens = tokenize_query(query);
    let effective_tokens = if tokens.is_empty() {
        vec![query.trim().to_lowercase()]
    } else {
        tokens
    };

    for document in documents {
        if !matches_knowledge_base_filter(&document.filter_attributes, filter) {
            continue;
        }

        let title_text = format!("{} {}", document.title, document.filename);
        let title_coverage = compute_token_coverage(&title_text, &effective_tokens);
        let content_coverage = compute_token_coverage(&document.content, &effective_tokens);

        if title_coverage == 0.0 && content_coverage == 0.0 {
            continue;
        }

        let score = normalize_score(content_coverage * 0.65 + title_coverage * 0.35);
        let title_match = title_coverage > 0.0;
        let matching_token = effective_tokens
            .iter()
            .find(|token| contains_case_insensitive(&document.content, token))
            .cloned()
            .unwrap_or_else(|| query.to_string());
        let snippet = build_snippet(&document.content, &matching_token);

        let entry = candidates
            .entry(document.relative_path.clone())
            .or_insert_with(|| CandidateResult {
                document: document.clone(),
                keyword_score: 0.0,
                semantic_score: 0.0,
                title_match: false,
                snippet: String::new(),
            });

        if score > entry.keyword_score {
            entry.keyword_score = score;
        }
        entry.title_match |= title_match;
        if entry.snippet.is_empty() {
            entry.snippet = snippet;
        }
    }
}

fn to_result_item(candidate: CandidateResult) -> KnowledgeBaseQueryResultItem {
    let CandidateResult {
        document,
        keyword_score,
        semantic_score,
        title_match,
        snippet,
    } = candidate;
    let summary = extract_document_summary(&document.content, &document.title);
    let rag_related_info = extract_rag_related_info(&document.content, &document.title);
    let retrieval_mode = resolve_result_retrieval_mode(keyword_score, semantic_score);
    let score = combine_scores(keyword_score, semantic_score);

    KnowledgeBaseQueryResultItem {
        file_id: document.relative_path.clone(),
        filename: document.filename,
        score,
        attributes: KnowledgeBaseQueryResultAttributes {
            path: document.relative_path,
            title: document.title,
            source: document.source,
            directory: document.directory,
            doc_type: document.doc_type,
            title_match,
            retrieval_mode,
        },
        content: if snippet.is_empty() {
            Vec::new()
        } else {
            vec![KnowledgeBaseContentChunk {
                kind: "text",
                text: snippet,
            }]
        },
        summary,
        rag_related_info,
    }
}

async fn apply_semantic_matches(
    project_path: &str,
    queries: &[String],
    documents: &[KnowledgeBaseDocument],
    filter: Option<&KnowledgeBaseFilter>,
    embedding_config: &KnowledgeBaseEmbeddingConfig,
    max_num_results: usize,
    candidates: &mut HashMap<String, CandidateResult>,
) -> Result<(), HttpQueryError> {
    let wiki_by_id = build_wiki_documents_by_id(documents);
    let vector_limit = usize::max(10, max_num_results * 2);

    for query in queries {
        let Some(query_embedding) = fetch_embedding(query, embedding_config).await? else {
            continue;
        };

        let results = vector_search(project_path.to_string(), query_embedding, vector_limit)
            .await
            .map_err(|error| HttpQueryError {
                status: 500,
                message: format!("Vector search failed: {error}"),
            })?;

        for result in results {
            let Some(matches) = wiki_by_id.get(&result.page_id) else {
                continue;
            };

            for document in matches {
                if !matches_knowledge_base_filter(&document.filter_attributes, filter) {
                    continue;
                }

                let entry = candidates
                    .entry(document.relative_path.clone())
                    .or_insert_with(|| CandidateResult {
                        document: document.clone(),
                        keyword_score: 0.0,
                        semantic_score: 0.0,
                        title_match: false,
                        snippet: String::new(),
                    });

                entry.semantic_score = entry.semantic_score.max(normalize_score(result.score));
                if entry.snippet.is_empty() {
                    entry.snippet = build_snippet(&document.content, query);
                }
            }
        }
    }

    Ok(())
}

fn build_wiki_documents_by_id(
    documents: &[KnowledgeBaseDocument],
) -> HashMap<String, Vec<KnowledgeBaseDocument>> {
    let mut wiki_by_id: HashMap<String, Vec<KnowledgeBaseDocument>> = HashMap::new();

    for document in documents {
        if document.source != "wiki" {
            continue;
        }

        let id = Path::new(&document.filename)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        if id.is_empty() {
            continue;
        }
        wiki_by_id.entry(id).or_default().push(document.clone());
    }

    wiki_by_id
}

fn combine_scores(keyword_score: f32, semantic_score: f32) -> f32 {
    if keyword_score > 0.0 && semantic_score > 0.0 {
        normalize_score(keyword_score * 0.65 + semantic_score * 0.35 + 0.05)
    } else {
        normalize_score(keyword_score.max(semantic_score))
    }
}

fn resolve_result_retrieval_mode(keyword_score: f32, semantic_score: f32) -> &'static str {
    if keyword_score > 0.0 && semantic_score > 0.0 {
        "hybrid"
    } else if semantic_score > 0.0 {
        "vector"
    } else {
        "keyword"
    }
}

fn build_response_summary(items: &[KnowledgeBaseQueryResultItem]) -> String {
    let parts: Vec<String> = items
        .iter()
        .take(3)
        .map(|item| {
            if item.summary.is_empty() {
                item.attributes.title.clone()
            } else {
                format!("{}：{}", item.attributes.title, item.summary)
            }
        })
        .collect();

    if parts.is_empty() {
        String::new()
    } else {
        format!("当前返回 {} 条相关知识。{}", items.len(), parts.join("；"))
    }
}

fn collect_response_rag_related_info(items: &[KnowledgeBaseQueryResultItem]) -> Vec<String> {
    let mut values = Vec::new();
    let mut seen = HashSet::new();

    for item in items {
        for entry in &item.rag_related_info {
            if seen.insert(entry.clone()) {
                values.push(entry.clone());
            }
            if values.len() >= MAX_RAG_HIGHLIGHTS * 2 {
                return values;
            }
        }
    }

    values
}

fn extract_document_summary(content: &str, title: &str) -> String {
    let sections = split_markdown_sections(content);
    let preferred = sections.iter().find(|section| {
        SUMMARY_SECTION_KEYWORDS
            .iter()
            .any(|keyword| contains_case_insensitive(&section.heading, keyword))
    });

    let candidate = preferred
        .and_then(find_section_summary)
        .or_else(|| sections.iter().find_map(find_section_summary))
        .or_else(|| first_meaningful_line(strip_frontmatter_content(content).lines()))
        .unwrap_or_else(|| title.to_string());

    truncate_text(&candidate, 220)
}

fn extract_rag_related_info(content: &str, title: &str) -> Vec<String> {
    let sections = split_markdown_sections(content);
    let first_lines = strip_frontmatter_content(content)
        .lines()
        .take(24)
        .collect::<Vec<_>>()
        .join("\n");
    let doc_level_relevant = is_rag_related_text(title) || is_rag_related_text(&first_lines);

    let mut highlights = Vec::new();
    let mut seen = HashSet::new();

    for section in sections {
        let joined = section.lines.join("\n");
        let section_relevant = doc_level_relevant
            || is_rag_related_text(&section.heading)
            || is_rag_related_text(&joined);

        if !section_relevant {
            continue;
        }

        for line in section.lines {
            if highlights.len() >= MAX_RAG_HIGHLIGHTS {
                return highlights;
            }

            let Some(cleaned) = clean_markdown_line(&line) else {
                continue;
            };
            if cleaned.chars().count() < 8 {
                continue;
            }
            if !section.heading.is_empty() && cleaned == section.heading {
                continue;
            }
            if !doc_level_relevant && !is_rag_related_text(&cleaned) {
                continue;
            }

            let value = if section.heading.is_empty() {
                truncate_text(&cleaned, 220)
            } else {
                truncate_text(&format!("{}: {}", section.heading, cleaned), 220)
            };

            if seen.insert(value.clone()) {
                highlights.push(value);
            }
        }
    }

    highlights
}

fn split_markdown_sections(content: &str) -> Vec<MarkdownSection> {
    let body = strip_frontmatter_content(content);
    let mut sections = Vec::new();
    let mut current = MarkdownSection {
        heading: String::new(),
        lines: Vec::new(),
    };
    let mut in_code_block = false;

    for line in body.lines() {
        let trimmed = line.trim();

        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            continue;
        }

        if !in_code_block && is_markdown_heading(trimmed) {
            if !current.heading.is_empty() || !current.lines.is_empty() {
                sections.push(current);
            }
            current = MarkdownSection {
                heading: trimmed.trim_start_matches('#').trim().to_string(),
                lines: Vec::new(),
            };
            continue;
        }

        current.lines.push(line.to_string());
    }

    if !current.heading.is_empty() || !current.lines.is_empty() {
        sections.push(current);
    }

    sections
}

fn find_section_summary(section: &MarkdownSection) -> Option<String> {
    first_meaningful_line(section.lines.iter().map(String::as_str))
}

fn first_meaningful_line<'a>(lines: impl IntoIterator<Item = &'a str>) -> Option<String> {
    for line in lines {
        let Some(cleaned) = clean_markdown_line(line) else {
            continue;
        };
        if cleaned.chars().count() >= 16 {
            return Some(cleaned);
        }
    }
    None
}

fn clean_markdown_line(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() || is_table_separator(trimmed) {
        return None;
    }

    let mut normalized = if trimmed.starts_with('|') {
        let cells: Vec<String> = trimmed
            .split('|')
            .map(|cell| cell.trim())
            .filter(|cell| !cell.is_empty())
            .filter(|cell| !is_table_separator(cell))
            .map(|cell| cell.to_string())
            .collect();
        if cells.is_empty() {
            return None;
        }
        cells.join(" | ")
    } else {
        trimmed
            .trim_start_matches('>')
            .trim_start()
            .trim_start_matches(|ch: char| matches!(ch, '-' | '*' | '+'))
            .trim_start()
            .to_string()
    };

    if let Some(rest) = strip_numbered_list_prefix(&normalized) {
        normalized = rest.to_string();
    }

    normalized = replace_wikilinks(&normalized);
    normalized = normalized
        .replace("**", "")
        .replace("__", "")
        .replace('`', "");

    let collapsed = normalized.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        None
    } else {
        Some(collapsed)
    }
}

fn build_document_preview(content: &str) -> String {
    let body = strip_frontmatter_content(content);
    let collapsed = body.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate_text(&collapsed, 280)
}

fn extract_wikilink_targets(content: &str) -> Vec<String> {
    let mut targets = Vec::new();
    let mut seen = HashSet::new();
    let mut rest = content;

    while let Some(start) = rest.find("[[") {
        let after_start = &rest[start + 2..];
        let Some(end) = after_start.find("]]") else {
            break;
        };

        let raw = &after_start[..end];
        if let Some(display) = normalize_reference_display(raw) {
            if seen.insert(display.clone()) {
                targets.push(display);
            }
        }

        rest = &after_start[end + 2..];
    }

    targets
}

fn strip_frontmatter_content(content: &str) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let start_index = if lines.first().copied() == Some("---") {
        Some(1usize)
    } else if lines
        .first()
        .is_some_and(|line| line.trim_start().starts_with("```"))
        && lines.get(1).copied() == Some("---")
    {
        Some(2usize)
    } else {
        None
    };

    let Some(start_index) = start_index else {
        return content.to_string();
    };

    for index in start_index..lines.len() {
        if lines[index] == "---" {
            let mut body_start = index + 1;
            if lines
                .get(body_start)
                .is_some_and(|line| line.trim_start().starts_with("```"))
            {
                body_start += 1;
            }
            return lines[body_start..].join("\n");
        }
    }

    content.to_string()
}

fn replace_wikilinks(value: &str) -> String {
    let mut output = String::new();
    let mut rest = value;

    while let Some(start) = rest.find("[[") {
        output.push_str(&rest[..start]);
        let after_start = &rest[start + 2..];
        if let Some(end) = after_start.find("]]") {
            output.push_str(&after_start[..end]);
            rest = &after_start[end + 2..];
        } else {
            output.push_str(&rest[start..]);
            return output;
        }
    }

    output.push_str(rest);
    output
}

fn strip_numbered_list_prefix(value: &str) -> Option<&str> {
    let mut chars = value.char_indices();
    let mut saw_digit = false;

    while let Some((_index, ch)) = chars.next() {
        if ch.is_ascii_digit() {
            saw_digit = true;
            continue;
        }
        if saw_digit && ch == '.' {
            if let Some((space_index, space)) = chars.next() {
                if space.is_whitespace() {
                    return Some(value[space_index..].trim_start());
                }
            }
        }
        break;
    }
    None
}

fn is_markdown_heading(value: &str) -> bool {
    let hashes = value.chars().take_while(|ch| *ch == '#').count();
    hashes > 0
        && value
            .chars()
            .nth(hashes)
            .is_some_and(|ch| ch.is_whitespace())
}

fn is_table_separator(value: &str) -> bool {
    value.chars().all(|ch| matches!(ch, '-' | ':' | '|' | ' '))
}

fn is_rag_related_text(value: &str) -> bool {
    RAG_RELATED_KEYWORDS
        .iter()
        .any(|keyword| contains_case_insensitive(value, keyword))
}

fn truncate_text(value: &str, max_length: usize) -> String {
    let chars: Vec<char> = value.chars().collect();
    if chars.len() <= max_length {
        value.to_string()
    } else {
        chars[..max_length.saturating_sub(3)]
            .iter()
            .collect::<String>()
            + "..."
    }
}

fn normalize_search_queries(query: &SearchQueryInput) -> Vec<String> {
    match query {
        SearchQueryInput::Single(value) => trim_query(value).into_iter().collect(),
        SearchQueryInput::Multiple(values) => values
            .iter()
            .filter_map(|value| trim_query(value))
            .collect(),
    }
}

fn trim_query(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn clamp_max_num_results(value: Option<usize>, fallback: usize) -> usize {
    value.unwrap_or(fallback).clamp(1, MAX_RESULTS)
}

fn clamp_max_related_items(value: Option<usize>) -> usize {
    value
        .unwrap_or(DEFAULT_MAX_RELATED_ITEMS)
        .clamp(1, MAX_RELATED_ITEMS)
}

fn normalize_score(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

fn tokenize_query(query: &str) -> Vec<String> {
    let lower = query.to_lowercase();
    let mut raw_tokens = Vec::new();
    let mut current = String::new();

    for ch in lower.chars() {
        if is_token_char(ch) {
            current.push(ch);
        } else if !current.is_empty() {
            raw_tokens.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        raw_tokens.push(current);
    }

    let mut dedup = HashSet::new();
    let mut tokens = Vec::new();

    for token in raw_tokens {
        if token.chars().count() <= 1 || is_stop_word(&token) {
            continue;
        }

        let chars: Vec<char> = token.chars().collect();
        let has_cjk = chars.iter().any(|ch| is_cjk(*ch));
        if has_cjk && chars.len() > 2 {
            for window in chars.windows(2) {
                let value: String = window.iter().collect();
                push_unique(&mut tokens, &mut dedup, value);
            }
            for ch in &chars {
                let value = ch.to_string();
                if !is_stop_word(&value) {
                    push_unique(&mut tokens, &mut dedup, value);
                }
            }
            push_unique(&mut tokens, &mut dedup, token);
        } else {
            push_unique(&mut tokens, &mut dedup, token);
        }
    }

    tokens
}

fn is_token_char(ch: char) -> bool {
    ch.is_alphanumeric() || is_cjk(ch)
}

fn is_cjk(ch: char) -> bool {
    matches!(ch as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF)
}

fn is_stop_word(token: &str) -> bool {
    STOP_WORDS.contains(&token)
}

fn push_unique(output: &mut Vec<String>, dedup: &mut HashSet<String>, value: String) {
    if dedup.insert(value.clone()) {
        output.push(value);
    }
}

fn compute_token_coverage(text: &str, tokens: &[String]) -> f32 {
    if tokens.is_empty() {
        return 0.0;
    }

    let lower = text.to_lowercase();
    let matched = tokens
        .iter()
        .filter(|token| lower.contains(token.as_str()))
        .count();

    matched as f32 / tokens.len() as f32
}

fn build_snippet(content: &str, query: &str) -> String {
    let content_chars: Vec<char> = content.chars().collect();
    if content_chars.is_empty() {
        return String::new();
    }

    if let Some(match_start) = find_char_index_case_insensitive(content, query) {
        let query_len = query.chars().count().max(1);
        let start = match_start.saturating_sub(SNIPPET_CONTEXT);
        let end = usize::min(
            content_chars.len(),
            match_start + query_len + SNIPPET_CONTEXT,
        );
        let mut snippet: String = content_chars[start..end].iter().collect();
        snippet = snippet.replace('\n', " ").replace('\r', " ");
        if start > 0 {
            snippet = format!("...{snippet}");
        }
        if end < content_chars.len() {
            snippet.push_str("...");
        }
        return snippet;
    }

    content_chars
        .iter()
        .take(SNIPPET_CONTEXT * 2)
        .collect::<String>()
        .replace('\n', " ")
        .replace('\r', " ")
}

fn find_char_index_case_insensitive(content: &str, query: &str) -> Option<usize> {
    let lower_content = content.to_lowercase();
    let lower_query = query.to_lowercase();
    let byte_index = lower_content.find(lower_query.as_str())?;
    Some(lower_content[..byte_index].chars().count())
}

fn contains_case_insensitive(text: &str, query: &str) -> bool {
    text.to_lowercase().contains(&query.to_lowercase())
}

fn parse_frontmatter(content: &str) -> ParsedFrontmatter {
    let Some(frontmatter) = extract_frontmatter(content) else {
        return ParsedFrontmatter {
            title: None,
            doc_type: None,
            tags: Vec::new(),
            sources: Vec::new(),
            related: Vec::new(),
        };
    };

    ParsedFrontmatter {
        title: match_scalar(&frontmatter, "title"),
        doc_type: match_scalar(&frontmatter, "type").map(|value| value.to_lowercase()),
        tags: match_array(&frontmatter, "tags"),
        sources: match_array(&frontmatter, "sources"),
        related: match_array(&frontmatter, "related"),
    }
}

fn extract_frontmatter(content: &str) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let start_index = if lines.first().copied()? == "---" {
        1
    } else if lines
        .first()
        .is_some_and(|line| line.trim_start().starts_with("```"))
        && lines.get(1).copied() == Some("---")
    {
        2
    } else {
        return None;
    };

    let mut frontmatter = Vec::new();
    for line in lines.iter().skip(start_index) {
        if *line == "---" {
            return Some(frontmatter.join("\n"));
        }
        frontmatter.push((*line).to_string());
    }

    None
}

fn match_scalar(frontmatter: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}:");
    for line in frontmatter.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix(&prefix) {
            let value = strip_quotes(rest.trim());
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn match_array(frontmatter: &str, key: &str) -> Vec<String> {
    let lines: Vec<&str> = frontmatter.lines().collect();
    let prefix = format!("{key}:");

    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.trim_end();
        if let Some(rest) = trimmed.trim_start().strip_prefix(&prefix) {
            let rest = rest.trim();
            if rest.starts_with('[') && rest.ends_with(']') {
                return rest[1..rest.len() - 1]
                    .split(',')
                    .map(|value| strip_quotes(value.trim()).to_string())
                    .filter(|value| !value.is_empty())
                    .collect();
            }

            if rest.is_empty() {
                let mut values = Vec::new();
                for next_line in lines.iter().skip(index + 1) {
                    let candidate = next_line.trim_start();
                    if let Some(value) = candidate.strip_prefix("- ") {
                        let normalized = strip_quotes(value.trim());
                        if !normalized.is_empty() {
                            values.push(normalized.to_string());
                        }
                        continue;
                    }
                    if candidate.is_empty() {
                        continue;
                    }
                    break;
                }
                return values;
            }
        }
    }

    Vec::new()
}

fn strip_quotes(value: &str) -> &str {
    value.trim().trim_matches('"').trim_matches('\'')
}

fn extract_heading_title(content: &str) -> Option<String> {
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("# ") {
            let title = rest.trim();
            if !title.is_empty() {
                return Some(title.to_string());
            }
        }
    }
    None
}

fn fallback_title(file_path: &Path) -> String {
    file_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .replace('-', " ")
}

fn normalize_path(path: &str) -> String {
    path.replace('\\', "/")
}

fn should_skip_path(path: &Path) -> bool {
    path.components().any(|component| {
        let value = component.as_os_str().to_string_lossy();
        value.starts_with('.') || value == ".cache"
    })
}

fn is_indexable_raw_file(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_lowercase();

    !matches!(
        ext.as_str(),
        "png"
            | "jpg"
            | "jpeg"
            | "gif"
            | "webp"
            | "bmp"
            | "ico"
            | "tiff"
            | "tif"
            | "avif"
            | "heic"
            | "heif"
            | "svg"
            | "mp4"
            | "webm"
            | "mov"
            | "avi"
            | "mkv"
            | "flv"
            | "wmv"
            | "m4v"
            | "mp3"
            | "wav"
            | "ogg"
            | "flac"
            | "aac"
            | "m4a"
            | "wma"
            | "doc"
            | "xls"
            | "ppt"
            | "pages"
            | "numbers"
            | "key"
            | "epub"
    )
}

fn is_placeholder_content(content: &str) -> bool {
    let trimmed = content.trim();
    trimmed.starts_with("[Image:")
        || trimmed.starts_with("[Media:")
        || trimmed.starts_with("[Binary file:")
        || trimmed.starts_with("[Document:")
        || trimmed == "[Unsupported format]"
}

fn matches_knowledge_base_filter(
    attributes: &Map<String, Value>,
    filter: Option<&KnowledgeBaseFilter>,
) -> bool {
    let Some(filter) = filter else {
        return true;
    };

    match filter {
        KnowledgeBaseFilter::Compound(compound) => {
            if compound.filters.is_empty() {
                return true;
            }
            match compound.operator.as_str() {
                "and" => compound
                    .filters
                    .iter()
                    .all(|item| matches_knowledge_base_filter(attributes, Some(item))),
                "or" => compound
                    .filters
                    .iter()
                    .any(|item| matches_knowledge_base_filter(attributes, Some(item))),
                _ => false,
            }
        }
        KnowledgeBaseFilter::Comparison(comparison) => {
            let Some(actual) = attributes.get(&comparison.key) else {
                return false;
            };
            compare_attribute(actual, comparison.operator.as_str(), &comparison.value)
        }
    }
}

fn compare_attribute(actual: &Value, operator: &str, expected: &Value) -> bool {
    match actual {
        Value::Array(values) => compare_array(values, operator, expected),
        _ => compare_scalar(actual, operator, expected),
    }
}

fn compare_scalar(actual: &Value, operator: &str, expected: &Value) -> bool {
    match operator {
        "eq" => values_equal(actual, expected),
        "ne" => !values_equal(actual, expected),
        "gt" => compare_comparable(actual, expected, |ordering| ordering.is_gt()),
        "gte" => compare_comparable(actual, expected, |ordering| {
            ordering.is_gt() || ordering.is_eq()
        }),
        "lt" => compare_comparable(actual, expected, |ordering| ordering.is_lt()),
        "lte" => compare_comparable(actual, expected, |ordering| {
            ordering.is_lt() || ordering.is_eq()
        }),
        "in" => match expected {
            Value::Array(values) => values.iter().any(|value| values_equal(actual, value)),
            _ => values_equal(actual, expected),
        },
        "nin" => !compare_scalar(actual, "in", expected),
        _ => false,
    }
}

fn compare_array(actual: &[Value], operator: &str, expected: &Value) -> bool {
    match operator {
        "eq" => match expected {
            Value::Array(expected_values) => {
                actual.len() == expected_values.len()
                    && actual
                        .iter()
                        .zip(expected_values.iter())
                        .all(|(left, right)| values_equal(left, right))
            }
            _ => actual.iter().any(|value| values_equal(value, expected)),
        },
        "ne" => !compare_array(actual, "eq", expected),
        "in" => match expected {
            Value::Array(expected_values) => actual.iter().any(|left| {
                expected_values
                    .iter()
                    .any(|right| values_equal(left, right))
            }),
            _ => actual.iter().any(|value| values_equal(value, expected)),
        },
        "nin" => !compare_array(actual, "in", expected),
        "gt" | "gte" | "lt" | "lte" => false,
        _ => false,
    }
}

fn compare_comparable(
    actual: &Value,
    expected: &Value,
    comparator: impl Fn(std::cmp::Ordering) -> bool,
) -> bool {
    match (actual, expected) {
        (Value::Number(left), Value::Number(right)) => match (left.as_f64(), right.as_f64()) {
            (Some(left), Some(right)) => left.partial_cmp(&right).map(&comparator).unwrap_or(false),
            _ => false,
        },
        (Value::String(left), Value::String(right)) => comparator(left.cmp(right)),
        _ => false,
    }
}

fn values_equal(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(left), Value::Number(right)) => match (left.as_f64(), right.as_f64()) {
            (Some(left), Some(right)) => (left - right).abs() < f64::EPSILON,
            _ => false,
        },
        _ => left == right,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn real_demo_project_path() -> Option<String> {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("local-data")
            .join("borrowed-llmwiki")
            .join("demo");
        path.exists()
            .then(|| normalize_path(path.to_string_lossy().as_ref()))
    }

    #[test]
    fn allowed_path_prefixes_filter_documents_with_real_data() {
        let Some(project_path) = real_demo_project_path() else {
            return;
        };

        let documents = load_knowledge_base_documents(&project_path).expect("load should succeed");
        if documents.is_empty() {
            return;
        }
        let target = documents
            .iter()
            .find(|item| item.relative_path.contains('/'))
            .cloned()
            .unwrap_or_else(|| documents[0].clone());
        let prefix = target.directory.clone();
        let filtered =
            filter_documents_by_allowed_prefixes(documents, std::slice::from_ref(&prefix));

        assert!(!filtered.is_empty());
        assert!(filtered.iter().all(|item| {
            item.relative_path == prefix || item.relative_path.starts_with(&format!("{prefix}/"))
        }));
        assert!(filtered
            .iter()
            .any(|item| item.relative_path == target.relative_path));
    }

    #[test]
    fn allowed_path_prefixes_block_document_reads_outside_scope() {
        let Some(project_path) = real_demo_project_path() else {
            return;
        };

        let documents = load_knowledge_base_documents(&project_path).expect("load should succeed");
        if documents.is_empty() {
            return;
        }
        let target = documents[0].clone();
        let mismatched_prefix = if target.relative_path.starts_with("wiki/") {
            "raw/sources".to_string()
        } else {
            "wiki".to_string()
        };

        let error = get_knowledge_base_document_internal(
            &project_path,
            KnowledgeBaseDocumentRequest {
                file_id: Some(target.relative_path.clone()),
                path: None,
                filename: None,
                directory: None,
                source: None,
                max_related_items: None,
                include_related_content: None,
                extensions: Some(KnowledgeBaseDocumentExtensions {
                    allowed_path_prefixes: Some(vec![mismatched_prefix]),
                }),
            },
        )
        .expect_err("document lookup should be blocked");

        assert_eq!(error.status, 404);
    }

    #[cfg(unix)]
    #[test]
    fn ingest_source_path_accepts_symlinked_shrimp_source_entry() {
        let unique = format!(
            "clawdhome-llmwiki-ingest-symlink-{}",
            std::process::id()
        );
        let root = std::env::temp_dir().join(unique);
        let project = root.join("project");
        let external_notes = root.join("vaults").join("shrimp").join("llmwiki-notes");
        let source_link = project.join("raw/sources/shrimps/shrimp");
        let source_file = source_link.join("note.md");

        fs::create_dir_all(project.join("wiki")).expect("create wiki dir");
        fs::create_dir_all(project.join("raw/sources/shrimps")).expect("create sources dir");
        fs::create_dir_all(&external_notes).expect("create external notes dir");
        fs::write(external_notes.join("note.md"), "# Note\n").expect("write note");
        std::os::unix::fs::symlink(&external_notes, &source_link).expect("create source symlink");

        let normalized = normalize_ingest_source_path_input(
            project.to_string_lossy().as_ref(),
            source_file.to_string_lossy().as_ref(),
        )
        .expect("symlinked source entry should be accepted");

        assert_eq!(normalized, source_file.to_string_lossy());
        let _ = fs::remove_dir_all(root);
    }
}
