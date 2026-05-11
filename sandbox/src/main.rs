mod fixups;
mod term;

use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use dirs::home_dir;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[derive(Parser)]
#[command(name = "sandbox")]
#[command(about = "A Container-Based Dev Sandbox CLI", long_about = None)]
struct Cli {
    /// Print every podman/filesystem command before running it
    #[arg(short, long)]
    verbose: bool,

    /// Show what would happen without doing anything
    #[arg(long)]
    dry_run: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Build a sandbox image (e.g. debian-trixie)
    Build {
        /// The variant to build (e.g. debian-trixie, arch)
        variant: String,
    },
    /// Create and start a sandbox container
    Create {
        /// The image to use
        image: String,
        /// The name of the sandbox
        name: String,

        /// Omit X11/Wayland sockets
        #[arg(long)]
        no_gui: bool,

        /// Omit /dev/dri passthrough
        #[arg(long)]
        no_gpu: bool,

        /// Use bridged networking instead of host
        #[arg(long)]
        no_network_host: bool,

        /// Override the default home directory path
        #[arg(long)]
        home: Option<PathBuf>,

        /// Bind-mount an extra working directory at /work
        #[arg(long)]
        work: Option<PathBuf>,

        /// Override fix-up script selection (bypasses mapping.conf)
        #[arg(long)]
        fixup: Option<String>,
    },
    /// Open an interactive login shell
    Shell {
        /// The name of the sandbox
        name: String,
        /// Open the shell as root instead of the sandbox user
        #[arg(long)]
        root: bool,
    },
    /// Run a command in the sandbox
    Exec {
        /// The name of the sandbox
        name: String,
        /// Run the command as root instead of the sandbox user
        #[arg(long)]
        root: bool,
        /// The command to run
        #[arg(required = true)]
        cmd: Vec<String>,
    },
    /// Stop a sandbox without removing it
    Stop {
        /// The name of the sandbox
        name: String,
    },
    /// Start a stopped sandbox
    Start {
        /// The name of the sandbox
        name: String,
    },
    /// Remove a sandbox container
    Rm {
        /// The name of the sandbox
        name: String,
        /// Also drop the home directory
        #[arg(long)]
        purge: bool,
    },
    /// List all sandboxes
    List,
    /// Snapshot the writable layer
    Snapshot {
        /// The name of the sandbox
        name: String,
        /// The tag to apply
        tag: String,
    },
    /// Recreate sandbox from a snapshot
    Restore {
        /// The name of the sandbox
        name: String,
        /// The tag to restore from
        tag: String,
    },
}

struct CreateParams {
    image: String,
    name: String,
    no_gui: bool,
    no_gpu: bool,
    no_network_host: bool,
    home: Option<PathBuf>,
    work: Option<PathBuf>,
    fixup: Option<String>,
}

struct SandboxManager {
    home_root: PathBuf,
    verbose: bool,
    dry_run: bool,
}

impl SandboxManager {
    fn new(verbose: bool, dry_run: bool) -> Result<Self> {
        let mut home_root = home_dir().ok_or_else(|| anyhow!("Could not find home directory"))?;
        home_root.push("sandboxes");
        Ok(Self {
            home_root,
            verbose,
            dry_run,
        })
    }

    fn log_command(&self, prefix: &str, args: &[String]) {
        if self.verbose || self.dry_run {
            let joined = args.join(" ");
            println!("{}: {}", prefix, joined);
        }
    }

    fn ensure_dir(&self, path: &PathBuf) -> Result<()> {
        if self.verbose || self.dry_run {
            println!("mkdir -p {}", path.display());
        }
        if self.dry_run {
            return Ok(());
        }
        std::fs::create_dir_all(path).with_context(|| format!("Failed to create {}", path.display()))
    }

    fn remove_dir(&self, path: &PathBuf) -> Result<()> {
        if self.verbose || self.dry_run {
            println!("rm -rf {}", path.display());
        }
        if self.dry_run {
            return Ok(());
        }
        std::fs::remove_dir_all(path).with_context(|| format!("Failed to remove {}", path.display()))
    }

