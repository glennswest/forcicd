//! cigate — forcicd deploy gate.
//!
//! A busybox-style multicall binary that exposes ONLY a fixed set
//! of CI/deploy verbs. It is installed as the forced command of a
//! dedicated, `from=`-restricted deploy key on an app's own LXC/VM
//! (never the Proxmox host). The key can do nothing but invoke
//! these verbs, within the policy at /etc/forcicd-deploy/gate.conf.
//!
//! Bulletproof by construction:
//!   * zero external dependencies (std only)
//!   * never spawns a shell — every action is an explicit argv to
//!     the container engine (no string interpolation into sh)
//!   * strict allowlist validation of image refs (charset +
//!     registry must be in the policy)
//!   * `panic = "abort"`, no unsafe
//!
//! Invocation paths:
//!   1. SSH forced command  → $SSH_ORIGINAL_COMMAND holds the verb
//!   2. argv                → `cigate deploy <ref>`
//!   3. no args             → a limited REPL (only these verbs)
//!
//! Verbs: deploy <ref> | rollback | restart | status | logs [N] |
//!        ps | help

use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::process::{Command, Stdio};

const CONF: &str = "/etc/forcicd-deploy/gate.conf";

struct Policy {
    engine: String,
    allowed_registries: Vec<String>,
    container_name: String,
    run_args: Vec<String>,
    log_path: String,
    state_dir: String,
}

impl Policy {
    fn load() -> Policy {
        // Defaults; overridden by simple `key = value` lines.
        let mut p = Policy {
            engine: "podman".into(),
            allowed_registries: vec![
                "forcicd.g8.lo:5000".into(),
                "fastregistry.g10.lo".into(),
            ],
            container_name: "app".into(),
            run_args: Vec::new(),
            log_path: "/var/log/forcicd-deploy-gate.log".into(),
            state_dir: "/var/lib/forcicd-deploy".into(),
        };
        if let Ok(txt) = fs::read_to_string(CONF) {
            for line in txt.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let Some((k, v)) = line.split_once('=') else { continue };
                let k = k.trim();
                let v = v.trim().trim_matches('"');
                match k {
                    "engine" => p.engine = v.into(),
                    "container_name" => p.container_name = v.into(),
                    "log_path" => p.log_path = v.into(),
                    "state_dir" => p.state_dir = v.into(),
                    "allowed_registries" => {
                        p.allowed_registries =
                            v.split_whitespace().map(str::to_string).collect()
                    }
                    "run_args" => {
                        p.run_args =
                            v.split_whitespace().map(str::to_string).collect()
                    }
                    _ => {}
                }
            }
        }
        p
    }

    fn log(&self, msg: &str) {
        if let Ok(mut f) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)
        {
            let _ = writeln!(f, "{} {}", now(), msg);
        }
    }
}

fn now() -> String {
    // Seconds since epoch — no chrono dependency.
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => format!("t={}", d.as_secs()),
        Err(_) => "t=?".into(),
    }
}

/// An image ref is acceptable iff every char is in a tight allow
/// set AND its registry component is in the policy. The charset
/// alone rules out shell metacharacters, spaces, quotes, `$`, etc.
fn valid_ref(p: &Policy, r: &str) -> bool {
    if r.is_empty() || r.len() > 512 {
        return false;
    }
    if !r.chars().all(|c| {
        c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/' | ':' | '@')
    }) {
        return false;
    }
    if r.contains("..") {
        return false;
    }
    let registry = r.split('/').next().unwrap_or("");
    p.allowed_registries.iter().any(|a| a == registry)
}

fn run(engine: &str, args: &[&str]) -> i32 {
    match Command::new(engine).args(args).status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => {
            eprintln!("cigate: failed to exec {engine}: {e}");
            127
        }
    }
}

