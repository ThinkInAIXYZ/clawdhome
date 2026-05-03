#[cfg(unix)]
use std::process::Command;
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;
use tiny_http::{Header, Method, Request, Response, Server};

#[cfg(unix)]
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::path::{Path, PathBuf};

static CURRENT_PROJECT: Mutex<String> = Mutex::new(String::new());
static ALL_PROJECTS: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new()); // (name, path)
static PENDING_CLIPS: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new()); // (projectPath, filePath)
static PENDING_INGEST_REQUESTS: Mutex<Vec<PendingIngestRequest>> = Mutex::new(Vec::new());
static KNOWLEDGE_BASE_READY: AtomicBool = AtomicBool::new(false);
static KNOWLEDGE_BASE_READY_REASON: Mutex<String> = Mutex::new(String::new());

/// Daemon status: 0=starting, 1=running, 2=port_conflict, 3=error
static DAEMON_STATUS: AtomicU8 = AtomicU8::new(0);

const PORT: u16 = 19827;
const MAX_BIND_RETRIES: u32 = 3;
const MAX_RESTART_RETRIES: u32 = 10;
const BIND_RETRY_DELAY_SECS: u64 = 2;
const RESTART_DELAY_SECS: u64 = 5;

#[cfg(unix)]
const KNOWLEDGE_BASE_SOCKET_NAME: &str = "knowledge-base-api.sock";
#[cfg(unix)]
const KNOWLEDGE_BASE_SOCKET_INFO_NAME: &str = "knowledge-base-api.json";
#[cfg(unix)]
const KNOWLEDGE_BASE_HEARTBEAT_SOCKET_NAME: &str = "knowledge-base-heartbeat.sock";

