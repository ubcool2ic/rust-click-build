//! Theme selection and theme-derived colours and styles.

use rtk::style::blend;
use rtk::theme::contrast_ratio;
use rtk::{Color, ColorRole, StyleSpec, Theme, Tk};

use crate::protocol::Role;

/// Named style for the large application title.
pub const STYLE_TITLE: &str = "RcbTitle";
/// Named style for inline validation errors.
pub const STYLE_ERROR: &str = "RcbError";
/// Named style for layout-only frames that must not paint a background.
pub const STYLE_PLAIN: &str = "RcbPlain";

/// Colour-free typography rules; colours come from `style_configure`.
const APP_CSS: &str = "
RcbTitle { font-size: 26; font-weight: bold; }
RcbError { font-size: 13; }
";

/// Best-effort spacing tweak, loaded separately so that a parser that does
/// not know the property cannot affect the rules above.
const APP_CSS_OPTIONAL: &str = "
RcbTitle { padding: 6; }
";

/// The user's theme selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThemeChoice {
    /// Follow the operating system (ModernLight / ModernDark).
    System,
    /// ModernLight.
    Light,
    /// ModernDark.
    Dark,
    /// HighContrast.
    HighContrast,
}

impl ThemeChoice {
    /// All choices in selector order.
    pub const ALL: [ThemeChoice; 4] = [
        ThemeChoice::System,
        ThemeChoice::Light,
        ThemeChoice::Dark,
        ThemeChoice::HighContrast,
    ];

    /// Parses a theme name, ignoring case, spaces, `-` and `_`.
    pub fn parse(raw: &str) -> Option<Self> {
        let key: String = raw
            .chars()
            .filter(|c| !matches!(c, ' ' | '-' | '_'))
            .flat_map(char::to_lowercase)
            .collect();
        match key.as_str() {
            "system" => Some(ThemeChoice::System),
            "light" => Some(ThemeChoice::Light),
            "dark" => Some(ThemeChoice::Dark),
            "highcontrast" => Some(ThemeChoice::HighContrast),
            _ => None,
        }
    }

    /// Label shown in the theme selector.
    pub fn label(self) -> &'static str {
        match self {
            ThemeChoice::System => "System",
            ThemeChoice::Light => "Light",
            ThemeChoice::Dark => "Dark",
            ThemeChoice::HighContrast => "High contrast",
        }
    }

    /// Index in the theme selector.
    pub fn index(self) -> i64 {
        match self {
            ThemeChoice::System => 0,
            ThemeChoice::Light => 1,
            ThemeChoice::Dark => 2,
            ThemeChoice::HighContrast => 3,
        }
    }

    /// Choice for a selector index (out-of-range falls back to System).
    pub fn from_index(index: i64) -> Self {
        match index {
            1 => ThemeChoice::Light,
            2 => ThemeChoice::Dark,
            3 => ThemeChoice::HighContrast,
            _ => ThemeChoice::System,
        }
    }
}

/// Applies `choice` to the toolkit and (re)installs the app styles.
pub fn apply(tk: &mut Tk, choice: ThemeChoice) {
    tk.unfollow_system_theme();
    match choice {
        ThemeChoice::System => {
            tk.set_theme(Theme::ModernLight);
            tk.follow_system_theme(Theme::ModernLight, Theme::ModernDark);
        }
        ThemeChoice::Light => tk.set_theme(Theme::ModernLight),
        ThemeChoice::Dark => tk.set_theme(Theme::ModernDark),
        ThemeChoice::HighContrast => tk.set_theme(Theme::HighContrast),
    }
    install_styles(tk);
}

/// Base colours read from the active theme.
struct Base {
    surface: Color,
    fg: Color,
    muted: Color,
    accent: Color,
}

/// Reads the base colours from the active theme (single place that touches
/// the token structs).
fn base_colors(tk: &Tk) -> Base {
    let palette = &tk.tokens().palette;
    Base {
        surface: palette.surface,
        fg: palette.fg,
        muted: palette.muted,
        accent: tk.semantic_tokens().color(ColorRole::Accent),
    }
}

/// Moves `color` towards `fg` until it reaches a 4.5:1 contrast on `bg`.
fn ensure_contrast(color: Color, bg: Color, fg: Color) -> Color {
    for step in 0..=10 {
        let candidate = blend(color, fg, step as f32 / 10.0);
        if contrast_ratio(candidate, bg) >= 4.5 {
            return candidate;
        }
    }
    fg
}

