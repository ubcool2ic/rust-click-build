//! Widget construction and the diffing `render` refresh.

use std::cell::RefCell;

use rtk::{
    Button, Canvas, Combobox, Entry, Fill, Frame, GridOpts, Label, Opt, PackOpts, Radiobutton,
    RtkError, Side, Sticky, Switch, Table, Theme, Tk, Var, WidgetId,
};

use crate::protocol::Role;
use crate::state::{BuildState, Status};
use crate::theme::{self, ThemeChoice};

const SP_4: f32 = 4.0;
const SP_8: f32 = 8.0;
const SP_16: f32 = 16.0;
/// Half of the 12px gap between cards (pack padding applies on both sides).
const GAP_HALF: f32 = 6.0;
/// Horizontal padding between a card's edge and its content frame.
const CARD_PAD: f32 = 8.0;
/// Header side padding so its content lines up with the card edges.
const HEADER_PAD: f32 = 14.0;

/// Fallback width of the log canvas when live layout is unavailable.
pub const LOG_WIDTH: f32 = 640.0;
/// Fallback height of the log canvas when live layout is unavailable.
pub const LOG_HEIGHT: f32 = 140.0;
const LOG_MIN_HEIGHT: f32 = 60.0;
const LOG_PAD: f32 = 8.0;
const LOG_LINE: f32 = 17.0;
const LOG_FONT: f32 = 12.5;
/// Most recent log lines drawn on the canvas (older ones are not drawn).
const LOG_MAX_DRAWN: usize = 2000;
/// Font size assumed when fitting ordinary label text.
const LABEL_FONT: f32 = 13.0;
/// Height of the custom-drawn progress bar.
const BAR_HEIGHT: f32 = 10.0;

const HINT_TEXT: &str = "Every Cargo project inside this folder is built.";
const START_TEXT: &str = "Start build";
const BUSY_TEXT: &str = "Building...";

/// What `render` last pushed to the widgets, so unchanged widgets are skipped.
#[derive(Default)]
struct RenderCache {
    theme: Option<Theme>,
    status: Option<Status>,
    running: Option<bool>,
    can_open: Option<bool>,
    progress_pct: Option<i64>,
    progress_text: Option<String>,
    table_rev: Option<u64>,
    counts: Option<(u64, u64)>,
    summary_text: Option<String>,
    log_rev: Option<u64>,
    /// Scrollable content height set by the last log redraw.
    log_content_h: Option<f32>,
}

/// Handles of every widget and variable the controller needs.
pub struct Ui {
    /// Status chip in the header.
    pub status_chip: WidgetId,
    /// Theme selector index variable.
    pub theme_var: Var<i64>,
    /// Theme selector.
    pub theme_combo: WidgetId,
    /// Folder entry.
    pub folder_entry: WidgetId,
    /// Browse button.
    pub browse_btn: WidgetId,
    /// Hint line under the folder entry; shows validation errors inline.
    pub error_label: WidgetId,
    /// Profile variable: 0 = release, 1 = debug.
    pub profile_var: Var<i64>,
    /// Release radio button.
    pub radio_release: WidgetId,
    /// Debug radio button.
    pub radio_debug: WidgetId,
    /// "Run tests" variable.
    pub test_var: Var<bool>,
    /// "Run tests" switch.
    pub test_switch: WidgetId,
    /// "Check for rtk updates" variable.
    pub rtk_var: Var<bool>,
    /// "Check for rtk updates" switch.
    pub rtk_switch: WidgetId,
    /// Start button.
    pub start_btn: WidgetId,
    /// Cancel button.
    pub cancel_btn: WidgetId,
    /// Open output folder button.
    pub open_btn: WidgetId,
    /// Progress percentage variable (0..=100).
    pub progress_var: Var<i64>,
    /// Progress bar (a canvas painted with theme colours).
    pub progress_bar: WidgetId,
    /// Progress description label.
    pub progress_label: WidgetId,
    /// Results table.
    pub table: WidgetId,
    /// "N passed" chip.
    pub pass_chip: WidgetId,
    /// "N failed" chip.
    pub fail_chip: WidgetId,
    /// Summary line.
    pub summary_label: WidgetId,
    /// Log canvas.
    pub log_canvas: WidgetId,
    bar_size: (f32, f32),
    log_size: (f32, f32),
    /// Height of one log line (monospace).
    log_line: f32,
    /// Estimated advance of one monospace log character.
    log_char_w: f32,
    content_w: f32,
    cache: RefCell<RenderCache>,
}

