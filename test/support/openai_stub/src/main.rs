use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    env,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    net::TcpListener,
    signal,
    sync::{Mutex, Notify, RwLock},
    time,
};

#[derive(Clone, Debug)]
struct Config {
    delay_ms: u64,
    tool_rounds: u64,
    payload_bytes: usize,
    expected_in_flight: usize,
    barrier_timeout_ms: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            delay_ms: 0,
            tool_rounds: 1,
            payload_bytes: 0,
            expected_in_flight: 0,
            barrier_timeout_ms: 5_000,
        }
    }
}

struct BarrierState {
    expected: usize,
    arrived: usize,
    generation: u64,
    broken_generation: Option<u64>,
}

struct RequestBarrier {
    state: Mutex<BarrierState>,
    notify: Notify,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BarrierResult {
    Released,
    TimedOut(bool),
    Reconfigured,
}

impl RequestBarrier {
    fn new() -> Self {
        Self {
            state: Mutex::new(BarrierState {
                expected: 0,
                arrived: 0,
                generation: 0,
                broken_generation: None,
            }),
            notify: Notify::new(),
        }
    }

    async fn reset(&self, expected: usize) {
        let mut state = self.state.lock().await;
        state.expected = expected;
        state.arrived = 0;
        state.generation = state.generation.wrapping_add(1);
        state.broken_generation = None;
        drop(state);
        self.notify.notify_waiters();
    }

    async fn wait(&self, expected: usize, timeout_ms: u64) -> BarrierResult {
        if expected <= 1 {
            return BarrierResult::Released;
        }

        let timeout = Duration::from_millis(timeout_ms.max(1));
        loop {
            // Register before taking the lock so a release cannot be missed.
            let notified = self.notify.notified();
            let mut state = self.state.lock().await;

            if state.expected != expected {
                return BarrierResult::Reconfigured;
            }

            let generation = state.generation;
            if state.arrived + 1 >= expected {
                state.arrived = 0;
                state.generation = state.generation.wrapping_add(1);
                state.broken_generation = None;
                drop(state);
                self.notify.notify_waiters();
                return BarrierResult::Released;
            }

            state.arrived += 1;
            drop(state);

            if time::timeout(timeout, notified).await.is_err() {
                let mut state = self.state.lock().await;
                if state.expected != expected {
                    return BarrierResult::Reconfigured;
                }
                if state.generation != generation {
                    return if state.broken_generation == Some(generation) {
                        BarrierResult::TimedOut(false)
                    } else {
                        BarrierResult::Released
                    };
                }
                state.arrived = 0;
                state.generation = state.generation.wrapping_add(1);
                state.broken_generation = Some(generation);
                drop(state);
                self.notify.notify_waiters();
                return BarrierResult::TimedOut(true);
            }

            let state = self.state.lock().await;
            if state.expected != expected {
                return BarrierResult::Reconfigured;
            }
            if state.broken_generation == Some(generation) {
                return BarrierResult::TimedOut(false);
            }
            if state.generation != generation {
                return BarrierResult::Released;
            }
        }
    }
}

struct Counters {
    requests: AtomicU64,
    tool_requests: AtomicU64,
    bytes: AtomicU64,
    in_flight: AtomicU64,
    active_peak: AtomicU64,
    completed: AtomicU64,
    failed: AtomicU64,
    barrier_timeouts: AtomicU64,
}

impl Counters {
    fn new() -> Self {
        Self {
            requests: AtomicU64::new(0),
            tool_requests: AtomicU64::new(0),
            bytes: AtomicU64::new(0),
            in_flight: AtomicU64::new(0),
            active_peak: AtomicU64::new(0),
            completed: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            barrier_timeouts: AtomicU64::new(0),
        }
    }