/// Registers the app's named styles from the active theme's colours.
pub fn install_styles(tk: &mut Tk) {
    let base = base_colors(tk);
    let clear = Color::rgba(0, 0, 0, 0);
    let danger = ensure_contrast(Color::rgb(214, 48, 49), base.surface, base.fg);
    tk.style_configure(
        STYLE_TITLE,
        StyleSpec {
            bg: Some(clear),
            fg: Some(base.fg),
            ..StyleSpec::new()
        },
    );
    tk.style_configure(
        STYLE_ERROR,
        StyleSpec {
            bg: Some(clear),
            fg: Some(danger),
            ..StyleSpec::new()
        },
    );
    tk.style_configure(
        STYLE_PLAIN,
        StyleSpec {
            bg: Some(clear),
            ..StyleSpec::new()
        },
    );
    let _ = tk.load_stylesheet(APP_CSS);
    let _ = tk.load_stylesheet(APP_CSS_OPTIONAL);
}

/// Colours of the custom-drawn progress bar.
#[derive(Clone, Copy)]
pub struct BarPalette {
    /// Card surface behind the bar.
    pub card: Color,
    /// Empty track.
    pub track: Color,
    /// Filled part (the theme accent).
    pub fill: Color,
}

/// Builds the progress bar palette for the active theme.
pub fn bar_palette(tk: &Tk) -> BarPalette {
    let base = base_colors(tk);
    BarPalette {
        card: base.surface,
        track: blend(base.surface, base.fg, 0.16),
        fill: base.accent,
    }
}

/// Colours used by the live log, derived from the active theme.
#[derive(Clone, Copy)]
pub struct LogPalette {
    /// Card surface behind the log panel.
    pub card: Color,
    /// Log panel background.
    pub bg: Color,
    /// Log panel outline.
    pub border: Color,
    /// Plain text.
    pub text: Color,
    /// De-emphasised text.
    pub muted: Color,
    /// Accent text.
    pub accent: Color,
    /// Informational text.
    pub info: Color,
    /// Success text.
    pub success: Color,
    /// Warning text.
    pub warning: Color,
    /// Error text.
    pub danger: Color,
    /// rtk version change text.
    pub rtkchange: Color,
}

impl LogPalette {
    /// Colour for a log role.
    pub fn color(&self, role: Role) -> Color {
        match role {
            Role::Text | Role::Heading => self.text,
            Role::Muted => self.muted,
            Role::Accent => self.accent,
            Role::Info => self.info,
            Role::Success => self.success,
            Role::Warning => self.warning,
            Role::Danger => self.danger,
            Role::RtkChange => self.rtkchange,
        }
    }
}

/// Builds the log palette for the active theme. Hues are nudged towards the
/// theme's foreground until they are readable, so HighContrast stays legible.
pub fn log_palette(tk: &Tk) -> LogPalette {
    let base = base_colors(tk);
    let bg = blend(base.surface, base.fg, 0.04);
    let fix = |c: Color| ensure_contrast(c, bg, base.fg);
    LogPalette {
        card: base.surface,
        bg,
        border: blend(base.surface, base.fg, 0.18),
        text: base.fg,
        muted: fix(base.muted),
        accent: fix(base.accent),
        info: fix(Color::rgb(41, 128, 185)),
        success: fix(Color::rgb(39, 174, 96)),
        warning: fix(Color::rgb(214, 137, 16)),
        danger: fix(Color::rgb(214, 48, 49)),
        rtkchange: fix(Color::rgb(190, 75, 219)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn choice_round_trips() {
        for choice in ThemeChoice::ALL {
            assert_eq!(ThemeChoice::from_index(choice.index()), choice);
            assert_eq!(ThemeChoice::parse(choice.label()), Some(choice));
        }
        assert_eq!(ThemeChoice::from_index(99), ThemeChoice::System);
        assert_eq!(ThemeChoice::parse("nope"), None);
    }

    #[test]
    fn log_colours_are_readable_in_every_theme() {
        for choice in [
            ThemeChoice::Light,
            ThemeChoice::Dark,
            ThemeChoice::HighContrast,
        ] {
            let mut tk = Tk::new();
            apply(&mut tk, choice);
            let pal = log_palette(&tk);
            for role in [Role::Danger, Role::Warning, Role::Success, Role::RtkChange] {
                assert!(contrast_ratio(pal.color(role), pal.bg) >= 3.0);
            }
        }
    }
}