/// Grids a widget in column 0 of its parent; the row is a literal.
macro_rules! grid_row {
    ($tk:expr, $id:expr, $row:literal, $sticky:expr, $pady:expr) => {
        $tk.grid(
            $id,
            GridOpts {
                row: $row,
                column: 0,
                sticky: $sticky,
                pady: $pady,
                ..GridOpts::default()
            },
        )
    };
}

fn pack(tk: &mut Tk, id: WidgetId, side: Side, fill: Fill, expand: bool, padx: f32, pady: f32) {
    tk.pack(
        id,
        PackOpts {
            side,
            fill,
            expand,
            padx,
            pady,
            ..PackOpts::default()
        },
    );
}

fn styled_label(
    tk: &mut Tk,
    parent: WidgetId,
    text: &str,
    style: &str,
) -> Result<WidgetId, RtkError> {
    let label = Label::new(tk, parent, text)?;
    tk.config(label, Opt::Style(style.into()));
    Ok(label)
}

fn styled_button(
    tk: &mut Tk,
    parent: WidgetId,
    text: &str,
    style: Option<&str>,
) -> Result<WidgetId, RtkError> {
    let button = Button::new(tk, parent, text)?;
    if let Some(style) = style {
        tk.config(button, Opt::Style(style.into()));
    }
    Ok(button)
}

/// A layout-only frame that does not paint its own background, so it can sit
/// inside a card without showing as a darker box.
fn plain_frame(tk: &mut Tk, parent: WidgetId) -> Result<WidgetId, RtkError> {
    let frame = Frame::new(tk, parent)?;
    tk.config(frame, Opt::Style(theme::STYLE_PLAIN.into()));
    Ok(frame)
}

/// Creates a card and the content frame inside it (a one-column grid).
///
/// With `fill_pady == None` the card is sized to its content and the content
/// is centred in it, so any spare room is split evenly above and below.
/// With `Some(pady)` the content frame fills the card (for stretching cards).
fn card(
    tk: &mut Tk,
    parent: WidgetId,
    fill_pady: Option<f32>,
) -> Result<(WidgetId, WidgetId), RtkError> {
    let frame = Frame::new(tk, parent)?;
    tk.config(frame, Opt::Style("Card".into()));
    let inner = plain_frame(tk, frame)?;
    match fill_pady {
        Some(pady) => pack(tk, inner, Side::Top, Fill::Both, true, CARD_PAD, pady),
        None => pack(tk, inner, Side::Top, Fill::X, true, CARD_PAD, 2.0),
    }
    tk.grid_columnconfigure(inner, 0, 1);
    Ok((frame, inner))
}

/// Live layout size of a widget (the only place that reads `Rect` fields).
fn size_of(tk: &mut Tk, id: WidgetId) -> Option<(f32, f32)> {
    let rect = tk.widget_rect(id)?;
    Some((rect.width, rect.height))
}

