use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    env, fs,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    net::TcpStream,
    os::{fd::AsRawFd, unix::process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn interrupt(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}

#[derive(Clone, Debug)]
struct Options {
    command: String,
    profiles: Vec<String>,
    interval_ms: u64,
    context_bytes: usize,
    max_agents: Option<u64>,
    pin_cpus: bool,
    managed: bool,
    output: Option<PathBuf>,
}
impl Options {
    fn parse(args: &[String]) -> Result<Self> {
        let mut out = Self {
            command: args.first().cloned().unwrap_or_else(|| "run".into()),
            profiles: vec!["A".into(), "B".into()],
            interval_ms: 100,
            context_bytes: 65536,
            max_agents: None,
            pin_cpus: false,
            managed: false,
            output: None,
        };
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--managed" => out.managed = true,
                "--pin-cpus" => out.pin_cpus = true,
                "--profiles" | "--interval-ms" | "--context-bytes" | "--max-agents"
                | "--output" => {
                    let key = &args[i];
                    i += 1;
                    let value = args.get(i).ok_or("missing option value")?;
                    match key.as_str() {
                        "--profiles" => {
                            out.profiles = value.split(',').map(str::to_owned).collect()
                        }
                        "--interval-ms" => out.interval_ms = value.parse()?,
                        "--context-bytes" => out.context_bytes = value.parse()?,
                        "--max-agents" => out.max_agents = Some(value.parse()?),
                        "--output" => out.output = Some(PathBuf::from(value)),
                        _ => unreachable!(),
                    }
                }
                "--help" | "-h" => out.command = "help".into(),
                other if out.command == "report" && out.output.is_none() => {
                    out.output = Some(other.into())
                }
                other => return Err(format!("unknown argument: {other}").into()),
            }
            i += 1;
        }
        if out.interval_ms == 0
            || out.context_bytes == 0
            || out.max_agents == Some(0)
            || out.profiles.is_empty()
            || out.profiles.iter().any(|p| p != "A" && p != "B")
        {
            return Err("invalid profile or non-positive limit".into());
        }
        Ok(out)
    }
}
fn read(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().into())
}
fn write_json(path: impl AsRef<Path>, value: &Value) -> Result<()> {
    fs::write(path, serde_json::to_vec_pretty(value)?)?;
    Ok(())
}
fn now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
}
fn stat(value: &str, key: &str) -> u64 {
    value
        .lines()
        .find_map(|line| {
            let mut words = line.split_whitespace();
            if words.next()? == key {
                words.next()?.parse().ok()
            } else {
                None
            }
        })
        .unwrap_or(0)
}
fn group() -> Result<PathBuf> {
    let membership = fs::read_to_string("/proc/self/cgroup")?;
    let path = membership
        .lines()
        .find_map(|line| line.strip_prefix("0::"))
        .ok_or("cgroup v2 required")?;
    Ok(Path::new("/sys/fs/cgroup").join(path.trim_start_matches('/')))
}
fn cpus(text: &str) -> Result<Vec<usize>> {
    let mut output = vec![];
    for part in text.trim().split(',') {
        let ends: Vec<_> = part.split('-').collect();
        let start: usize = ends[0].parse()?;
        let end: usize = ends.last().unwrap().parse()?;
        output.extend(start..=end);
    }
    output.sort_unstable();
    output.dedup();
    Ok(output)
}
fn available_cpus() -> Result<Vec<usize>> {
    let status = fs::read_to_string("/proc/self/status")?;
    cpus(
        status
            .lines()
            .find_map(|l| l.strip_prefix("Cpus_allowed_list:"))
            .ok_or("CPU affinity unavailable")?,
    )
}
fn dimensions(profile: &str) -> (usize, u64) {
    if profile == "A" {
        (1, 536_870_912)
    } else {
        (2, 1_073_741_824)
    }
}
fn required(pin: bool) -> Vec<&'static str> {
    let mut out = vec!["cpu", "memory", "pids"];
    if pin {
        out.push("cpuset");
    }
    out
}
fn delegate(pin: bool) -> Result<PathBuf> {
    let root = group()?;
    if !root
        .file_name()
        .unwrap()
        .to_string_lossy()
        .starts_with("omunculus-bench-")
    {
        return Err("refusing to modify a cgroup not owned by this benchmark".into());
    }
    if read(root.join("cgroup.procs")).as_deref() != Some(&std::process::id().to_string()) {
        return Err("benchmark cgroup contains other processes".into());
    }
    let controllers = read(root.join("cgroup.controllers")).ok_or("controllers unavailable")?;
    for name in required(pin) {
        if !controllers.split_whitespace().any(|word| word == name) {
            return Err(format!("controller not delegated: {name}").into());
        }
    }
    let observer = root.join("observer");
    fs::create_dir(&observer)?;
    fs::write(
        observer.join("cgroup.procs"),
        std::process::id().to_string(),
    )?;
    fs::write(
        root.join("cgroup.subtree_control"),
        required(pin)
            .iter()
            .map(|s| format!("+{s}"))
            .collect::<Vec<_>>()
            .join(" "),
    )?;
    Ok(root)
}