    fn reset(&self) {
        for counter in [
            &self.requests,
            &self.tool_requests,
            &self.bytes,
            &self.active_peak,
            &self.completed,
            &self.failed,
            &self.barrier_timeouts,
        ] {
            counter.store(0, Ordering::Relaxed);
        }
    }
}

struct AppState {
    config: RwLock<Config>,
    counters: Counters,
    barrier: RequestBarrier,
    last_tools: RwLock<Value>,
}

impl AppState {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            config: RwLock::new(Config::default()),
            counters: Counters::new(),
            barrier: RequestBarrier::new(),
            last_tools: RwLock::new(json!([])),
        })
    }

    async fn set_last_tools(&self, tools: Value) {
        *self.last_tools.write().await = tools;
    }

    async fn configure(&self, input: ControlRequest) {
        let mut config = self.config.write().await;
        if let Some(value) = input.delay_ms {
            config.delay_ms = value;
        }
        if let Some(value) = input.tool_rounds {
            config.tool_rounds = value;
        }
        if let Some(value) = input.payload_bytes {
            config.payload_bytes = value;
        }
        if let Some(value) = input.expected_in_flight {
            config.expected_in_flight = value;
        }
        if let Some(value) = input.barrier_timeout_ms {
            config.barrier_timeout_ms = value;
        }
        let expected = config.expected_in_flight;
        self.counters.reset();
        drop(config);
        self.barrier.reset(expected).await;
    }

    async fn config(&self) -> Config {
        self.config.read().await.clone()
    }

    fn begin_request(self: &Arc<Self>, bytes: usize) -> RequestGuard {
        self.counters.requests.fetch_add(1, Ordering::Relaxed);
        self.counters
            .bytes
            .fetch_add(bytes as u64, Ordering::Relaxed);
        let current = self.counters.in_flight.fetch_add(1, Ordering::Relaxed) + 1;
        let mut peak = self.counters.active_peak.load(Ordering::Relaxed);
        while current > peak {
            match self.counters.active_peak.compare_exchange_weak(
                peak,
                current,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(observed) => peak = observed,
            }
        }
        RequestGuard {
            state: Arc::clone(self),
            finished: false,
        }
    }

    async fn stats(&self) -> Value {
        json!({
            "requests": self.counters.requests.load(Ordering::Relaxed),
            "tool_requests": self.counters.tool_requests.load(Ordering::Relaxed),
            "bytes": self.counters.bytes.load(Ordering::Relaxed),
            "in_flight": self.counters.in_flight.load(Ordering::Relaxed),
            "active_peak": self.counters.active_peak.load(Ordering::Relaxed),
            "completed": self.counters.completed.load(Ordering::Relaxed),
            "failed": self.counters.failed.load(Ordering::Relaxed),
            "barrier_timeouts": self.counters.barrier_timeouts.load(Ordering::Relaxed),
            "last_tools": self.last_tools.read().await.clone(),
        })
    }
}

struct RequestGuard {
    state: Arc<AppState>,
    finished: bool,
}