/// Builds the whole window content under the root frame.
pub fn build(tk: &mut Tk, theme_choice: ThemeChoice) -> Result<Ui, RtkError> {
    let root = tk.root();

    // ---- Header -----------------------------------------------------------
    let header = Frame::new(tk, root)?;
    pack(tk, header, Side::Top, Fill::X, false, HEADER_PAD, SP_4);

    let titles = Frame::new(tk, header)?;
    pack(tk, titles, Side::Left, Fill::None, false, 0.0, 0.0);
    let title = styled_label(tk, titles, "Rust Click Build", theme::STYLE_TITLE)?;
    grid_row!(tk, title, 0, Sticky::W, 0.0);
    let subtitle = styled_label(
        tk,
        titles,
        "Build every Cargo project in a folder",
        "Muted",
    )?;
    grid_row!(tk, subtitle, 1, Sticky::W, 0.0);

    let theme_var = tk.int_var(theme_choice.index());
    let labels: Vec<String> = ThemeChoice::ALL
        .iter()
        .map(|c| c.label().to_string())
        .collect();
    let theme_combo = Combobox::new(tk, header, labels, theme_var)?;
    pack(tk, theme_combo, Side::Right, Fill::None, false, 0.0, 0.0);
    let theme_label = styled_label(tk, header, "Theme", "Muted")?;
    pack(tk, theme_label, Side::Right, Fill::None, false, SP_8, 0.0);
    let status_chip = styled_label(tk, header, Status::Idle.label(), "Chip.Neutral")?;
    pack(tk, status_chip, Side::Right, Fill::None, false, SP_16, 0.0);

    // ---- Body -------------------------------------------------------------
    let body = Frame::new(tk, root)?;
    pack(tk, body, Side::Top, Fill::Both, true, GAP_HALF, GAP_HALF);
    let left = Frame::new(tk, body)?;
    pack(tk, left, Side::Left, Fill::Y, false, GAP_HALF, 0.0);
    let right = Frame::new(tk, body)?;
    pack(tk, right, Side::Left, Fill::Both, true, GAP_HALF, 0.0);

    // ---- Project card -----------------------------------------------------
    let (project, project_in) = card(tk, left, None)?;
    pack(tk, project, Side::Top, Fill::X, false, 0.0, GAP_HALF);
    let heading = styled_label(tk, project_in, "Project", "Subheading")?;
    grid_row!(tk, heading, 0, Sticky::W, SP_4);
    let folder_row = plain_frame(tk, project_in)?;
    grid_row!(tk, folder_row, 1, Sticky::EW, SP_4);
    let browse_btn = styled_button(tk, folder_row, "Browse...", None)?;
    pack(tk, browse_btn, Side::Right, Fill::None, false, 0.0, 0.0);
    let folder_entry = Entry::new(tk, folder_row)?;
    pack(tk, folder_entry, Side::Left, Fill::X, true, SP_8, 0.0);
    let error_label = styled_label(tk, project_in, HINT_TEXT, "Muted")?;
    grid_row!(tk, error_label, 2, Sticky::W, SP_4);

    // Vertical inset the toolkit gives a content-sized card; stretching cards
    // reuse it so every card title sits at the same distance from its edge.
    let fill_pady = match (size_of(tk, project), size_of(tk, project_in)) {
        (Some(outer), Some(inner)) => ((outer.1 - inner.1) / 2.0 - 2.0).clamp(4.0, 28.0),
        _ => 10.0,
    };

    // ---- Options card (stretches; actions are pinned to its bottom) -------
    let (options, options_in) = card(tk, left, Some(fill_pady))?;
    pack(tk, options, Side::Top, Fill::Both, true, 0.0, GAP_HALF);
    let heading = styled_label(tk, options_in, "Options", "Subheading")?;
    grid_row!(tk, heading, 0, Sticky::W, SP_4);
    let profile_row = plain_frame(tk, options_in)?;
    grid_row!(tk, profile_row, 1, Sticky::W, SP_4);
    let profile_var = tk.int_var(0);
    let radio_release = Radiobutton::new(tk, profile_row, "Release", profile_var, 0)?;
    pack(tk, radio_release, Side::Left, Fill::None, false, 0.0, 0.0);
    let radio_debug = Radiobutton::new(tk, profile_row, "Debug", profile_var, 1)?;
    pack(tk, radio_debug, Side::Left, Fill::None, false, SP_16, 0.0);
    let test_var = tk.bool_var(false);
    let test_switch = Switch::new(tk, options_in, "Run tests", test_var)?;
    grid_row!(tk, test_switch, 2, Sticky::W, SP_4);
    let rtk_var = tk.bool_var(true);
    let rtk_switch = Switch::new(
        tk,
        options_in,
        "Check for rtk updates before building",
        rtk_var,
    )?;
    grid_row!(tk, rtk_switch, 3, Sticky::W, SP_4);
    let spacer = plain_frame(tk, options_in)?;
    grid_row!(tk, spacer, 4, Sticky::W, 0.0);
    tk.grid_rowconfigure(options_in, 4, 1);
    let start_btn = styled_button(tk, options_in, START_TEXT, Some("Accent.TButton"))?;
    grid_row!(tk, start_btn, 5, Sticky::EW, SP_8);
    let cancel_btn = styled_button(tk, options_in, "Cancel", None)?;
    grid_row!(tk, cancel_btn, 6, Sticky::EW, SP_4);
    let open_btn = styled_button(tk, options_in, "Open output folder", Some("Ghost.TButton"))?;
    grid_row!(tk, open_btn, 7, Sticky::EW, SP_4);
    tk.tooltip(start_btn, "Ctrl+Enter or F5");
    tk.tooltip(cancel_btn, "Esc");

    // ---- Progress card ----------------------------------------------------
    let (progress, progress_in) = card(tk, right, None)?;
    pack(tk, progress, Side::Top, Fill::X, false, 0.0, GAP_HALF);
    let progress_head = plain_frame(tk, progress_in)?;
    grid_row!(tk, progress_head, 0, Sticky::EW, SP_4);
    let heading = styled_label(tk, progress_head, "Progress", "Subheading")?;
    pack(tk, heading, Side::Left, Fill::None, false, 0.0, 0.0);
    let progress_label = styled_label(tk, progress_head, "", "Muted")?;
    pack(tk, progress_label, Side::Right, Fill::None, false, 0.0, 0.0);

    // Usable width inside the right-hand cards, from the live layout.
    let content_w = size_of(tk, progress_in)
        .map(|(w, _)| (w - 4.0).floor())
        .filter(|w| *w >= 240.0)
        .unwrap_or(LOG_WIDTH);

    let progress_var = tk.int_var(0);
    let bar_size = (content_w, BAR_HEIGHT);
    let progress_bar = Canvas::new(tk, progress_in, bar_size.0, bar_size.1)?;
    grid_row!(tk, progress_bar, 1, Sticky::W, SP_8);
    tk.a11y_set_label(progress_bar, "Build progress 0%");

    // ---- Results card -----------------------------------------------------
    let (results, results_in) = card(tk, right, None)?;
    pack(tk, results, Side::Top, Fill::X, false, 0.0, GAP_HALF);
    let results_head = plain_frame(tk, results_in)?;
    grid_row!(tk, results_head, 0, Sticky::EW, SP_4);
    let heading = styled_label(tk, results_head, "Results", "Subheading")?;
    pack(tk, heading, Side::Left, Fill::None, false, 0.0, 0.0);
    let fail_chip = styled_label(tk, results_head, "0 failed", "Chip.Neutral")?;
    pack(tk, fail_chip, Side::Right, Fill::None, false, 0.0, 0.0);
    let pass_chip = styled_label(tk, results_head, "0 passed", "Chip.Success")?;
    pack(tk, pass_chip, Side::Right, Fill::None, false, SP_8, 0.0);
    let table = Table::new(
        tk,
        results_in,
        &["Project", "Build", "Tests", "rtk", "Time", "Artifacts"],
        5,
    )?;
    let table_w = content_w - 4.0;
    for (col, share) in [0.29_f32, 0.15, 0.12, 0.22, 0.10, 0.12]
        .into_iter()
        .enumerate()
    {
        tk.table_set_column_width(table, col, (table_w * share).floor());
    }
    grid_row!(tk, table, 1, Sticky::EW, SP_4);
    let summary_label = styled_label(tk, results_in, "", "Muted")?;
    grid_row!(tk, summary_label, 2, Sticky::W, SP_4);

    // ---- Log card (takes the remaining height) ----------------------------
    let (log, log_in) = card(tk, right, Some(fill_pady))?;
    pack(tk, log, Side::Top, Fill::Both, true, 0.0, GAP_HALF);
    let heading = styled_label(tk, log_in, "Build log", "Subheading")?;
    grid_row!(tk, heading, 0, Sticky::W, SP_4);
    // Height left under the heading: frame padding (2 + 2), the heading's
    // row padding (4 + 4), the canvas row padding (4 + 4) and 1px of slack.
    let log_h = match (size_of(tk, log_in), size_of(tk, heading)) {
        (Some(inner), Some(head)) => (inner.1 - head.1.max(24.0) - 21.0).floor(),
        _ => LOG_HEIGHT,
    };
    let log_size = (content_w, log_h.max(LOG_MIN_HEIGHT));
    let log_canvas = Canvas::new(tk, log_in, log_size.0, log_size.1)?;
    grid_row!(tk, log_canvas, 1, Sticky::W, SP_4);
    tk.a11y_set_label(log_canvas, "Build log");
    // Canvas text uses the canvas widget's font family: make the log monospace.
    tk.config(log_canvas, Opt::Monospace(true));
    let (digits_w, glyph_h) = tk.text_size("0000000000", LOG_FONT, 400);
    let log_line = (glyph_h + 3.0).ceil().max(LOG_LINE);
    let log_char_w = (digits_w / 10.0).max(LOG_FONT * 0.6);
    let _ = tk.canvas_scrollregion(log_canvas, log_size.0, log_size.1);

    Ok(Ui {
        status_chip,
        theme_var,
        theme_combo,
        folder_entry,
        browse_btn,
        error_label,
        profile_var,
        radio_release,
        radio_debug,
        test_var,
        test_switch,
        rtk_var,
        rtk_switch,
        start_btn,
        cancel_btn,
        open_btn,
        progress_var,
        progress_bar,
        progress_label,
        table,
        pass_chip,
        fail_chip,
        summary_label,
        log_canvas,
        bar_size,
        log_size,
        log_line,
        log_char_w,
        content_w,
        cache: RefCell::new(RenderCache::default()),
    })
}

