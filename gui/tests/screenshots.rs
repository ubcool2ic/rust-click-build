//! Smoke test: all nine headless screenshots render and are not blank.

use std::collections::HashSet;

#[test]
fn renders_all_nine_states() {
    let dir = std::env::temp_dir().join(format!("rcb-gui-shots-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let shots = rcb_gui::render_screenshots(&dir).expect("screenshots render");
    assert_eq!(shots.len(), 9);

    let mut names = HashSet::new();
    for shot in &shots {
        let name = shot
            .path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        assert!(shot.path.is_file(), "{name} missing");
        let size = std::fs::metadata(&shot.path).map(|m| m.len()).unwrap_or(0);
        assert!(size > 1000, "{name} is suspiciously small ({size} bytes)");
        assert!(shot.distinct_colors > 1, "{name} is a single colour");
        names.insert(name);
    }
    for theme in ["light", "dark", "highcontrast"] {
        for stage in ["idle", "building", "results"] {
            let want = format!("rcb-gui-{theme}-{stage}.png");
            assert!(names.contains(&want), "{want} not rendered");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}