    fn run_podman(&self, args: &[&str]) -> Result<()> {
        let args_owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        self.log_command("podman", &args_owned);
        if self.dry_run {
            return Ok(());
        }

        let status = Command::new("podman")
            .args(args)
            .status()
            .with_context(|| format!("Failed to execute podman {:?}", args))?;

        if status.success() {
            Ok(())
        } else {
            Err(anyhow!("podman command failed with status: {}", status))
        }
    }

    fn run_podman_vec(&self, args: Vec<String>) -> Result<()> {
        self.log_command("podman", &args);
        if self.dry_run {
            return Ok(());
        }

        let status = Command::new("podman")
            .args(&args)
            .status()
            .with_context(|| format!("Failed to execute podman {:?}", args))?;

        if status.success() {
            Ok(())
        } else {
            Err(anyhow!("podman command failed with status: {}", status))
        }
    }

    /// Run a podman command capturing stdout. Returns trimmed stdout on success.
    /// In dry-run mode the command is logged and an empty string returned.
    fn run_podman_capture(&self, args: Vec<String>) -> Result<String> {
        self.log_command("podman", &args);
        if self.dry_run {
            return Ok(String::new());
        }
        let output = Command::new("podman")
            .args(&args)
            .output()
            .with_context(|| format!("Failed to execute podman {:?}", args))?;
        if !output.status.success() {
            return Err(anyhow!(
                "podman command failed with status {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    /// Run a podman command piping `stdin_body` to the child's stdin.
    fn run_podman_stdin(&self, args: Vec<String>, stdin_body: &str) -> Result<()> {
        self.log_command("podman", &args);
        if self.dry_run {
            println!(
                "   (piped via stdin: {} bytes, {} lines)",
                stdin_body.len(),
                stdin_body.lines().count()
            );
            return Ok(());
        }
        let mut child = Command::new("podman")
            .args(&args)
            .stdin(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to execute podman {:?}", args))?;
        {
            let stdin = child
                .stdin
                .as_mut()
                .ok_or_else(|| anyhow!("Failed to open podman stdin"))?;
            stdin
                .write_all(stdin_body.as_bytes())
                .context("Failed to write to podman stdin")?;
        }
        let status = child
            .wait()
            .with_context(|| format!("Failed to wait on podman {:?}", args))?;
        if status.success() {
            Ok(())
        } else {
            Err(anyhow!("podman command failed with status: {}", status))
        }
    }

    /// Detect the container's distro by reading PRETTY_NAME from /etc/os-release.
    /// Returns "Unknown" if detection fails so the trailing `.*` mapping line still matches.
    fn detect_pretty_name(&self, container: &str) -> Result<String> {
        let args: Vec<String> = vec![
            "exec".into(),
            "--user".into(),
            "root".into(),
            container.to_string(),
            "sh".into(),
            "-c".into(),
            ". /etc/os-release 2>/dev/null && printf %s \"$PRETTY_NAME\"".into(),
        ];
        let out = self.run_podman_capture(args).unwrap_or_default();
        if out.is_empty() {
            Ok("Unknown".to_string())
        } else {
            Ok(out)
        }
    }

    fn get_user_info(&self) -> Result<(String, String, String)> {
        let user = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
        let uid = String::from_utf8(std::process::Command::new("id").arg("-u").output()?.stdout)?
            .trim()
            .to_string();
        let gid = String::from_utf8(std::process::Command::new("id").arg("-g").output()?.stdout)?
            .trim()
            .to_string();
        Ok((user, uid, gid))
    }

    fn create_container(&self, params: CreateParams) -> Result<()> {
        let CreateParams {
            image,
            name,
            no_gui,
            no_gpu,
            no_network_host,
            home,
            work,
            fixup,
        } = params;

        let (user, uid, gid) = self.get_user_info()?;

        let sandbox_home = home.unwrap_or_else(|| self.home_root.join(&name));
        if !sandbox_home.exists() {
            self.ensure_dir(&sandbox_home)?;
        }

        let mut args: Vec<String> = vec![
            "run".into(),
            "-d".into(),
            "--name".into(),
            name.clone(),
            "--hostname".into(),
            name.clone(),
            "--userns=keep-id".into(),
        ];

        if !no_network_host {
            args.push("--network=host".into());
        }

        args.push("-v".into());
        args.push(format!("{}:/home", sandbox_home.display()));

        // Pass host locale env vars through to the container so the guest
        // matches the user's host locale (UTF-8 etc). Falls back to C.UTF-8
        // when LANG is unset on the host.
        let host_lang = std::env::var("LANG").unwrap_or_else(|_| "C.UTF-8".to_string());
        args.push("-e".into());
        args.push(format!("LANG={host_lang}"));
        if let Ok(lc_all) = std::env::var("LC_ALL") {
            args.push("-e".into());
            args.push(format!("LC_ALL={lc_all}"));
        }
        if let Ok(language) = std::env::var("LANGUAGE") {
            args.push("-e".into());
            args.push(format!("LANGUAGE={language}"));
        }

        if let Some(work_path) = work {
            args.push("-v".into());
            args.push(format!("{}:/work", work_path.display()));
        }

        if !no_gui {
            let display = std::env::var("DISPLAY").unwrap_or_default();
            let wayland_display =
                std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());
            let xdg_runtime =
                std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
            let xauthority =
                std::env::var("XAUTHORITY").unwrap_or_else(|_| "/tmp/.Xauthority".to_string());

            if !display.is_empty() {
                args.push("-e".into());
                args.push(format!("DISPLAY={display}"));
            }
            args.push("-e".into());
            args.push(format!("WAYLAND_DISPLAY={wayland_display}"));
            args.push("-e".into());
            args.push("XDG_RUNTIME_DIR=/tmp/runtime-user".into());
            args.push("-e".into());
            args.push("XAUTHORITY=/tmp/.Xauthority".into());
            args.push("-e".into());
            args.push("QT_QPA_PLATFORM=wayland;xcb".into());
            args.push("-e".into());
            args.push("GDK_BACKEND=wayland,x11".into());

            args.push("-v".into());
            args.push("/tmp/.X11-unix:/tmp/.X11-unix".into());
            args.push("-v".into());
            args.push(format!(
                "{xdg_runtime}/wayland-0:/tmp/runtime-user/wayland-0"
            ));
            args.push("-v".into());
            args.push(format!("{xauthority}:/tmp/.Xauthority:ro"));
        }

        if !no_gpu {
            args.push("--device=/dev/dri".into());
        }

        args.push(image);
        args.push("sleep".into());
        args.push("infinity".into());

        println!("Creating container {}...", name);
        self.run_podman_vec(args)?;

        let script_name: String = if let Some(forced) = fixup {
            forced
        } else {
            let pretty = self.detect_pretty_name(&name)?;
            term::info(&format!("Detected distro: {}", pretty));
            let mapping = fixups::load_mapping()?;
            match fixups::select_script(&pretty, &mapping) {
                Some(s) => s.to_string(),
                None => {
                    return Err(anyhow!(
                        "No fix-up script matched PRETTY_NAME={:?}. Add a regex line to ~/.config/sandbox/fixups/mapping.conf.",
                        pretty
                    ));
                }
            }
        };
        term::info(&format!("Selected fix-up script: {}", script_name));
        let script_path = fixups::ensure_local(&script_name)?;
        let body = std::fs::read_to_string(&script_path)
            .with_context(|| format!("Failed to read {}", script_path.display()))?;

        println!();
        term::rule(&format!("inside guest: running {}", script_name));
        self.run_podman_stdin(
            vec![
                "exec".into(),
                "-i".into(),
                "--user".into(),
                "root".into(),
                "-e".into(),
                format!("SANDBOX_USER={user}"),
                "-e".into(),
                format!("SANDBOX_UID={uid}"),
                "-e".into(),
                format!("SANDBOX_GID={gid}"),
                "-e".into(),
                format!("SANDBOX_NAME={name}"),
                name.clone(),
                "bash".into(),
                "-s".into(),
            ],
            &body,
        )?;
        term::rule("back on host");
        println!();

        term::success(&format!("\u{2714} Sandbox '{}' is ready.", name));
        println!();
        println!("  Open a shell:     sandbox shell {name}");
        println!("  Open as root:     sandbox shell --root {name}");
        println!("  Run a command:    sandbox exec {name} <cmd>");
        println!("  Stop / remove:    sandbox stop {name}  |  sandbox rm {name}");
        println!();
        Ok(())
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let manager = SandboxManager::new(cli.verbose, cli.dry_run)?;

    match cli.command {
        Commands::Build { variant } => {
            let dockerfile = format!("Containerfiles/{}.Dockerfile", variant);
            let (user, uid, gid) = manager.get_user_info()?;

            println!("Building variant: {}...", variant);
            manager.run_podman(&[
                "build",
                "-f",
                &dockerfile,
                "--build-arg",
                &format!("USERNAME={}", user),
                "--build-arg",
                &format!("USER_UID={}", uid),
                "--build-arg",
                &format!("USER_GID={}", gid),
                "-t",
                &format!("sandbox:{}", variant),
                ".",
            ])?;
            println!("Successfully built sandbox:{}", variant);
        }
        Commands::Create {
            image,
            name,
            no_gui,
            no_gpu,
            no_network_host,
            home,
            work,
            fixup,
        } => {
            manager.create_container(CreateParams {
                image,
                name,
                no_gui,
                no_gpu,
                no_network_host,
                home,
                work,
                fixup,
            })?;
        }
        Commands::Shell { name, root } => {
            let target_user = if root {
                "root".to_string()
            } else {
                manager.get_user_info()?.0
            };
            let workdir = if root {
                "/root".to_string()
            } else {
                format!("/home/{}", target_user)
            };
            manager.run_podman_vec(vec![
                "exec".into(),
                "-it".into(),
                "--user".into(),
                target_user,
                "--workdir".into(),
                workdir,
                name.clone(),
                "bash".into(),
                "-l".into(),
            ])?;
        }
        Commands::Exec { name, root, cmd } => {
            let target_user = if root {
                "root".to_string()
            } else {
                manager.get_user_info()?.0
            };
            let full_cmd = cmd.join(" ");
            manager.run_podman_vec(vec![
                "exec".into(), "-it".into(), "--user".into(), target_user, name.clone(), "bash".into(), "-lc".into(), full_cmd
            ])?;
        }
        Commands::Stop { name } => {
            manager.run_podman(&["stop", &name])?;
            println!("Stopped sandbox: {}", name);
        }
        Commands::Start { name } => {
            manager.run_podman(&["start", &name])?;
            println!("Started sandbox: {}", name);
        }
        Commands::Rm { name, purge } => {
            manager.run_podman(&["rm", "-f", &name])?;
            if purge {
                let sandbox_home = manager.home_root.join(&name);
                if sandbox_home.exists() {
                    manager.remove_dir(&sandbox_home)?;
                    println!("Purged home directory for: {}", name);
                } else if manager.dry_run {
                    println!("[dry-run] Would remove home directory: {}", sandbox_home.display());
                }
            }
            println!("Removed sandbox: {}", name);
        }
        Commands::List => {
            manager.run_podman(&[
                "ps",
                "-a",
                "--format",
                "table {{.Names}}\t{{.Status}}\t{{.Image}}",
            ])?;
        }
        Commands::Snapshot { name, tag } => {
            manager.run_podman(&["commit", &name, &format!("{}:{}", name, tag)])?;
            println!("Snapshot saved: {}:{}", name, tag);
        }
        Commands::Restore { name, tag } => {
            let snapshot_image = format!("{}:{}", name, tag);
            println!("Restoring {} from snapshot {}...", name, tag);

            if let Err(err) = manager.run_podman(&["rm", "-f", name.as_str()]) {
                eprintln!(
                    "Warning: could not remove existing container {}: {}",
                    name, err
                );
            }

            manager.create_container(CreateParams {
                image: snapshot_image,
                name,
                no_gui: false,
                no_gpu: false,
                no_network_host: false,
                home: None,
                work: None,
                fixup: None,
            })?;
        }
    }

    Ok(())
}