/// Shows the inline validation error, or (with `None`) restores the hint.
pub fn set_error(tk: &mut Tk, ui: &Ui, message: Option<&str>) {
    match message {
        Some(message) => {
            tk.config(ui.error_label, Opt::Style(theme::STYLE_ERROR.into()));
            tk.config(ui.error_label, Opt::Text(message.to_string()));
        }
        None => {
            tk.config(ui.error_label, Opt::Style("Muted".into()));
            tk.config(ui.error_label, Opt::Text(HINT_TEXT.to_string()));
        }
    }
}

fn chip_style(status: Status) -> &'static str {
    match status {
        Status::Idle => "Chip.Neutral",
        Status::Building => "Chip.Info",
        Status::Passed => "Chip.Success",
        Status::Failed => "Chip.Danger",
        Status::Cancelled => "Chip.Warning",
    }
}

/// Removes control characters and shortens `text` to fit `max_width`.
fn fit_text(tk: &mut Tk, text: &str, size: f32, weight: u16, max_width: f32) -> String {
    let clean: String = text
        .chars()
        .map(|c| if c == '\t' { ' ' } else { c })
        .filter(|c| !c.is_control())
        .collect();
    if clean.is_empty() {
        return clean;
    }
    let (width, _) = tk.text_size(&clean, size, weight);
    if width <= max_width || width <= 0.0 {
        return clean;
    }
    let count = clean.chars().count();
    let mut keep = ((count as f32) * max_width / width) as usize;
    for _ in 0..12 {
        keep = keep.saturating_sub(2);
        let candidate: String = clean.chars().take(keep).chain(['…']).collect();
        let (w, _) = tk.text_size(&candidate, size, weight);
        if w <= max_width || keep == 0 {
            return candidate;
        }
    }
    clean.chars().take(keep).chain(['…']).collect()
}

