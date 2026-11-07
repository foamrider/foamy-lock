//! The style sweep: every style of every element in each column of its row,
//! through sizes, clock formats, typing and primary/secondary states, then
//! a cycle through every style on one view back to the default look.

use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::{app, host};

const SHELL: &str = include_str!("styles.qml");

pub fn run(args: &[String]) -> Result<(), String> {
    let mut choice = "4.5".to_string();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--host" => choice = rest.next().cloned().ok_or(format!("{arg} needs a value"))?,
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let hosts = host::selected(&choice)?;
    let mut failed = Vec::new();
    for (name, shell) in &hosts {
        if hosts.len() > 1 {
            println!("== host {name}: {}", shell.display());
        }
        if let Err(message) = run_host(name, shell) {
            eprintln!("{message}");
            failed.push(name.clone());
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("styles failed: {}", failed.join(", ")))
    }
}

/// The sweep on one host shell. Captures are taken only when
/// `FOAMY_RENDER_OUT` asks for them (they slow the sweep down).
pub fn run_host(name: &str, shell: &Path) -> Result<(), String> {
    let out = app::render_out("styles");
    let base = app::temp_dir("foamy-lock-styles")?;
    let dir = base.join("app");
    app::prepare(&dir, shell)?;
    fs::write(
        dir.join("shell.qml"),
        SHELL.replace("__CAPTURE__", if out.is_some() { "true" } else { "false" }),
    )
    .map_err(app::io("shell.qml"))?;
    app::register_types(&dir)?;
    let (success, output) =
        app::run_quickshell(&base, &dir, shell, "en", Duration::from_secs(600))?;
    for line in output
        .lines()
        .filter(|line| line.contains("STYLES_") || line.contains("cycle") || line.contains("ERROR"))
    {
        println!("{line}");
    }
    let warnings = qml_warnings(&output);
    if !success || !output.contains("STYLES_PASS") || !warnings.is_empty() {
        return Err(format!(
            "styles failed ({name} {}){}; log: {}",
            shell.display(),
            warnings
                .iter()
                .map(|line| format!("\n  {line}"))
                .collect::<String>(),
            base.display()
        ));
    }
    if let Some(out) = out {
        app::copy_captures(&dir, &out)?;
    }
    Ok(())
}

/// QML warnings from the plugin's own files (binding loops, type errors),
/// which the sweep treats as failures.
fn qml_warnings(log: &str) -> Vec<&str> {
    log.lines()
        .filter(|line| {
            (line.contains("WARN") || line.contains("ERROR"))
                && [
                    "elements/",
                    "LockView.qml",
                    "Layout.js",
                    "Binding loop",
                    "TypeError",
                    "ReferenceError",
                ]
                .iter()
                .any(|needle| line.contains(needle))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::qml_warnings;

    #[test]
    fn plugin_warnings_fail_the_sweep() {
        let log = "  WARN: $HYPRLAND_INSTANCE_SIGNATURE is unset.\n  WARN scene: @elements/ClockElement.qml[12:3]: Binding loop detected\n DEBUG qml: styles ok";
        assert_eq!(
            qml_warnings(log),
            vec!["  WARN scene: @elements/ClockElement.qml[12:3]: Binding loop detected"]
        );
        assert!(qml_warnings(" DEBUG qml: STYLES_PASS").is_empty());
    }
}