struct Budget {
    path: PathBuf,
    controls: Value,
}
impl Budget {
    fn new(root: &Path, profile: &str, pin: bool) -> Result<Self> {
        let (count, memory) = dimensions(profile);
        let path = root.join(format!("profile-{profile}"));
        fs::create_dir(&path)?;
        let mut budget = Self {
            path,
            controls: json!({}),
        };
        let mut controls = BTreeMap::from([
            ("cpu.max", format!("{} 100000", count * 100000)),
            ("memory.max", memory.to_string()),
            ("memory.swap.max", "0".into()),
            ("memory.oom.group", "1".into()),
            ("pids.max", "max".into()),
        ]);
        if pin {
            let available = available_cpus()?;
            if available.len() < count {
                return Err("not enough CPUs to pin this profile".into());
            }
            controls.insert(
                "cpuset.cpus",
                available[..count]
                    .iter()
                    .map(usize::to_string)
                    .collect::<Vec<_>>()
                    .join(","),
            );
            fs::write(
                budget.path.join("cpuset.mems"),
                read(root.join("cpuset.mems.effective")).ok_or("cpuset unavailable")?,
            )?;
        }
        for (name, value) in &controls {
            fs::write(budget.path.join(name), value)?;
            let actual = read(budget.path.join(name)).ok_or("control unreadable")?;
            let equal = if *name == "cpuset.cpus" {
                cpus(&actual)? == cpus(value)?
            } else {
                actual == *value
            };
            if !equal {
                return Err(format!("ineffective control: {name}").into());
            }
        }
        if pin
            && cpus(&read(budget.path.join("cpuset.cpus.effective")).ok_or("no effective cpuset")?)?
                != cpus(&controls["cpuset.cpus"])?
        {
            return Err("effective cpuset differs from requested CPUs".into());
        }
        let mut ancestor = Some(root);
        while let Some(parent) = ancestor {
            if parent == Path::new("/sys/fs/cgroup") {
                break;
            }
            if let Some(limit) = read(parent.join("memory.max")) {
                if limit != "max" && limit.parse::<u64>()? < memory {
                    return Err("ancestor memory budget is smaller".into());
                }
            }
            if let Some(limit) = read(parent.join("cpu.max")) {
                let fields: Vec<_> = limit.split_whitespace().collect();
                if fields[0] != "max"
                    && fields[0].parse::<f64>()? / fields[1].parse::<f64>()? < count as f64
                {
                    return Err("ancestor CPU budget is smaller".into());
                }
            }
            ancestor = parent.parent();
        }
        budget.controls = serde_json::to_value(controls)?;
        Ok(budget)
    }
    fn spawn(&self, command: &mut Command) -> Result<Child> {
        let file = OpenOptions::new()
            .write(true)
            .open(self.path.join("cgroup.procs"))?;
        let fd = file.as_raw_fd();
        // No allocation or subprocess before entering the budget. Writing 0
        // moves the calling child, then exec creates the measured runtime.
        unsafe {
            command.pre_exec(move || {
                if libc::write(fd, b"0".as_ptr().cast(), 1) != 1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        drop(file);
        Ok(child)
    }
    fn sample(&self) -> Value {
        let mut sample = json!({"at_ms": now()});
        for name in [
            "memory.current",
            "memory.peak",
            "memory.stat",
            "memory.events",
            "memory.swap.current",
            "cpu.stat",
            "cpu.pressure",
            "memory.pressure",
            "io.pressure",
            "pids.current",
            "pids.peak",
            "pids.events",
            "cgroup.events",
        ] {
            sample[name] = json!(read(self.path.join(name)));
        }
        sample["pids"] = json!(read(self.path.join("cgroup.procs")));
        sample
    }
    fn kill(&self) {
        let _ = fs::write(self.path.join("cgroup.kill"), "1");
    }
}
impl Drop for Budget {
    fn drop(&mut self) {
        self.kill();
        for _ in 0..100 {
            if stat(
                &read(self.path.join("cgroup.events")).unwrap_or_default(),
                "populated",
            ) == 0
            {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = fs::remove_dir(&self.path);
    }
}
struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn http(port: u16, path: &str, body: Option<Value>) -> Result<Value> {
    let mut stream =
        TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_secs(5))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let payload = body.as_ref().map(Value::to_string).unwrap_or_default();
    write!(stream, "{} {} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}", if body.is_some() {"POST"} else {"GET"}, path, payload.len(), payload)?;
    let mut response = String::new();
    stream.take(1_048_576).read_to_string(&mut response)?;
    let (headers, data) = response
        .split_once("\r\n\r\n")
        .ok_or("invalid stub response")?;
    if !headers.starts_with("HTTP/1.1 200 ") {
        return Err(format!("stub HTTP error: {headers}").into());
    }
    Ok(serde_json::from_str(data)?)
}
fn start_stub(root: &Path, output: &Path) -> Result<(OwnedChild, u16)> {
    let mut child = OwnedChild(
        Command::new(root.join("_build/bench/native/stub/release/benchmark_stub"))
            .args(["--port", "0"])
            .env("TOKIO_WORKER_THREADS", "2")
            .stdout(Stdio::piped())
            .stderr(File::create(output.join("stub.log"))?)
            .spawn()?,
    );
    let stdout = child.0.stdout.as_mut().unwrap();
    unsafe {
        libc::fcntl(stdout.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK);
    }
    let mut buffer = vec![];
    let start = Instant::now();
    loop {
        let mut bytes = [0; 256];
        match stdout.read(&mut bytes) {
            Ok(0) => return Err("Rust stub exited before READY".into()),
            Ok(n) => buffer.extend_from_slice(&bytes[..n]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => (),
            Err(error) => return Err(error.into()),
        }
        if let Some(end) = buffer.iter().position(|b| *b == b'\n') {
            let line = std::str::from_utf8(&buffer[..end])?;
            let port = line
                .strip_prefix("READY ")
                .ok_or("invalid stub READY")?
                .trim()
                .parse()?;
            http(
                port,
                "/control",
                Some(
                    json!({"delay_ms":86400000,"tool_rounds":0,"expected_in_flight":0,"payload_bytes":0}),
                ),
            )?;
            return Ok((child, port));
        }
        if start.elapsed() > Duration::from_secs(10) {
            return Err("Rust stub startup timeout".into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[derive(Default)]
struct Progress {
    launched: u64,
    resident: u64,
    limit: bool,
    failure: Option<String>,
    buffer: String,
}
impl Progress {
    fn update(&mut self, events: &mut File) -> Result<()> {
        events.read_to_string(&mut self.buffer)?;
        while let Some(end) = self.buffer.find('\n') {
            let line = self.buffer[..end].to_owned();
            self.buffer.drain(..=end);
            if let Ok(event) = serde_json::from_str::<Value>(&line) {
                match event["type"].as_str() {
                    Some("launch") => {
                        self.launched = event["agent"].as_u64().unwrap_or(self.launched)
                    }
                    Some("resident") => {
                        self.resident = event["agents"].as_u64().unwrap_or(self.resident)
                    }
                    Some("limit") => self.limit = true,
                    Some("failure") => self.failure = Some(event["reason"].to_string()),
                    _ => (),
                }
            }
        }
        Ok(())
    }
}
fn reason(
    oom: u64,
    interrupted: bool,
    failure: &Option<String>,
    limit: bool,
    status: Option<i32>,
) -> String {
    if interrupted {
        "interrupted".into()
    } else if oom > 0 {
        "oom".into()
    } else if let Some(value) = failure {
        format!("agent_error: {value}")
    } else if limit {
        "exploration_limit".into()
    } else {
        format!("process_exit: {status:?}")
    }
}
fn measure(
    root: &Path,
    delegated: &Path,
    output: &Path,
    profile: &str,
    options: &Options,
) -> Result<Value> {
    let directory = output.join(profile);
    fs::create_dir(&directory)?;
    let budget = Budget::new(delegated, profile, options.pin_cpus)?;
    let (_stub, port) = start_stub(root, &directory)?;
    let work = directory.join("work");
    let home = directory.join("home");
    fs::create_dir(&home)?;
    let config = json!({"work_dir":work, "model_url":format!("http://127.0.0.1:{port}"),
        "context_bytes":options.context_bytes,"interval_ms":options.interval_ms,"max_agents":options.max_agents});
    let config_path = directory.join("config.json");
    write_json(&config_path, &config)?;
    let events_path = directory.join("agents.ndjson");
    let events_out = File::create(&events_path)?;
    let (count, _) = dimensions(profile);
    let mut command = Command::new(root.join("_build/bench/rel/benchmark/bin/benchmark"));
    command
        .args(["eval", "Omunculus.Benchmark.Driver.main()"])
        .env("OMUNCULUS_BENCH_CONFIG", &config_path)
        .env(
            "ERL_FLAGS",
            format!("+S {count}:{count} +SDcpu 1 +SDio 1 +A 1"),
        )
        .env("ERL_AFLAGS", "")
        .env("ERL_ZFLAGS", "")
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .stdout(events_out)
        .stderr(File::create(directory.join("driver.log"))?);
    let mut driver = OwnedChild(budget.spawn(&mut command)?);
    let mut events = File::open(events_path)?;
    let mut progress = Progress::default();
    let mut samples = File::create(directory.join("samples.ndjson"))?;
    let started = Instant::now();
    let mut last_print = Instant::now();
    let mut peak_http = 0;
    let mut limit_seen = None;
    let mut monitor_error = None;
    loop {
        progress.update(&mut events)?;
        let mut sample = budget.sample();
        match http(port, "/stats", None) {
            Ok(mut stats) => {
                peak_http = peak_http.max(stats["active_peak"].as_u64().unwrap_or(0));
                stats.as_object_mut().unwrap().remove("last_tools");
                sample["stub"] = stats;
            }
            Err(error) => {
                monitor_error = Some(error.to_string());
            }
        }
        sample["launched"] = json!(progress.launched);
        sample["resident"] = json!(progress.resident);
        writeln!(samples, "{sample}")?;
        samples.flush()?;
        if last_print.elapsed() >= Duration::from_secs(5) {
            println!(
                "{profile}: launched={} confirmed={} memory={} MiB",
                progress.launched,
                progress.resident.min(peak_http),
                sample["memory.current"]
                    .as_str()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0)
                    / 1048576
            );
            last_print = Instant::now();
        }
        if driver.0.try_wait()?.is_some() || STOP.load(Ordering::Relaxed) || monitor_error.is_some()
        {
            break;
        }
        if progress.limit {
            let when = limit_seen.get_or_insert_with(Instant::now);
            if peak_http >= progress.resident || when.elapsed() > Duration::from_secs(5) {
                break;
            }
        }
        thread::sleep(Duration::from_millis(250));
    }
    progress.update(&mut events)?;
    let final_sample = budget.sample();
    let oom = stat(
        final_sample["memory.events"].as_str().unwrap_or(""),
        "oom_kill",
    );
    let status = driver.0.try_wait()?.and_then(|status| status.code());
    let stop_reason = monitor_error
        .map(|error| format!("observer_error: {error}"))
        .unwrap_or_else(|| {
            reason(
                oom,
                STOP.load(Ordering::Relaxed),
                &progress.failure,
                progress.limit,
                status,
            )
        });
    let result = json!({"profile":profile,"controls":budget.controls,"cpu_pinning":options.pin_cpus,
        "launched_agents":progress.launched,"assembled_agents":progress.resident,
        "confirmed_agents":progress.resident.min(peak_http),"http_peak":peak_http,
        "reason":stop_reason,"elapsed_seconds":started.elapsed().as_secs_f64(),"final":final_sample,
        "config":config,"http_pool_size":65536,"database":"shared","step":1});
    write_json(directory.join("result.json"), &result)?;
    budget.kill();
    let _ = driver.0.wait();
    drop(budget);
    fs::remove_dir_all(work)?;
    fs::remove_dir_all(home)?;
    println!(
        "{profile}: confirmed={} stopped={}",
        result["confirmed_agents"], result["reason"]
    );
    Ok(result)
}
fn report(output: &Path) -> Result<()> {
    let mut csv = String::from(
        "profile,confirmed_agents,launched_agents,peak_bytes,elapsed_seconds,reason\n",
    );
    let mut md = String::from("# Capacidade residente — rampa linear\n\nUm agente acrescentado por vez; os anteriores continuam vivos aguardando o stub Rust. CPU e RAM abrangem BEAM e descendentes. Stub e coletor Rust ficam fora.\n\n| Perfil | Agentes confirmados | Último agente iniciado | Pico MiB | Parada |\n|---|---:|---:|---:|---|\n");
    for profile in ["A", "B"] {
        let path = output.join(profile).join("result.json");
        if !path.exists() {
            continue;
        }
        let value: Value = serde_json::from_slice(&fs::read(path)?)?;
        let peak = value["final"]["memory.peak"]
            .as_str()
            .unwrap_or("0")
            .parse::<u64>()?;
        let reason = value["reason"]
            .as_str()
            .unwrap_or("unknown")
            .replace(['\n', ',', '|'], " ");
        csv.push_str(&format!(
            "{},{},{},{},{},{}\n",
            profile,
            value["confirmed_agents"],
            value["launched_agents"],
            peak,
            value["elapsed_seconds"],
            reason
        ));
        md.push_str(&format!(
            "| {profile} | {} | {} | {:.1} | {reason} |\n",
            value["confirmed_agents"],
            value["launched_agents"],
            peak as f64 / 1048576.0
        ));
    }
    md.push_str("\nA: quota de 1 CPU/512 MiB; B: quota de 2 CPUs/1 GiB; swap zero. O contador confirmado cruza runs montadas com requisições simultâneas recebidas pelo stub.\n\nEste é um teste de residência até falhar, não throughput nem um SLO de latência. `exploration_limit` significa teste limitado pelo argumento --max-agents, não teto do hardware. O último contador confirmado é conservador devido ao intervalo de coleta.\n\nContexto de 64 KiB por padrão, banco/workspace compartilhado e uma conexão SQLite por agente. Pool HTTP de 65.536 conexões apenas no benchmark para não parar no padrão de 50. Confira parâmetros em manifest.json e A/B/config.json.\n");
    fs::write(output.join("summary.csv"), csv)?;
    fs::write(output.join("report.md"), md)?;
    Ok(())
}
fn output(args: &[&str]) -> String {
    Command::new(args[0])
        .args(&args[1..])
        .output()
        .map(|r| String::from_utf8_lossy(&r.stdout).trim().into())
        .unwrap_or_default()
}
fn preflight(root: &Path) -> Result<()> {
    for file in [
        "_build/bench/native/stub/release/benchmark_stub",
        "_build/bench/rel/benchmark/bin/benchmark",
    ] {
        if !root.join(file).is_file() {
            return Err("run mise run benchmark:build first".into());
        }
    }
    if !Path::new("/sys/fs/cgroup/cgroup.controllers").exists() {
        return Err("cgroup v2 required".into());
    }
    Ok(())
}
fn main_result() -> Result<()> {
    unsafe {
        libc::signal(libc::SIGINT, interrupt as *const () as usize);
        libc::signal(libc::SIGTERM, interrupt as *const () as usize);
    }
    let arguments: Vec<_> = env::args().skip(1).collect();
    let options = Options::parse(&arguments)?;
    let root = env::current_dir()?;
    match options.command.as_str() {
        "stamp" => {
            write_json(
                root.join("_build/bench/native/build.json"),
                &json!({
                    "built_at_ms": now(),
                    "revision": output(&["git", "rev-parse", "HEAD"]),
                    "rust": output(&["rustc", "--version"]),
                    "elixir": output(&["elixir", "--version"]),
                    "source_hashes": output(&["sha256sum", "bench/lib/driver.ex",
                        "bench/runner/src/main.rs", "bench/runner/Cargo.lock",
                        "bench/stub/src/main.rs", "bench/stub/Cargo.lock", "mix.lock"]),
                    "stub_source": "master:3a484b6:priv/benchmark_stub"
                }),
            )?;
            return Ok(());
        }
        "help" => {
            println!("capacity_benchmark run [--profiles A,B] [--interval-ms 100] [--context-bytes 65536] [--pin-cpus] [--max-agents N] [--output DIR]\nDefault: add one resident agent per interval until failure, once per hardware profile.\ncapacity_benchmark preflight\ncapacity_benchmark report [DIR]");
            return Ok(());
        }
        "report" => return report(&options.output.unwrap_or_else(|| root.join("bench/results"))),
        "preflight" => {
            preflight(&root)?;
            println!("Build and cgroup v2 available. Delegation is verified on launch; cpuset is optional.");
            return Ok(());
        }
        "run" => (),
        _ => return Err("unknown command".into()),
    }
    preflight(&root)?;
    if !options.managed {
        let mut command = Command::new("systemd-run");
        command
            .args([
                "--user",
                "--quiet",
                "--wait",
                "--pipe",
                "--collect",
                "--property=Delegate=yes",
                "--property=TasksMax=infinity",
                "--property=KillMode=control-group",
            ])
            .arg(format!(
                "--unit=omunculus-bench-{}-{}",
                std::process::id(),
                now()
            ))
            .arg(format!("--working-directory={}", root.display()));
        for name in ["PATH", "HOME"] {
            command.arg(format!("--setenv={name}={}", env::var(name)?));
        }
        let status = command
            .arg(env::current_exe()?)
            .args(&arguments)
            .arg("--managed")
            .status()?;
        if !status.success() {
            return Err(format!("benchmark service exited: {status}").into());
        }
        return Ok(());
    }
    let delegated = delegate(options.pin_cpus)?;
    let directory = options
        .output
        .clone()
        .unwrap_or_else(|| root.join("bench/results"));
    let directory = if directory.is_absolute() {
        directory
    } else {
        root.join(directory)
    };
    if directory.exists() {
        if options.output.is_some() || directory.is_symlink() {
            return Err("output directory already exists".into());
        }
        fs::remove_dir_all(&directory)?;
    }
    fs::create_dir_all(&directory)?;
    write_json(
        directory.join("manifest.json"),
        &json!({"version":2,"strategy":"linear_resident","step":1,
        "interval_ms":options.interval_ms,"context_bytes":options.context_bytes,"max_agents":options.max_agents,
        "cpu_pinning":options.pin_cpus,"available_cpus":available_cpus()?,"profiles":options.profiles,
        "kernel":output(&["uname","-r"]),"revision":output(&["git","rev-parse","HEAD"]),
        "build":read(root.join("_build/bench/native/build.json")),"limits":read("/proc/self/limits"),
        "cpuinfo":read("/proc/cpuinfo"),"stub_source":"master:3a484b6:priv/benchmark_stub",
        "http_pool_size":65536,"model_delay_ms":86400000,"database":"shared"}),
    )?;
    println!("Artifacts: {}", directory.display());
    for profile in &options.profiles {
        if STOP.load(Ordering::Relaxed) {
            break;
        }
        match measure(&root, &delegated, &directory, profile, &options) {
            Ok(_) => report(&directory)?,
            Err(error) => {
                write_json(
                    directory.join("error.json"),
                    &json!({"profile":profile,"error":error.to_string()}),
                )?;
                return Err(error);
            }
        }
    }
    println!("Report: {}", directory.join("report.md").display());
    Ok(())
}
fn main() {
    if let Err(error) = main_result() {
        eprintln!("Benchmark failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_is_linear_without_a_ceiling_or_cpu_pinning() {
        let options = Options::parse(&["run".into()]).unwrap();
        assert!(!options.pin_cpus);
        assert_eq!(options.max_agents, None);
        assert_eq!(options.profiles, vec!["A", "B"]);
        assert_eq!(options.interval_ms, 100);
        assert!(!required(false).contains(&"cpuset"));
        assert!(required(true).contains(&"cpuset"));
    }
    #[test]
    fn limits_are_not_reported_as_hardware_failure() {
        assert_eq!(reason(0, false, &None, true, None), "exploration_limit");
        assert_eq!(reason(1, false, &None, false, None), "oom");
        assert_eq!(
            reason(0, false, &Some("sqlite".into()), false, Some(2)),
            "agent_error: sqlite"
        );
    }
    #[test]
    fn profiles_preserve_requested_budgets() {
        assert_eq!(dimensions("A"), (1, 536870912));
        assert_eq!(dimensions("B"), (2, 1073741824));
        assert_eq!(cpus("0-2,5").unwrap(), vec![0, 1, 2, 5]);
    }
    #[test]
    fn event_parser_keeps_partial_lines() {
        let path = env::temp_dir().join(format!("benchmark-events-{}", std::process::id()));
        fs::write(
            &path,
            "{\"type\":\"resident\",\"agents\":12}\n{\"type\":\"la",
        )
        .unwrap();
        let mut progress = Progress::default();
        let mut file = File::open(&path).unwrap();
        progress.update(&mut file).unwrap();
        assert_eq!(progress.resident, 12);
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"unch\",\"agent\":13}\n")
            .unwrap();
        progress.update(&mut file).unwrap();
        assert_eq!(progress.launched, 13);
        fs::remove_file(path).unwrap();
    }
}