/// Paints the progress bar: a subtle track with an accent-coloured fill.
fn draw_bar(tk: &mut Tk, ui: &Ui, pct: i64) {
    let pal = theme::bar_palette(tk);
    let (w, h) = ui.bar_size;
    let canvas = ui.progress_bar;
    let radius = h / 2.0;
    tk.canvas_clear(canvas);
    tk.canvas_create_rect(canvas, 0.0, 0.0, w, h, pal.card);
    tk.canvas_create_round_rect(canvas, 0.0, 0.0, w, h, radius, pal.track);
    if pct > 0 {
        let fraction = (pct.min(100) as f32) / 100.0;
        let fill_w = (w * fraction).clamp(h.min(w), w);
        tk.canvas_create_round_rect(canvas, 0.0, 0.0, fill_w, h, radius, pal.fill);
    }
}

/// Removes control characters and cuts `text` to at most `max_chars`
/// characters (monospace fitting; no per-line text measurement).
fn fit_mono(text: &str, max_chars: usize) -> String {
    let mut chars = text
        .chars()
        .map(|c| if c == '\t' { ' ' } else { c })
        .filter(|c| !c.is_control());
    let mut out: String = chars.by_ref().take(max_chars.max(2)).collect();
    if chars.next().is_some() {
        out.pop();
        out.push('…');
    }
    out
}