impl RequestGuard {
    fn finish(mut self, success: bool) {
        self.finished = true;
        if success {
            self.state
                .counters
                .completed
                .fetch_add(1, Ordering::Relaxed);
        } else {
            self.state.counters.failed.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl Drop for RequestGuard {
    fn drop(&mut self) {
        self.state
            .counters
            .in_flight
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                Some(value.saturating_sub(1))
            })
            .ok();
        if !self.finished {
            self.state.counters.failed.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[derive(Debug, Deserialize, Default)]
struct ControlRequest {
    delay_ms: Option<u64>,
    #[serde(alias = "rounds")]
    tool_rounds: Option<u64>,
    payload_bytes: Option<usize>,
    expected_in_flight: Option<usize>,
    barrier_timeout_ms: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
struct ChatRequest {
    #[serde(default)]
    messages: Vec<Message>,
    #[serde(default)]
    tools: Vec<Tool>,
}

#[derive(Debug, Deserialize, Default)]
struct Message {
    #[serde(default)]
    role: String,
}

#[derive(Debug, Deserialize, Default)]
struct Tool {
    #[serde(default)]
    function: Option<Function>,
}

#[derive(Debug, Deserialize, Default)]
struct Function {
    #[serde(default)]
    name: String,
    #[serde(default)]
    parameters: Value,
}

async fn health() -> impl IntoResponse {
    Json(json!({"ok": true}))
}

async fn stats(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(state.stats().await)
}

async fn control(
    State(state): State<Arc<AppState>>,
    Json(input): Json<ControlRequest>,
) -> impl IntoResponse {
    state.configure(input).await;
    Json(json!({"ok": true}))
}

async fn completions(State(state): State<Arc<AppState>>, body: Bytes) -> Response {
    let guard = state.begin_request(body.len());
    let request: ChatRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(_) => {
            guard.finish(false);
            return error_response(StatusCode::BAD_REQUEST, "invalid json");
        }
    };
    let last_tools: Value = request
        .tools
        .iter()
        .filter_map(|tool| tool.function.as_ref())
        .map(|function| json!({"name": function.name, "parameters": function.parameters}))
        .collect();
    state.set_last_tools(last_tools).await;

    let config = state.config().await;
    match state
        .barrier
        .wait(config.expected_in_flight, config.barrier_timeout_ms)
        .await
    {
        BarrierResult::Released => {}
        BarrierResult::TimedOut(first) => {
            if first {
                state
                    .counters
                    .barrier_timeouts
                    .fetch_add(1, Ordering::Relaxed);
            }
            guard.finish(false);
            return error_response(StatusCode::REQUEST_TIMEOUT, "in-flight barrier timed out");
        }
        BarrierResult::Reconfigured => {
            guard.finish(false);
            return error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                "in-flight barrier reconfigured",
            );
        }
    }

    if config.delay_ms > 0 {
        time::sleep(Duration::from_millis(config.delay_ms)).await;
    }

    let tool_messages = request
        .messages
        .iter()
        .filter(|message| message.role == "tool")
        .count() as u64;
    let has_counter = request.tools.iter().any(|tool| {
        tool.function
            .as_ref()
            .map(|function| function.name == "counter")
            .unwrap_or(false)
    });

    let message = if has_counter && tool_messages < config.tool_rounds {
        state.counters.tool_requests.fetch_add(1, Ordering::Relaxed);
        json!({
            "role": "assistant",
            "content": Value::Null,
            "tool_calls": [{
                "id": format!("benchmark-counter-{}", tool_messages + 1),
                "type": "function",
                "function": {"name": "counter", "arguments": "{}"}
            }]
        })
    } else {
        let mut content = "benchmark complete".to_owned();
        if config.payload_bytes > content.len() {
            content.extend(std::iter::repeat('x').take(config.payload_bytes - content.len()));
        }
        json!({"role": "assistant", "content": content})
    };

    guard.finish(true);
    (
        StatusCode::OK,
        Json(json!({
            "id": "benchmark",
            "object": "chat.completion",
            "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        })),
    )
        .into_response()
}

fn error_response(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({"error": {"message": message}}))).into_response()
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) = signal::unix::signal(signal::unix::SignalKind::terminate()) {
            signal.recv().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}

fn parse_port() -> Result<u16, String> {
    let args: Vec<String> = env::args().collect();
    let mut port = 0_u16;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--port" => {
                index += 1;
                let value = args
                    .get(index)
                    .ok_or_else(|| "--port requires a number".to_owned())?;
                port = value
                    .parse()
                    .map_err(|_| format!("invalid port: {value}"))?;
            }
            value => return Err(format!("unknown argument: {value}")),
        }
        index += 1;
    }
    Ok(port)
}

#[tokio::main]
async fn main() {
    let port = match parse_port() {
        Ok(port) => port,
        Err(error) => {
            eprintln!("openai stub: {error}");
            std::process::exit(2);
        }
    };

    let listener = match TcpListener::bind(("127.0.0.1", port)).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("openai stub: failed to bind 127.0.0.1:{port}: {error}");
            std::process::exit(1);
        }
    };
    let address: SocketAddr = match listener.local_addr() {
        Ok(address) => address,
        Err(error) => {
            eprintln!("openai stub: failed to inspect listener: {error}");
            std::process::exit(1);
        }
    };
    println!("READY {}", address.port());

    let state = AppState::new();
    let app = Router::new()
        .route("/health", get(health))
        .route("/healthz", get(health))
        .route("/stats", get(stats))
        .route("/control", post(control))
        .route("/v1/chat/completions", post(completions))
        .layer(DefaultBodyLimit::max(16 * 1024 * 1024))
        .with_state(state);

    if let Err(error) = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
    {
        eprintln!("openai stub: server error: {error}");
        std::process::exit(1);
    }
}