static SERVICE_START_TIME: OnceLock<std::time::Instant> = OnceLock::new();

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingIngestRequest {
    #[serde(rename = "projectPath")]
    pub project_path: String,
    #[serde(rename = "sourcePath")]
    pub source_path: String,
    #[serde(rename = "debounceMs")]
    pub debounce_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct HttpKnowledgeBaseIngestPayload {
    #[serde(rename = "projectPath")]
    project_path: Option<String>,
    #[serde(rename = "sourcePath")]
    source_path: Option<String>,
    #[serde(rename = "sourcePaths")]
    source_paths: Option<Vec<String>>,
    #[serde(rename = "debounceMs")]
    debounce_ms: Option<u64>,
    reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct PendingIngestTakePayload {
    #[serde(rename = "projectPath")]
    project_path: Option<String>,
}

#[cfg(unix)]
#[derive(Debug, Clone)]
struct KnowledgeBaseRuntimeSecurity {
    dir_mode: u32,
    file_mode: u32,
    group: Option<String>,
    mode_label: &'static str,
}

/// Get current daemon status as a string
pub fn get_daemon_status() -> &'static str {
    match DAEMON_STATUS.load(Ordering::Relaxed) {
        0 => "starting",
        1 => "running",
        2 => "port_conflict",
        _ => "error",
    }
}

pub fn start_clip_server() {
    let _ = SERVICE_START_TIME.get_or_init(std::time::Instant::now);
    start_tcp_clip_server();
    start_knowledge_base_socket_server();
    start_knowledge_base_heartbeat_socket_server();
}

pub fn take_pending_ingest_requests(project_path: Option<&str>) -> Vec<PendingIngestRequest> {
    let mut pending = PENDING_INGEST_REQUESTS.lock().unwrap();
    match project_path {
        Some(project_path) => {
            let mut matched = Vec::new();
            let mut remaining = Vec::new();
            for request in pending.drain(..) {
                if request.project_path == project_path {
                    matched.push(request);
                } else {
                    remaining.push(request);
                }
            }
            *pending = remaining;
            matched
        }
        None => std::mem::take(&mut *pending),
    }
}

#[cfg(unix)]
fn set_knowledge_base_readiness(ready: bool, reason: impl Into<String>) {
    KNOWLEDGE_BASE_READY.store(ready, Ordering::Relaxed);
    if let Ok(mut guard) = KNOWLEDGE_BASE_READY_REASON.lock() {
        *guard = reason.into();
    }
}

#[cfg(unix)]
fn knowledge_base_readiness() -> (bool, String, &'static str) {
    let ready = KNOWLEDGE_BASE_READY.load(Ordering::Relaxed);
    let reason = KNOWLEDGE_BASE_READY_REASON
        .lock()
        .map(|value| value.clone())
        .unwrap_or_else(|_| "failed to read readiness reason".to_string());
    let status = if ready { "ready" } else { "degraded" };
    (ready, reason, status)
}

fn start_tcp_clip_server() {
    thread::spawn(|| {
        let mut restart_count: u32 = 0;

        loop {
            let server = {
                let mut last_err = String::new();
                let mut bound = None;
                for attempt in 1..=MAX_BIND_RETRIES {
                    match Server::http(format!("127.0.0.1:{}", PORT)) {
                        Ok(s) => {
                            bound = Some(s);
                            break;
                        }
                        Err(e) => {
                            last_err = e.to_string();
                            eprintln!(
                                "[Clip Server] Bind attempt {}/{} failed: {}",
                                attempt, MAX_BIND_RETRIES, e
                            );
                            if attempt < MAX_BIND_RETRIES {
                                thread::sleep(std::time::Duration::from_secs(
                                    BIND_RETRY_DELAY_SECS,
                                ));
                            }
                        }
                    }
                }
                match bound {
                    Some(s) => s,
                    None => {
                        eprintln!(
                            "[Clip Server] Port {} unavailable after {} attempts: {}",
                            PORT, MAX_BIND_RETRIES, last_err
                        );
                        DAEMON_STATUS.store(2, Ordering::Relaxed);
                        return;
                    }
                }
            };

            DAEMON_STATUS.store(1, Ordering::Relaxed);
            println!("[Clip Server] Listening on http://127.0.0.1:{}", PORT);

            for mut request in server.incoming_requests() {
                let cors_headers = cors_headers();

                if request.method() == &Method::Options {
                    respond(request, 204, String::new(), &cors_headers);
                    continue;
                }

                let url = request.url().to_string();

                match (request.method(), url.as_str()) {
                    (&Method::Get, "/status") => {
                        respond(request, 200, tcp_status_body(), &cors_headers);
                    }
                    (&Method::Get, "/project") => {
                        respond(request, 200, current_project_body(), &cors_headers);
                    }
                    (&Method::Post, "/project") => match read_request_body(&mut request) {
                        Ok(body) => {
                            let result = handle_set_project(&body);
                            let status = if result.contains(r#""ok":true"#) {
                                200
                            } else {
                                400
                            };
                            respond(request, status, result, &cors_headers);
                        }
                        Err(err) => {
                            respond(request, 400, error_body(&err), &cors_headers);
                        }
                    },
                    (&Method::Get, "/projects") => {
                        respond(request, 200, all_projects_body(), &cors_headers);
                    }
                    (&Method::Post, "/projects") => {
                        if let Ok(body) = read_request_body(&mut request) {
                            store_recent_projects(&body);
                        }
                        respond(request, 200, ok_body(), &cors_headers);
                    }
                    (&Method::Get, "/clips/pending") => {
                        respond(request, 200, pending_clips_body(), &cors_headers);
                    }
                    (&Method::Post, "/pending-ingest/take") => match read_request_body(&mut request) {
                        Ok(body) => {
                            let result = handle_pending_ingest_take(&body);
                            let status = if result.contains(r#""ok":true"#) {
                                200
                            } else {
                                400
                            };
                            respond(request, status, result, &cors_headers);
                        }
                        Err(err) => {
                            respond(request, 400, error_body(&err), &cors_headers);
                        }
                    },
                    (&Method::Post, "/clip") => match read_request_body(&mut request) {
                        Ok(body) => {
                            let result = handle_clip(&body);
                            let status = if result.contains(r#""ok":true"#) {
                                200
                            } else {
                                500
                            };
                            respond(request, status, result, &cors_headers);
                        }
                        Err(err) => {
                            respond(request, 400, error_body(&err), &cors_headers);
                        }
                    },
                    (&Method::Post, "/knowledge-base/query")
                    | (&Method::Post, "/vector_stores/search")
                    | (&Method::Post, "/knowledge-base/document")
                    | (&Method::Post, "/knowledge-base/ingest") => {
                        #[cfg(unix)]
                        {
                            respond(
                                request,
                                403,
                                knowledge_base_tcp_disabled_body(),
                                &cors_headers,
                            );
                        }

                        #[cfg(not(unix))]
                        {
                            match read_request_body(&mut request) {
                                Ok(body) => {
                                    let (status, response_body) =
                                        knowledge_base_http_response(url.as_str(), &body);
                                    respond(request, status, response_body, &cors_headers);
                                }
                                Err(err) => {
                                    respond(request, 400, error_body(&err), &cors_headers);
                                }
                            }
                        }
                    }
                    _ => {
                        respond(request, 404, error_body("Not found"), &cors_headers);
                    }
                }
            }

            DAEMON_STATUS.store(3, Ordering::Relaxed);
            restart_count += 1;

            if restart_count >= MAX_RESTART_RETRIES {
                eprintln!(
                    "[Clip Server] Exceeded max restarts ({}). Giving up.",
                    MAX_RESTART_RETRIES
                );
                return;
            }

            eprintln!(
                "[Clip Server] Crashed. Restarting in {}s (attempt {}/{})",
                RESTART_DELAY_SECS, restart_count, MAX_RESTART_RETRIES
            );
            thread::sleep(std::time::Duration::from_secs(RESTART_DELAY_SECS));
        }
    });
}

#[cfg(unix)]
fn start_knowledge_base_socket_server() {
    thread::spawn(|| {
        let mut restart_count: u32 = 0;

        loop {
            let socket_path = knowledge_base_socket_path();
            set_knowledge_base_readiness(false, "preparing knowledge base socket");
            if let Err(error) = prepare_knowledge_base_socket(&socket_path) {
                set_knowledge_base_readiness(false, format!("failed to prepare socket: {}", error));
                restart_count += 1;
                eprintln!(
                    "[Knowledge Base API] Failed to prepare socket {}: {}",
                    socket_path.display(),
                    error
                );
                if restart_count >= MAX_RESTART_RETRIES {
                    eprintln!(
                        "[Knowledge Base API] Exceeded max restarts ({}). Giving up.",
                        MAX_RESTART_RETRIES
                    );
                    return;
                }
                thread::sleep(std::time::Duration::from_secs(RESTART_DELAY_SECS));
                continue;
            }

            let server = match Server::http_unix(&socket_path) {
                Ok(server) => server,
                Err(error) => {
                    set_knowledge_base_readiness(
                        false,
                        format!("failed to bind knowledge base socket: {}", error),
                    );
                    restart_count += 1;
                    eprintln!(
                        "[Knowledge Base API] Failed to bind unix socket {}: {}",
                        socket_path.display(),
                        error
                    );
                    if restart_count >= MAX_RESTART_RETRIES {
                        eprintln!(
                            "[Knowledge Base API] Exceeded max restarts ({}). Giving up.",
                            MAX_RESTART_RETRIES
                        );
                        return;
                    }
                    thread::sleep(std::time::Duration::from_secs(RESTART_DELAY_SECS));
                    continue;
                }
            };

            if let Err(error) = tighten_socket_permissions(&socket_path) {
                eprintln!(
                    "[Knowledge Base API] Failed to tighten socket permissions on {}: {}",
                    socket_path.display(),
                    error
                );
            }
            if let Err(error) = write_socket_info_file(&socket_path) {
                eprintln!(
                    "[Knowledge Base API] Failed to write socket info file for {}: {}",
                    socket_path.display(),
                    error
                );
            }

            restart_count = 0;
            println!(
                "[Knowledge Base API] Listening on unix://{}",
                socket_path.display()
            );
            set_knowledge_base_readiness(true, "knowledge base socket is ready");
            if let Err(error) = write_socket_info_file(&socket_path) {
                eprintln!(
                    "[Knowledge Base API] Failed to refresh socket info file for {}: {}",
                    socket_path.display(),
                    error
                );
            }

            for mut request in server.incoming_requests() {
                let url = request.url().to_string();

                match (request.method(), url.as_str()) {
                    (&Method::Get, "/status") => {
                        respond(
                            request,
                            200,
                            unix_status_body(&socket_path),
                            &json_headers(),
                        );
                    }
                    (&Method::Get, "/project") => {
                        respond(request, 200, current_project_body(), &json_headers());
                    }
                    (&Method::Post, "/project") => match read_request_body(&mut request) {
                        Ok(body) => {
                            let result = handle_set_project(&body);
                            let status = if result.contains(r#""ok":true"#) {
                                200
                            } else {
                                400
                            };
                            respond(request, status, result, &json_headers());
                        }
                        Err(err) => {
                            respond(request, 400, error_body(&err), &json_headers());
                        }
                    },
                    (&Method::Post, "/pending-ingest/take") => match read_request_body(&mut request) {
                        Ok(body) => {
                            let result = handle_pending_ingest_take(&body);
                            let status = if result.contains(r#""ok":true"#) {
                                200
                            } else {
                                400
                            };
                            respond(request, status, result, &json_headers());
                        }
                        Err(err) => {
                            respond(request, 400, error_body(&err), &json_headers());
                        }
                    },
                    (&Method::Post, "/knowledge-base/query")
                    | (&Method::Post, "/vector_stores/search")
                    | (&Method::Post, "/knowledge-base/document")
                    | (&Method::Post, "/knowledge-base/ingest") => {
                        match read_request_body(&mut request) {
                            Ok(body) => {
                                let (status, response_body) =
                                    knowledge_base_http_response(url.as_str(), &body);
                                respond(request, status, response_body, &json_headers());
                            }
                            Err(err) => {
                                respond(request, 400, error_body(&err), &json_headers());
                            }
                        }
                    }
                    _ => {
                        respond(request, 404, error_body("Not found"), &json_headers());
                    }
                }
            }

            set_knowledge_base_readiness(false, "knowledge base socket server loop ended");
            if let Err(error) = write_socket_info_file(&socket_path) {
                eprintln!(
                    "[Knowledge Base API] Failed to refresh socket info file for {}: {}",
                    socket_path.display(),
                    error
                );
            }
            restart_count += 1;
            if restart_count >= MAX_RESTART_RETRIES {
                eprintln!(
                    "[Knowledge Base API] Exceeded max restarts ({}). Giving up.",
                    MAX_RESTART_RETRIES
                );
                return;
            }

            eprintln!(
                "[Knowledge Base API] Server loop ended. Restarting in {}s (attempt {}/{})",
                RESTART_DELAY_SECS, restart_count, MAX_RESTART_RETRIES
            );
            thread::sleep(std::time::Duration::from_secs(RESTART_DELAY_SECS));
        }
    });
}

#[cfg(not(unix))]
fn start_knowledge_base_socket_server() {
    eprintln!(
        "[Knowledge Base API] Unix sockets are not supported on this platform. Falling back to TCP-only behavior."
    );
}

#[cfg(unix)]
fn start_knowledge_base_heartbeat_socket_server() {
    thread::spawn(|| {
        let mut restart_count: u32 = 0;

        loop {
            let socket_path = knowledge_base_heartbeat_socket_path();
            if let Err(error) = prepare_knowledge_base_socket(&socket_path) {
                restart_count += 1;
                eprintln!(
                    "[Knowledge Base Heartbeat] Failed to prepare socket {}: {}",
                    socket_path.display(),
                    error
                );
                if restart_count >= MAX_RESTART_RETRIES {
                    eprintln!(
                        "[Knowledge Base Heartbeat] Exceeded max restarts ({}). Giving up.",
                        MAX_RESTART_RETRIES
                    );
                    return;
                }
                thread::sleep(Duration::from_secs(RESTART_DELAY_SECS));
                continue;
            }

            let server = match Server::http_unix(&socket_path) {
                Ok(server) => server,
                Err(error) => {
                    restart_count += 1;
                    eprintln!(
                        "[Knowledge Base Heartbeat] Failed to bind unix socket {}: {}",
                        socket_path.display(),
                        error
                    );
                    if restart_count >= MAX_RESTART_RETRIES {
                        eprintln!(
                            "[Knowledge Base Heartbeat] Exceeded max restarts ({}). Giving up.",
                            MAX_RESTART_RETRIES
                        );
                        return;
                    }
                    thread::sleep(Duration::from_secs(RESTART_DELAY_SECS));
                    continue;
                }
            };

            if let Err(error) = tighten_socket_permissions(&socket_path) {
                eprintln!(
                    "[Knowledge Base Heartbeat] Failed to tighten socket permissions on {}: {}",
                    socket_path.display(),
                    error
                );
            }
            if let Err(error) = write_socket_info_file(&knowledge_base_socket_path()) {
                eprintln!(
                    "[Knowledge Base Heartbeat] Failed to write socket info file for {}: {}",
                    socket_path.display(),
                    error
                );
            }

            restart_count = 0;
            println!(
                "[Knowledge Base Heartbeat] Listening on unix://{}",
                socket_path.display()
            );

            for request in server.incoming_requests() {
                match (request.method(), request.url()) {
                    (&Method::Get, "/health") => {
                        let (status_code, body) = heartbeat_status_body(&socket_path);
                        respond(request, status_code, body, &json_headers());
                    }
                    _ => {
                        respond(request, 404, error_body("Not found"), &json_headers());
                    }
                }
            }

            restart_count += 1;
            if restart_count >= MAX_RESTART_RETRIES {
                eprintln!(
                    "[Knowledge Base Heartbeat] Exceeded max restarts ({}). Giving up.",
                    MAX_RESTART_RETRIES
                );
                return;
            }

            eprintln!(
                "[Knowledge Base Heartbeat] Restarting in {}s (attempt {}/{})",
                RESTART_DELAY_SECS, restart_count, MAX_RESTART_RETRIES
            );
            thread::sleep(Duration::from_secs(RESTART_DELAY_SECS));
        }
    });
}

#[cfg(not(unix))]
fn start_knowledge_base_heartbeat_socket_server() {}

fn cors_headers() -> Vec<Header> {
    vec![
        Header::from_bytes("Access-Control-Allow-Origin", "*").unwrap(),
        Header::from_bytes("Access-Control-Allow-Methods", "GET, POST, OPTIONS").unwrap(),
        Header::from_bytes("Access-Control-Allow-Headers", "Content-Type").unwrap(),
        Header::from_bytes("Content-Type", "application/json").unwrap(),
    ]
}

fn json_headers() -> Vec<Header> {
    vec![Header::from_bytes("Content-Type", "application/json").unwrap()]
}

fn respond(request: Request, status: u16, body: String, headers: &[Header]) {
    let mut response = Response::from_string(body).with_status_code(status);
    for header in headers {
        response.add_header(header.clone());
    }
    let _ = request.respond(response);
}

fn read_request_body(request: &mut Request) -> Result<String, String> {
    let mut body = String::new();
    request
        .as_reader()
        .read_to_string(&mut body)
        .map_err(|error| format!("Failed to read body: {}", error))?;
    Ok(body)
}

fn ok_body() -> String {
    json!({ "ok": true }).to_string()
}

fn error_body(message: impl AsRef<str>) -> String {
    json!({ "ok": false, "error": message.as_ref() }).to_string()
}

fn current_project_body() -> String {
    let path = CURRENT_PROJECT.lock().unwrap().clone();
    json!({ "ok": true, "path": path }).to_string()
}

fn all_projects_body() -> String {
    let projects = ALL_PROJECTS.lock().unwrap().clone();
    let current = CURRENT_PROJECT.lock().unwrap().clone();
    let items: Vec<serde_json::Value> = projects
        .iter()
        .map(|(name, path)| {
            json!({
                "name": name,
                "path": path,
                "current": path == &current,
            })
        })
        .collect();
    json!({ "ok": true, "projects": items }).to_string()
}

fn pending_clips_body() -> String {
    let mut pending = PENDING_CLIPS.lock().unwrap();
    let items: Vec<serde_json::Value> = pending
        .iter()
        .map(|(project_path, file_path)| {
            json!({
                "projectPath": project_path,
                "filePath": file_path,
            })
        })
        .collect();
    pending.clear();
    json!({ "ok": true, "clips": items }).to_string()
}

fn store_recent_projects(body: &str) {
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(body) {
        if let Some(arr) = parsed["projects"].as_array() {
            let mut projects = ALL_PROJECTS.lock().unwrap();
            projects.clear();
            for item in arr {
                let name = item["name"].as_str().unwrap_or("").to_string();
                let path = item["path"].as_str().unwrap_or("").to_string();
                if !path.is_empty() {
                    projects.push((name, path));
                }
            }
        }
    }
}

fn knowledge_base_http_response(endpoint: &str, body: &str) -> (u16, String) {
    let current_project = CURRENT_PROJECT.lock().unwrap().clone();
    let fallback_project = if current_project.is_empty() {
        None
    } else {
        Some(current_project.as_str())
    };

    match endpoint {
        "/knowledge-base/ingest" => match handle_ingest_trigger(body, fallback_project) {
            Ok(result) => (200, result),
            Err(error) => (error.status, error_body(error.message)),
        },
        "/knowledge-base/document" => {
            match crate::commands::knowledge_base::handle_http_document(body, fallback_project) {
                Ok(result) => match serde_json::to_string(&result) {
                    Ok(body) => (200, body),
                    Err(error) => (
                        500,
                        error_body(format!("Failed to serialize response: {error}")),
                    ),
                },
                Err(error) => (error.status, error_body(error.message)),
            }
        }
        _ => match crate::commands::knowledge_base::handle_http_query(body, fallback_project) {
            Ok(result) => match serde_json::to_string(&result) {
                Ok(body) => (200, body),
                Err(error) => (
                    500,
                    error_body(format!("Failed to serialize response: {error}")),
                ),
            },
            Err(error) => (error.status, error_body(error.message)),
        },
    }
}

fn tcp_status_body() -> String {
    #[cfg(unix)]
    {
        let (ready, reason, status) = knowledge_base_readiness();
        json!({
            "ok": true,
            "version": "0.1.0",
            "knowledgeBaseTransport": "http+unix",
            "knowledgeBaseSocketPath": knowledge_base_socket_path().to_string_lossy(),
            "knowledgeBaseSocketInfoPath": knowledge_base_socket_info_path().to_string_lossy(),
            "knowledgeBaseHeartbeatSocketPath": knowledge_base_heartbeat_socket_path().to_string_lossy(),
            "knowledgeBaseHealthEndpoint": "/health",
            "knowledgeBaseReady": ready,
            "knowledgeBaseStatus": status,
            "knowledgeBaseReason": reason,
        })
        .to_string()
    }

    #[cfg(not(unix))]
    {
        json!({
            "ok": true,
            "version": "0.1.0",
            "knowledgeBaseTransport": "tcp",
        })
        .to_string()
    }
}

#[cfg(unix)]
fn unix_status_body(socket_path: &Path) -> String {
    let (ready, reason, status) = knowledge_base_readiness();
    json!({
        "ok": true,
        "version": "0.1.0",
        "transport": "http+unix",
        "socketPath": socket_path.to_string_lossy(),
        "socketInfoPath": knowledge_base_socket_info_path().to_string_lossy(),
        "heartbeatSocketPath": knowledge_base_heartbeat_socket_path().to_string_lossy(),
        "healthEndpoint": "/health",
        "ready": ready,
        "status": status,
        "reason": reason,
    })
    .to_string()
}

#[cfg(unix)]
fn knowledge_base_tcp_disabled_body() -> String {
    json!({
        "ok": false,
        "error": "Knowledge base API only accepts Unix socket requests on this platform.",
        "transport": "unix",
        "socketPath": knowledge_base_socket_path().to_string_lossy(),
        "socketInfoPath": knowledge_base_socket_info_path().to_string_lossy(),
    })
    .to_string()
}

#[cfg(unix)]
fn knowledge_base_socket_path() -> PathBuf {
    if let Some(value) = std::env::var_os("LLM_WIKI_KB_SOCKET_PATH") {
        return PathBuf::from(value);
    }

    knowledge_base_runtime_dir().join(KNOWLEDGE_BASE_SOCKET_NAME)
}

#[cfg(unix)]
fn knowledge_base_socket_info_path() -> PathBuf {
    knowledge_base_socket_path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(knowledge_base_runtime_dir)
        .join(KNOWLEDGE_BASE_SOCKET_INFO_NAME)
}

#[cfg(unix)]
fn knowledge_base_heartbeat_socket_path() -> PathBuf {
    if let Some(value) = std::env::var_os("LLM_WIKI_KB_HEARTBEAT_SOCKET_PATH") {
        return PathBuf::from(value);
    }

    knowledge_base_runtime_dir().join(KNOWLEDGE_BASE_HEARTBEAT_SOCKET_NAME)
}

#[cfg(unix)]
fn knowledge_base_runtime_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("llm-wiki"))
        .join(".llm-wiki")
        .join("run")
}