/// Puts the vertical scroll offset back to `y` if a redraw moved it.
fn restore_view(tk: &mut Tk, canvas: WidgetId, y: f32, content_h: f32, view_h: f32) {
    let moved = |tk: &mut Tk| {
        tk.canvas_view(canvas)
            .map(|(_, now)| (now - y).abs() > 0.5)
            .unwrap_or(false)
    };
    if !moved(tk) || content_h <= 0.0 {
        return;
    }
    tk.yview_moveto(canvas, (y / content_h).clamp(0.0, 1.0));
    if moved(tk) && content_h > view_h {
        tk.yview_moveto(canvas, (y / (content_h - view_h)).clamp(0.0, 1.0));
    }
}

/// Redraws the log (most recent `LOG_MAX_DRAWN` lines) as scrollable canvas
/// content and returns the content height. The view stays pinned to the
/// bottom unless the user had scrolled up by more than one line.
fn draw_log(tk: &mut Tk, ui: &Ui, state: &BuildState, prev_content_h: Option<f32>) -> f32 {
    let pal = theme::log_palette(tk);
    let canvas = ui.log_canvas;
    let (w, h) = ui.log_size;
    let line = ui.log_line;
    let drawn = state.log_len().min(LOG_MAX_DRAWN);
    let content_h = (2.0 * LOG_PAD + drawn as f32 * line).max(h);

    // Decide before touching the canvas whether the user is at the bottom.
    let view_y = tk.canvas_view(canvas).map(|(_, y)| y);
    let pinned = match (view_y, prev_content_h) {
        (Some(y), Some(prev)) => content_h < prev || y >= prev - h - line,
        _ => true,
    };

    tk.canvas_clear(canvas);
    tk.canvas_create_rect(canvas, 0.0, 0.0, w, content_h, pal.card);
    tk.canvas_create_round_rect_outline(
        canvas,
        0.5,
        0.5,
        w - 0.5,
        content_h - 0.5,
        8.0,
        Some(pal.bg),
        pal.border,
        1.0,
    );
    let text_x = LOG_PAD + 2.0;
    if drawn == 0 {
        tk.canvas_create_text_ex(
            canvas,
            text_x,
            LOG_PAD,
            "Build output will appear here.",
            pal.muted,
            LOG_FONT,
            400,
        );
    } else {
        let max_chars = ((w - 2.0 * text_x) / ui.log_char_w).floor().max(8.0) as usize;
        for (row, (role, text)) in state.log_tail(LOG_MAX_DRAWN).enumerate() {
            let weight: u16 = if *role == Role::Heading { 700 } else { 400 };
            let fitted = fit_mono(text, max_chars);
            if fitted.is_empty() {
                continue;
            }
            tk.canvas_create_text_ex(
                canvas,
                text_x,
                LOG_PAD + row as f32 * line,
                fitted,
                pal.color(*role),
                LOG_FONT,
                weight,
            );
        }
    }

    let _ = tk.canvas_scrollregion(canvas, w, content_h);
    if pinned {
        tk.yview_moveto(canvas, 1.0);
    } else if let Some(y) = view_y {
        restore_view(tk, canvas, y, content_h, h);
    }
    content_h
}

