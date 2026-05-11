//! Small terminal helpers: ANSI colours and labelled rules, with automatic
//! fall-back to plain text when stdout is not a TTY.

use std::io::IsTerminal;

const RESET: &str = "\x1b[0m";
const BOLD: &str = "\x1b[1m";
const DIM: &str = "\x1b[2m";
const GREEN: &str = "\x1b[32m";
const CYAN: &str = "\x1b[36m";
const YELLOW: &str = "\x1b[33m";

const RULE_WIDTH: usize = 72;

fn use_colour() -> bool {
    std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none()
}

fn wrap(code: &str, text: &str) -> String {
    if use_colour() {
        format!("{code}{text}{RESET}")
    } else {
        text.to_string()
    }
}

/// Print a labelled horizontal rule. Used to fence off output that comes
/// from inside a container so it's distinguishable from host-side logs.
pub fn rule(label: &str) {
    let prefix = "── ";
    let body = format!("{prefix}{label} ");
    let pad = RULE_WIDTH.saturating_sub(body.chars().count());
    let line = format!("{body}{}", "─".repeat(pad));
    println!("{}", wrap(CYAN, &line));
}

/// Print a quiet, dim-styled informational line (e.g. "Detected ...").
pub fn info(msg: &str) {
    println!("{}", wrap(DIM, msg));
}

/// Print a green success banner.
pub fn success(msg: &str) {
    println!("{}", wrap(&format!("{BOLD}{GREEN}"), msg));
}

/// Print a yellow warning line.
#[allow(dead_code)]
pub fn warn(msg: &str) {
    println!("{}", wrap(YELLOW, msg));
}