fn deploy(p: &Policy, reference: &str) -> i32 {
    if !valid_ref(p, reference) {
        eprintln!("cigate: image ref rejected (charset or registry not allowed)");
        p.log(&format!("DENIED deploy {reference}"));
        return 2;
    }
    p.log(&format!("deploy {reference} -> {}", p.container_name));

    // Remember the currently-running image for rollback.
    if let Ok(out) = Command::new(&p.engine)
        .args(["inspect", "-f", "{{.ImageName}}", &p.container_name])
        .output()
    {
        if out.status.success() {
            let prev = String::from_utf8_lossy(&out.stdout);
            let prev = prev.trim();
            if !prev.is_empty() {
                let _ = fs::create_dir_all(&p.state_dir);
                let _ = fs::write(format!("{}/previous-image", p.state_dir), prev);
            }
        }
    }

    if run(&p.engine, &["pull", "--tls-verify=false", reference]) != 0 {
        return 3;
    }
    let _ = run(&p.engine, &["rm", "-f", &p.container_name]);
    let mut args: Vec<&str> =
        vec!["run", "-d", "--name", &p.container_name, "--restart=unless-stopped"];
    for a in &p.run_args {
        args.push(a);
    }
    args.push(reference);
    let rc = run(&p.engine, &args);
    if rc == 0 {
        let _ = fs::create_dir_all(&p.state_dir);
        let _ = fs::write(format!("{}/current-image", p.state_dir), reference);
        println!("deployed {reference} as {}", p.container_name);
    }
    rc
}

fn rollback(p: &Policy) -> i32 {
    let prev = fs::read_to_string(format!("{}/previous-image", p.state_dir))
        .unwrap_or_default();
    let prev = prev.trim();
    if prev.is_empty() {
        eprintln!("cigate: no previous image recorded");
        return 1;
    }
    eprintln!("cigate: rolling back to {prev}");
    deploy(p, prev)
}

fn restart(p: &Policy) -> i32 {
    p.log("restart");
    run(&p.engine, &["restart", &p.container_name])
}

fn status(p: &Policy) -> i32 {
    run(
        &p.engine,
        &[
            "ps",
            "-a",
            "--filter",
            &format!("name=^{}$", p.container_name),
            "--format",
            "{{.Names}} {{.Status}} {{.Image}}",
        ],
    )
}

fn logs(p: &Policy, n: &str) -> i32 {
    let n = if n.chars().all(|c| c.is_ascii_digit()) && !n.is_empty() {
        n
    } else {
        "100"
    };
    run(&p.engine, &["logs", "--tail", n, &p.container_name])
}

fn ps(p: &Policy) -> i32 {
    run(&p.engine, &["ps", "--format", "{{.Names}} {{.Status}} {{.Image}}"])
}

fn help() -> i32 {
    println!(
        "cigate — forcicd deploy gate (only these verbs):\n\
         \n\
         \x20 deploy <image-ref>   pull + (re)start the app container\n\
         \x20 rollback             revert to the previously deployed image\n\
         \x20 restart              restart the app container\n\
         \x20 status               show the app container's state\n\
         \x20 logs [N]             tail N (default 100) lines of app logs\n\
         \x20 ps                   list running containers\n\
         \x20 help                 this text\n"
    );
    0
}

fn dispatch(p: &Policy, tokens: &[String]) -> i32 {
    let Some(verb) = tokens.first() else {
        return help();
    };
    match verb.as_str() {
        "deploy" => match tokens.get(1) {
            Some(r) => deploy(p, r),
            None => {
                eprintln!("cigate: deploy needs an image ref");
                2
            }
        },
        "rollback" => rollback(p),
        "restart" => restart(p),
        "status" => status(p),
        "logs" => logs(p, tokens.get(1).map(String::as_str).unwrap_or("100")),
        "ps" => ps(p),
        "help" | "-h" | "--help" => help(),
        other => {
            eprintln!("cigate: unknown verb '{other}' (try: help)");
            p.log(&format!("DENIED verb {other}"));
            2
        }
    }
}

/// Limited REPL — only the built-in verbs, no shell escape.
fn repl(p: &Policy) -> i32 {
    let stdin = io::stdin();
    let mut last = 0;
    loop {
        print!("cigate> ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        match stdin.lock().read_line(&mut line) {
            Ok(0) => break, // EOF
            Ok(_) => {}
            Err(_) => break,
        }
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line == "exit" || line == "quit" {
            break;
        }
        let tokens: Vec<String> =
            line.split_whitespace().map(str::to_string).collect();
        last = dispatch(p, &tokens);
    }
    last
}

fn main() {
    // Keep child output attached to our stdio.
    let _ = Stdio::inherit();
    let p = Policy::load();

    // 1) SSH forced command.
    if let Ok(cmd) = env::var("SSH_ORIGINAL_COMMAND") {
        let tokens: Vec<String> =
            cmd.split_whitespace().map(str::to_string).collect();
        std::process::exit(dispatch(&p, &tokens));
    }
    // 2) Direct argv.
    let args: Vec<String> = env::args().skip(1).collect();
    if !args.is_empty() {
        std::process::exit(dispatch(&p, &args));
    }
    // 3) Interactive limited shell.
    std::process::exit(repl(&p));
}