/// Pushes `state` to the widgets, touching only what changed since the last
/// call (or everything colour-related after a theme change).
pub fn render(tk: &mut Tk, ui: &Ui, state: &BuildState) {
    let Ok(mut cache) = ui.cache.try_borrow_mut() else {
        return;
    };

    let theme_now = tk.theme();
    if cache.theme.as_ref() != Some(&theme_now) {
        theme::install_styles(tk);
        cache.theme = Some(theme_now);
        cache.log_rev = None;
        cache.progress_pct = None;
    }

    let status = state.status();
    if cache.status != Some(status) {
        tk.config(ui.status_chip, Opt::Text(status.label().to_string()));
        tk.config(ui.status_chip, Opt::Style(chip_style(status).into()));
        cache.status = Some(status);
    }

    let running = state.is_running();
    if cache.running != Some(running) {
        for id in [
            ui.folder_entry,
            ui.browse_btn,
            ui.radio_release,
            ui.radio_debug,
            ui.test_switch,
            ui.rtk_switch,
        ] {
            tk.config(id, Opt::Disabled(running));
        }
        // While a build runs the start button becomes a neutral, fully
        // readable "Building..." indicator; the controller ignores clicks
        // on it until the run has finished.
        if running {
            tk.config(ui.start_btn, Opt::Style("TButton".into()));
            tk.config(ui.start_btn, Opt::Text(BUSY_TEXT.to_string()));
            tk.tooltip(ui.start_btn, "A build is running - press Esc to cancel");
        } else {
            tk.config(ui.start_btn, Opt::Style("Accent.TButton".into()));
            tk.config(ui.start_btn, Opt::Text(START_TEXT.to_string()));
            tk.tooltip(ui.start_btn, "Ctrl+Enter or F5");
        }
        tk.config(ui.cancel_btn, Opt::Disabled(!running));
        cache.running = Some(running);
    }

    let can_open = !running && state.built_dir().is_some();
    if cache.can_open != Some(can_open) {
        tk.config(ui.open_btn, Opt::Disabled(!can_open));
        cache.can_open = Some(can_open);
    }

    let pct = (state.progress_fraction() * 100.0).round() as i64;
    if cache.progress_pct != Some(pct) {
        ui.progress_var.set(tk, pct);
        draw_bar(tk, ui, pct);
        tk.a11y_set_label(ui.progress_bar, format!("Build progress {pct}%"));
        cache.progress_pct = Some(pct);
    }
    let mut text = state.progress_text();
    if running || pct > 0 {
        text = format!("{text}  ({pct}%)");
    }
    if cache.progress_text.as_deref() != Some(text.as_str()) {
        let max_width = (ui.content_w - 150.0).max(120.0);
        let fitted = fit_text(tk, &text, LABEL_FONT, 400, max_width);
        tk.config(ui.progress_label, Opt::Text(fitted));
        cache.progress_text = Some(text);
    }

    if cache.table_rev != Some(state.table_revision()) {
        tk.table_set_rows(ui.table, state.table_rows());
        cache.table_rev = Some(state.table_revision());
    }

    let counts = (state.passed(), state.failed());
    if cache.counts != Some(counts) {
        tk.config(ui.pass_chip, Opt::Text(format!("{} passed", counts.0)));
        tk.config(ui.fail_chip, Opt::Text(format!("{} failed", counts.1)));
        let fail_style = if counts.1 > 0 {
            "Chip.Danger"
        } else {
            "Chip.Neutral"
        };
        tk.config(ui.fail_chip, Opt::Style(fail_style.into()));
        cache.counts = Some(counts);
    }
    let summary = state.summary_text();
    if cache.summary_text.as_deref() != Some(summary.as_str()) {
        let max_width = (ui.content_w - 24.0).max(120.0);
        let fitted = fit_text(tk, &summary, LABEL_FONT, 400, max_width);
        tk.config(ui.summary_label, Opt::Text(fitted));
        cache.summary_text = Some(summary);
    }

    if cache.log_rev != Some(state.log_revision()) {
        let content_h = draw_log(tk, ui, state, cache.log_content_h);
        cache.log_content_h = Some(content_h);
        cache.log_rev = Some(state.log_revision());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{sample_state, Stage};

    #[test]
    fn build_and_render_headless() {
        let mut tk = Tk::new();
        tk.geometry(crate::WINDOW_WIDTH, crate::WINDOW_HEIGHT);
        theme::apply(&mut tk, ThemeChoice::Dark);
        let ui = build(&mut tk, ThemeChoice::Dark).expect("ui builds");
        for stage in Stage::ALL {
            let state = sample_state(stage);
            render(&mut tk, &ui, &state);
            render(&mut tk, &ui, &state);
        }
        assert_eq!(tk.table_row_count(ui.table), 5);
        assert_eq!(ui.progress_var.get(&tk), Some(100));
        assert!(tk.canvas_items(ui.log_canvas) > 1);
        assert!(tk.canvas_items(ui.progress_bar) > 1);
        set_error(&mut tk, &ui, Some("Folder not found"));
        assert_eq!(
            tk.widget_text(ui.error_label).as_deref(),
            Some("Folder not found")
        );
        set_error(&mut tk, &ui, None);
        assert_eq!(tk.widget_text(ui.error_label).as_deref(), Some(HINT_TEXT));
    }

    #[test]
    fn log_scrollback_stays_where_the_user_scrolled() {
        /// Wheel amount in whatever numeric type `sim_wheel` takes.
        fn lines<T: From<i8>>(n: i8) -> T {
            T::from(n)
        }

        let mut tk = Tk::new();
        tk.geometry(crate::WINDOW_WIDTH, crate::WINDOW_HEIGHT);
        theme::apply(&mut tk, ThemeChoice::Dark);
        let ui = build(&mut tk, ThemeChoice::Dark).expect("ui builds");
        tk.sim_resize(crate::WINDOW_WIDTH, crate::WINDOW_HEIGHT);

        let mut state = BuildState::new();
        state.begin();
        for i in 0..300 {
            state.push_log(Role::Text, format!("log line {i}"));
        }
        render(&mut tk, &ui, &state);

        let view_y = |tk: &mut Tk| {
            tk.canvas_view(ui.log_canvas)
                .map(|(_, y)| y)
                .expect("log canvas has a view")
        };

        // Pinned at the bottom: scrolled away from the top, and asking for
        // the bottom again does not move the view.
        let bottom = view_y(&mut tk);
        assert!(bottom > 0.0, "300 lines must overflow the log view");
        tk.yview_moveto(ui.log_canvas, 1.0);
        assert!((view_y(&mut tk) - bottom).abs() < 0.5, "not pinned to the bottom");

        // Wheel up over the log (try the other sign if the first is "down").
        let rect = tk.widget_rect(ui.log_canvas).expect("log canvas rect");
        tk.sim_mouse_move(rect.x + rect.width / 2.0, rect.y + rect.height / 2.0);
        for _ in 0..4 {
            tk.sim_wheel(lines(3));
        }
        if view_y(&mut tk) >= bottom - 0.5 {
            for _ in 0..4 {
                tk.sim_wheel(lines(-3));
            }
        }
        let up = view_y(&mut tk);
        assert!(up < bottom - 0.5, "wheel did not scroll up: {up} vs {bottom}");

        // A new line must not drag the view back to the bottom.
        state.push_log(Role::Text, "one more line");
        render(&mut tk, &ui, &state);
        let after = view_y(&mut tk);
        tk.yview_moveto(ui.log_canvas, 1.0);
        let new_bottom = view_y(&mut tk);
        assert!(
            after < new_bottom - 0.5,
            "view jumped to the bottom: {after} vs {new_bottom}"
        );
    }
}
