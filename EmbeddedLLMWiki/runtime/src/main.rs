use std::env;
use std::io::Read;
use std::thread;
use std::time::Duration;

use clawdhome_llmwiki_runtime::commands;
use serde::Deserialize;
use serde_json::{json, Value};

fn main() {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        None | Some("serve") => serve_forever(),
        Some("invoke") => {
            let command = args.next().unwrap_or_default();
            if command.is_empty() {
                fail("missing command name");
            }
            let payload = read_payload();
            match invoke(&command, payload) {
                Ok(value) => {
                    println!(
                        "{}",
                        serde_json::to_string(&value).unwrap_or_else(|_| "null".to_string())
                    );
                }
                Err(error) => fail(&error),
            }
        }
        Some(other) => fail(&format!("unsupported mode: {other}")),
    }
}

fn serve_forever() {
    clawdhome_llmwiki_runtime::clip_server::start_clip_server();
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

fn read_payload() -> Value {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return Value::Null;
    }
    let trimmed = input.trim();
    if trimmed.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(trimmed).unwrap_or_else(|error| fail(&format!("invalid payload JSON: {error}")))
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1);
}

fn invoke(command: &str, payload: Value) -> Result<Value, String> {
    match command {
        "read_file" => {
            let payload: PathPayload = deserialize(payload)?;
            Ok(json!(commands::fs::read_file(payload.path)?))
        }
        "write_file" => {
            let payload: WriteFilePayload = deserialize(payload)?;
            commands::fs::write_file(payload.path, payload.contents)?;
            Ok(Value::Null)
        }
        "list_directory" => {
            let payload: PathPayload = deserialize(payload)?;
            Ok(json!(commands::fs::list_directory(payload.path)?))
        }
        "list_source_documents" => {
            let payload: ProjectPathPayload = deserialize(payload)?;
            Ok(json!(commands::fs::list_source_documents(payload.project_path)?))
        }
        "copy_file" => {
            let payload: CopyPayload = deserialize(payload)?;
            commands::fs::copy_file(payload.source, payload.destination)?;
            Ok(Value::Null)
        }
        "copy_directory" => {
            let payload: CopyPayload = deserialize(payload)?;
            Ok(json!(commands::fs::copy_directory(
                payload.source,
                payload.destination
            )?))
        }
        "preprocess_file" => {
            let payload: PathPayload = deserialize(payload)?;
            Ok(json!(commands::fs::preprocess_file(payload.path)?))
        }
        "delete_file" => {
            let payload: PathPayload = deserialize(payload)?;
            commands::fs::delete_file(payload.path)?;
            Ok(Value::Null)
        }
        "find_related_wiki_pages" => {
            let payload: FindRelatedPayload = deserialize(payload)?;
            Ok(json!(commands::fs::find_related_wiki_pages(
                payload.project_path,
                payload.source_name
            )?))
        }
        "create_directory" => {
            let payload: PathPayload = deserialize(payload)?;
            commands::fs::create_directory(payload.path)?;
            Ok(Value::Null)
        }
        "create_project" => {
            let payload: CreateProjectPayload = deserialize(payload)?;
            Ok(json!(commands::project::create_project(
                payload.name,
                payload.path
            )?))
        }
        "open_project" => {
            let payload: PathPayload = deserialize(payload)?;
            Ok(json!(commands::project::open_project(payload.path)?))
        }
        "knowledge_base_query" => {
            let payload: KnowledgeBaseQueryPayload = deserialize(payload)?;
            Ok(json!(tauri::async_runtime::block_on(
                commands::knowledge_base::knowledge_base_query(payload.project_path, payload.request)
            )?))
        }
        "knowledge_base_document" => {
            let payload: KnowledgeBaseDocumentPayload = deserialize(payload)?;
            Ok(json!(commands::knowledge_base::knowledge_base_document(
                payload.project_path,
                payload.request
            )?))
        }
        "vector_upsert" => {
            let payload: VectorUpsertPayload = deserialize(payload)?;
            tauri::async_runtime::block_on(commands::vectorstore::vector_upsert(
                payload.project_path,
                payload.page_id,
                payload.embedding,
            ))?;
            Ok(Value::Null)
        }
        "vector_search" => {
            let payload: VectorSearchPayload = deserialize(payload)?;
            Ok(json!(tauri::async_runtime::block_on(
                commands::vectorstore::vector_search(
                    payload.project_path,
                    payload.query_embedding,
                    payload.top_k,
                )
            )?))
        }
        "vector_delete" => {
            let payload: VectorDeletePayload = deserialize(payload)?;
            tauri::async_runtime::block_on(commands::vectorstore::vector_delete(
                payload.project_path,
                payload.page_id,
            ))?;
            Ok(Value::Null)
        }
        "vector_count" => {
            let payload: ProjectPathPayload = deserialize(payload)?;
            Ok(json!(tauri::async_runtime::block_on(
                commands::vectorstore::vector_count(payload.project_path)
            )?))
        }
        other => Err(format!("unsupported invoke command: {other}")),
    }
}

fn deserialize<T: for<'de> Deserialize<'de>>(payload: Value) -> Result<T, String> {
    serde_json::from_value(payload).map_err(|error| format!("invalid payload: {error}"))
}

#[derive(Deserialize)]
struct PathPayload {
    path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectPathPayload {
    project_path: String,
}

#[derive(Deserialize)]
struct WriteFilePayload {
    path: String,
    contents: String,
}

#[derive(Deserialize)]
struct CopyPayload {
    source: String,
    destination: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FindRelatedPayload {
    project_path: String,
    source_name: String,
}

#[derive(Deserialize)]
struct CreateProjectPayload {
    name: String,
    path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KnowledgeBaseQueryPayload {
    project_path: String,
    request: commands::knowledge_base::KnowledgeBaseQueryRequest,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KnowledgeBaseDocumentPayload {
    project_path: String,
    request: commands::knowledge_base::KnowledgeBaseDocumentRequest,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorUpsertPayload {
    project_path: String,
    page_id: String,
    embedding: Vec<f32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorSearchPayload {
    project_path: String,
    query_embedding: Vec<f32>,
    top_k: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VectorDeletePayload {
    project_path: String,
    page_id: String,
}