#[cfg(unix)]
fn knowledge_base_runtime_security() -> KnowledgeBaseRuntimeSecurity {
    let group = std::env::var("LLM_WIKI_KB_RUNTIME_GROUP")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    if let Some(group) = group {
        KnowledgeBaseRuntimeSecurity {
            dir_mode: 0o770,
            file_mode: 0o660,
            group: Some(group),
            mode_label: "group_shared",
        }
    } else {
        KnowledgeBaseRuntimeSecurity {
            dir_mode: 0o700,
            file_mode: 0o600,
            group: None,
            mode_label: "private",
        }
    }
}

#[cfg(unix)]
fn apply_runtime_group(path: &Path, group: Option<&str>) -> Result<(), String> {
    let Some(group) = group else {
        return Ok(());
    };

    let output = Command::new("/usr/bin/chgrp")
        .arg(group)
        .arg(path)
        .output()
        .map_err(|error| format!("Failed to invoke chgrp for '{}': {}", path.display(), error))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to assign group '{}' to '{}': {}",
            group,
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

#[cfg(unix)]
fn prepare_knowledge_base_socket(socket_path: &Path) -> Result<(), String> {
    let security = knowledge_base_runtime_security();
    let runtime_dir = socket_path.parent().ok_or_else(|| {
        format!(
            "Socket path '{}' has no parent directory",
            socket_path.display()
        )
    })?;

    fs::create_dir_all(runtime_dir)
        .map_err(|error| format!("Failed to create '{}': {}", runtime_dir.display(), error))?;
    apply_runtime_group(runtime_dir, security.group.as_deref())?;
    fs::set_permissions(runtime_dir, fs::Permissions::from_mode(security.dir_mode)).map_err(
        |error| {
            format!(
                "Failed to set runtime permissions on '{}': {}",
                runtime_dir.display(),
                error
            )
        },
    )?;

    if socket_path.exists() {
        fs::remove_file(socket_path).map_err(|error| {
            format!(
                "Failed to remove stale socket '{}': {}",
                socket_path.display(),
                error
            )
        })?;
    }

    Ok(())
}

#[cfg(unix)]
fn tighten_socket_permissions(socket_path: &Path) -> Result<(), String> {
    let security = knowledge_base_runtime_security();
    apply_runtime_group(socket_path, security.group.as_deref())?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(security.file_mode)).map_err(
        |error| {
            format!(
                "Failed to set socket permissions on '{}': {}",
                socket_path.display(),
                error
            )
        },
    )
}

