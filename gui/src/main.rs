//! Entry point of the `rcb-gui` binary.
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::error::Error;

use rcb_gui::args;

fn main() -> Result<(), Box<dyn Error>> {
    let parsed = match args::parse(std::env::args_os().skip(1)) {
        Ok(parsed) => parsed,
        Err(err) => {
            eprintln!("rcb-gui: {err}\n\n{}", args::USAGE);
            std::process::exit(2);
        }
    };
    if parsed.help {
        println!("{}", args::USAGE);
        return Ok(());
    }
    if let Some(dir) = &parsed.screenshot_dir {
        let shots = rcb_gui::render_screenshots(dir)?;
        for shot in shots {
            println!("{}", shot.path.display());
        }
        return Ok(());
    }
    rcb_gui::app::run(parsed)
}