#[cfg(unix)]
fn write_socket_info_file(socket_path: &Path) -> Result<(), String> {
    let info_path = knowledge_base_socket_info_path();
    let (ready, reason, status) = knowledge_base_readiness();
    let security = knowledge_base_runtime_security();
    let info = json!({
        "transport": "http+unix",
        "socketPath": socket_path.to_string_lossy(),
        "statusEndpoint": "/status",
        "projectEndpoint": "/project",
        "searchEndpoint": "/vector_stores/search",
        "searchAliases": ["/knowledge-base/query"],
        "ingestEndpoint": "/knowledge-base/ingest",
        "documentEndpoint": "/knowledge-base/document",
        "heartbeatSocketPath": knowledge_base_heartbeat_socket_path().to_string_lossy(),
        "healthEndpoint": "/health",
        "ready": ready,
        "status": status,
        "reason": reason,
        "security": {
            "runtimeMode": security.mode_label,
            "runtimeGroup": security.group,
            "socketDirMode": format!("{:04o}", security.dir_mode),
            "socketFileMode": format!("{:04o}", security.file_mode),
            "knowledgeBaseTcp": "disabled_on_unix"
        }
    });

    fs::write(&info_path, format!("{}\n", info)).map_err(|error| {
        format!(
            "Failed to write socket info file '{}': {}",
            info_path.display(),
            error
        )
    })?;
    apply_runtime_group(&info_path, security.group.as_deref())?;
    fs::set_permissions(&info_path, fs::Permissions::from_mode(security.file_mode)).map_err(
        |error| {
            format!(
                "Failed to set info file permissions on '{}': {}",
                info_path.display(),
                error
            )
        },
    )
}

#[cfg(unix)]
fn heartbeat_status_body(socket_path: &Path) -> (u16, String) {
    let timestamp = chrono::Local::now().to_rfc3339();
    let uptime_seconds = SERVICE_START_TIME
        .get()
        .map(|started| started.elapsed().as_secs())
        .unwrap_or(0);
    let (ready, reason, status) = knowledge_base_readiness();
    let status_code = if ready { 200 } else { 503 };
    (
        status_code,
        json!({
            "ok": ready,
            "ready": ready,
            "status": status,
            "reason": reason,
            "service": "llm-wiki",
            "timestamp": timestamp,
            "pid": std::process::id(),
            "transport": "http+unix",
            "socketPath": socket_path.to_string_lossy(),
            "kbSocketPath": knowledge_base_socket_path().to_string_lossy(),
            "healthEndpoint": "/health",
            "uptimeSeconds": uptime_seconds,
        })
        .to_string(),
    )
}

fn handle_ingest_trigger(
    body: &str,
    fallback_project_path: Option<&str>,
) -> Result<String, crate::commands::knowledge_base::HttpQueryError> {
    let payload: HttpKnowledgeBaseIngestPayload =
        serde_json::from_str(body).map_err(|error| crate::commands::knowledge_base::HttpQueryError {
            status: 400,
            message: format!("Invalid JSON: {error}"),
        })?;

    let project_path = payload
        .project_path
        .filter(|value| !value.trim().is_empty())
        .or_else(|| fallback_project_path.map(|value| value.to_string()))
        .ok_or_else(|| crate::commands::knowledge_base::HttpQueryError {
            status: 400,
            message: "projectPath is required (set via POST /project or include in request body)"
                .to_string(),
        })?;

    crate::commands::knowledge_base::validate_project_path_input(&project_path).map_err(
        |message| crate::commands::knowledge_base::HttpQueryError {
            status: 400,
            message,
        },
    )?;

    let raw_sources = payload
        .source_paths
        .unwrap_or_default()
        .into_iter()
        .chain(payload.source_path.into_iter())
        .filter(|value| !value.trim().is_empty())
        .collect::<Vec<_>>();

    if raw_sources.is_empty() {
        return Err(crate::commands::knowledge_base::HttpQueryError {
            status: 400,
            message: "sourcePath or sourcePaths is required".to_string(),
        });
    }

    let debounce_ms = payload.debounce_ms.unwrap_or(2500).clamp(200, 30_000);
    let mut accepted = Vec::new();
    for source_path in raw_sources {
        let normalized_source_path =
            crate::commands::knowledge_base::normalize_ingest_source_path_input(
                &project_path,
                &source_path,
            )
            .map_err(|message| crate::commands::knowledge_base::HttpQueryError {
                status: 400,
                message,
            })?;

        accepted.push(PendingIngestRequest {
            project_path: project_path.clone(),
            source_path: normalized_source_path,
            debounce_ms,
            reason: payload.reason.clone(),
        });
    }

    queue_pending_ingest_requests(&accepted);

    Ok(json!({
        "ok": true,
        "queued": accepted.len(),
        "projectPath": project_path,
        "debounceMs": debounce_ms,
        "requests": accepted,
    })
    .to_string())
}

fn queue_pending_ingest_requests(requests: &[PendingIngestRequest]) {
    let mut pending = PENDING_INGEST_REQUESTS.lock().unwrap();
    for request in requests {
        if let Some(existing) = pending.iter_mut().find(|value| {
            value.project_path == request.project_path && value.source_path == request.source_path
        }) {
            *existing = request.clone();
        } else {
            pending.push(request.clone());
        }
    }
}

fn handle_pending_ingest_take(body: &str) -> String {
    let payload: PendingIngestTakePayload = match serde_json::from_str(body) {
        Ok(value) => value,
        Err(error) => {
            return json!({
                "ok": false,
                "error": format!("Invalid JSON: {error}"),
            })
            .to_string()
        }
    };

    json!({
        "ok": true,
        "requests": take_pending_ingest_requests(payload.project_path.as_deref()),
    })
    .to_string()
}

fn handle_set_project(body: &str) -> String {
    let parsed: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return format!(r#"{{"ok":false,"error":"Invalid JSON: {}"}}"#, e),
    };

    let path = match parsed["path"].as_str() {
        Some(p) => p.to_string(),
        None => return r#"{"ok":false,"error":"path field is required"}"#.to_string(),
    };

    #[cfg(unix)]
    if let Err(error) = crate::commands::knowledge_base::validate_project_path_input(&path) {
        return format!(r#"{{"ok":false,"error":"{}"}}"#, error.replace('"', "\\\""));
    }

    match CURRENT_PROJECT.lock() {
        Ok(mut guard) => {
            *guard = path;
            r#"{"ok":true}"#.to_string()
        }
        Err(e) => format!(r#"{{"ok":false,"error":"Lock error: {}"}}"#, e),
    }
}

fn handle_clip(body: &str) -> String {
    let parsed: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return format!(r#"{{"ok":false,"error":"Invalid JSON: {}"}}"#, e),
    };

    let title = parsed["title"].as_str().unwrap_or("Untitled");
    let url = parsed["url"].as_str().unwrap_or("");
    let content = parsed["content"].as_str().unwrap_or("");

    let project_path_from_body = parsed["projectPath"].as_str().unwrap_or("").to_string();
    let project_path = if project_path_from_body.is_empty() {
        match CURRENT_PROJECT.lock() {
            Ok(guard) => guard.clone(),
            Err(e) => return format!(r#"{{"ok":false,"error":"Lock error: {}"}}"#, e),
        }
    } else {
        project_path_from_body
    };

    if project_path.is_empty() {
        return r#"{"ok":false,"error":"projectPath is required (set via POST /project or include in request body)"}"#
            .to_string();
    }

    if content.is_empty() {
        return r#"{"ok":false,"error":"content is required"}"#.to_string();
    }

    let date = chrono::Local::now().format("%Y-%m-%d").to_string();
    let date_compact = chrono::Local::now().format("%Y%m%d").to_string();

    let slug_raw: String = title
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == ' ' || c == '-' {
                c
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
        .to_lowercase();
    let slug: String = slug_raw.chars().take(50).collect();

    let base_name = format!("{}-{}", slug, date_compact);
    let dir_path = std::path::Path::new(&project_path)
        .join("raw")
        .join("sources");

    if let Err(e) = std::fs::create_dir_all(&dir_path) {
        return format!(
            r#"{{"ok":false,"error":"Failed to create directory: {}"}}"#,
            e
        );
    }

    let mut file_path = dir_path.join(format!("{}.md", base_name));
    let mut counter = 2u32;
    while file_path.exists() {
        file_path = dir_path.join(format!("{}-{}.md", base_name, counter));
        counter += 1;
    }
    let file_path = file_path.to_string_lossy().to_string();

    let markdown = format!(
        "---\ntype: clip\ntitle: \"{}\"\nurl: \"{}\"\nclipped: {}\norigin: web-clip\nsources: []\ntags: [web-clip]\n---\n\n# {}\n\nSource: {}\n\n{}\n",
        title.replace('"', r#"\""#),
        url.replace('"', r#"\""#),
        date,
        title,
        url,
        content,
    );

    if let Err(e) = std::fs::write(&file_path, &markdown) {
        return format!(r#"{{"ok":false,"error":"Failed to write file: {}"}}"#, e);
    }

    let relative_path = {
        let full = std::path::Path::new(&file_path);
        let base = std::path::Path::new(&project_path);
        full.strip_prefix(base)
            .map(|p| p.to_string_lossy().replace('\\', "/"))
            .unwrap_or_else(|_| file_path.replace('\\', "/"))
    };

    if let Ok(mut pending) = PENDING_CLIPS.lock() {
        pending.push((project_path, file_path.clone()));
    }

    format!(r#"{{"ok":true,"path":"{}"}}"#, relative_path)
}
