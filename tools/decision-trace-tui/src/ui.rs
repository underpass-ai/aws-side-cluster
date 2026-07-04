//! Render: fondo solido propio (independiente del tema/transparencia del
//! terminal), waterfall coloreado, badge de estado, iconos por evento y el
//! pie con la tesis. Pensado para que la captura del articulo luzca sola.

use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span as TSpan},
    widgets::{Block, BorderType, Borders, Clear, List, ListItem, Paragraph, Wrap},
    Frame,
};

use crate::model::Reconstruction;

// Paleta (truecolor): fondo carbon, paneles apenas mas claros, acentos vivos.
const BG: Color = Color::Rgb(13, 15, 20);
const PANEL: Color = Color::Rgb(20, 23, 31);
const FG: Color = Color::Rgb(214, 219, 230);
const DIM: Color = Color::Rgb(110, 118, 134);
const CYAN: Color = Color::Rgb(0, 200, 255);
const MAGENTA: Color = Color::Rgb(255, 121, 198);
const YELLOW: Color = Color::Rgb(255, 200, 87);
const GREEN: Color = Color::Rgb(80, 250, 123);
const RED: Color = Color::Rgb(255, 85, 85);
const BLUE: Color = Color::Rgb(98, 160, 255);

pub struct AppState {
    pub rec: Reconstruction,
    pub log_scroll: usize,
    pub span_scroll: usize,
    pub focus_logs: bool,
}

fn panel(title: Vec<TSpan<'_>>, focused: bool) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(if focused {
            Style::default().fg(CYAN)
        } else {
            Style::default().fg(Color::Rgb(60, 66, 82))
        })
        .style(Style::default().bg(PANEL))
        .title(Line::from(title))
}

pub fn draw(f: &mut Frame, st: &AppState) {
    // Fondo solido en TODO el frame: inmune a terminales translucidos.
    f.render_widget(Clear, f.area());
    f.render_widget(
        Block::default().style(Style::default().bg(BG)),
        f.area(),
    );

    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(10),
            Constraint::Length(3),
        ])
        .split(f.area());

    // Cabecera-lema
    f.render_widget(
        Paragraph::new(Line::from(vec![
            TSpan::styled("  ⛭ DECISION TRACE ", Style::default().fg(CYAN).add_modifier(Modifier::BOLD)),
            TSpan::styled("· compute is disposable — evidence is persistent", Style::default().fg(DIM)),
        ]))
        .style(Style::default().bg(BG)),
        outer[0],
    );

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(52), Constraint::Percentage(48)])
        .split(outer[1]);

    draw_waterfall(f, cols[0], st);

    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(10), Constraint::Min(5)])
        .split(cols[1]);
    draw_artifact(f, right[0], st);
    draw_events(f, right[1], st);
    draw_footer(f, outer[2], st);
}

const BAR_COLORS: [Color; 6] = [CYAN, MAGENTA, YELLOW, GREEN, BLUE, RED];
const CIRCLED: [&str; 9] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"];

/// Timeline narrativo: una fila por FASE de la decision (step de la
/// ceremonia), no por span. Numero, nombre del paso, quien hablo, barra
/// proporcional alineada al tiempo real y duracion. La fontaneria
/// (rpc/prepare/run_ceremony) vive solo en el titulo.
fn draw_waterfall(f: &mut Frame, area: Rect, st: &AppState) {
    let rec = &st.rec;
    let total = rec.trace_duration_ms.max(1.0);
    let bar_w = 26usize;

    let mut items: Vec<ListItem> = vec![ListItem::new(Line::from(vec![
        TSpan::styled(
            format!("   {:<12}", "FASE"),
            Style::default().fg(DIM).add_modifier(Modifier::BOLD),
        ),
        TSpan::styled(format!("{:<28}", "QUIEN"), Style::default().fg(DIM).add_modifier(Modifier::BOLD)),
        TSpan::styled("TIEMPO", Style::default().fg(DIM).add_modifier(Modifier::BOLD)),
    ]))];

    items.extend(rec.phases.iter().skip(st.span_scroll).map(|p| {
        let color = BAR_COLORS[(p.idx - 1) % BAR_COLORS.len()];
        let off = ((p.start_offset_ms / total) * bar_w as f64) as usize;
        let len = (((p.duration_ms / total) * bar_w as f64).ceil() as usize)
            .clamp(1, bar_w.saturating_sub(off).max(1));
        let num = CIRCLED.get(p.idx - 1).copied().unwrap_or("●");
        ListItem::new(Line::from(vec![
            TSpan::styled(format!(" {num} "), Style::default().fg(color).add_modifier(Modifier::BOLD)),
            TSpan::styled(
                format!("{:<12}", p.name.to_uppercase()),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
            TSpan::styled(format!("✎ {:<26}", p.author), Style::default().fg(FG)),
            TSpan::raw(" ".repeat(off)),
            TSpan::styled("█".repeat(len), Style::default().fg(color)),
            TSpan::raw(" ".repeat(bar_w.saturating_sub(off + len))),
            TSpan::styled(format!(" {:>6.1}s", p.duration_ms / 1000.0), Style::default().fg(FG).add_modifier(Modifier::BOLD)),
        ]))
    }));

    if rec.phases.is_empty() {
        items.push(ListItem::new(Line::from(TSpan::styled(
            " (sin fases deliberativas en la traza — ver spans crudos con --no-tui) ",
            Style::default().fg(DIM),
        ))));
    }

    let title = vec![
        TSpan::styled(" ⧗ timeline de la decisión ", Style::default().fg(CYAN).add_modifier(Modifier::BOLD)),
        TSpan::styled(
            format!(
                "· {:.1}s · trace {} · {} spans ",
                rec.trace_duration_ms / 1000.0,
                &st.rec.artifact.trace_id[..12.min(st.rec.artifact.trace_id.len())],
                rec.spans.len()
            ),
            Style::default().fg(DIM),
        ),
    ];
    f.render_widget(List::new(items).block(panel(title, !st.focus_logs)), area);
}

fn badge(status: &str) -> (String, Color) {
    match status {
        "accept" => (" ✔ ACCEPT ".into(), GREEN),
        "reject" => (" ✘ REJECT ".into(), RED),
        s => (format!(" ◈ {} ", s.to_uppercase()), YELLOW),
    }
}

fn draw_artifact(f: &mut Frame, area: Rect, st: &AppState) {
    let a = &st.rec.artifact;
    let (btxt, bcol) = badge(&a.status);
    let escaped_ok = a.unsupported_claim_escape_count == 0;

    let label = |t: &str| TSpan::styled(format!(" {t:<9}"), Style::default().fg(DIM));
    let mut lines = vec![
        Line::from(vec![
            label("decision"),
            TSpan::styled(a.decision_id.clone(), Style::default().fg(FG).add_modifier(Modifier::BOLD)),
            TSpan::raw("  "),
            TSpan::styled(btxt, Style::default().fg(Color::Black).bg(bcol).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![label("profile"), TSpan::styled(a.profile.clone(), Style::default().fg(BLUE))]),
        Line::from(vec![
            label("claims"),
            TSpan::styled(format!("{} total", a.final_claims_total), Style::default().fg(FG)),
            TSpan::styled(
                format!("  ✔ {} con evidencia", a.claims_with_evidence),
                Style::default().fg(GREEN),
            ),
            TSpan::styled(
                format!("  ✘ {} sin", a.claims_without_evidence),
                Style::default().fg(if a.claims_without_evidence == 0 { DIM } else { RED }),
            ),
        ]),
        Line::from(vec![
            label("escaped"),
            TSpan::styled(
                if escaped_ok {
                    " ✔ 0 unsupported claims llegaron a la decisión ".to_string()
                } else {
                    format!(" ✘ {} unsupported claims ESCAPARON ", a.unsupported_claim_escape_count)
                },
                Style::default()
                    .fg(Color::Black)
                    .bg(if escaped_ok { GREEN } else { RED })
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
    ];
    if let Some(w) = &a.worker_lifecycle {
        lines.push(Line::from(vec![
            label("worker"),
            TSpan::styled("☁ ", Style::default().fg(BLUE)),
            TSpan::styled(
                format!("{} {} ", w.instance_family, w.instance_id),
                Style::default().fg(FG),
            ),
            TSpan::styled(
                if w.idle_shutdown_triggered { "⏻ idle-shutdown" } else { "manual" },
                Style::default().fg(if w.idle_shutdown_triggered { MAGENTA } else { DIM }).add_modifier(Modifier::BOLD),
            ),
        ]));
        if let (Some(l), Some(s)) = (&w.launched_at, &w.stopped_at) {
            lines.push(Line::from(vec![
                label("lifetime"),
                TSpan::styled(format!("{l}  ➜  {s}"), Style::default().fg(DIM)),
            ]));
        }
    }
    let title = vec![TSpan::styled(
        " ⚖ decision artifact ",
        Style::default().fg(MAGENTA).add_modifier(Modifier::BOLD),
    )];
    f.render_widget(
        Paragraph::new(lines).wrap(Wrap { trim: false }).block(panel(title, false)),
        area,
    );
}

fn event_decor(msg: &str, detail: &str) -> (&'static str, Color) {
    match msg {
        "proposal drafted" => ("✎", CYAN),
        "peer critique and revision" => ("⚔", MAGENTA),
        "validator verdict" => {
            if detail.contains("passed=false") {
                ("✘", RED)
            } else {
                ("✔", GREEN)
            }
        }
        "proposal scored" => ("Σ", BLUE),
        "deliberation completed" => ("●", YELLOW),
        "ceremony step deliberation completed" => ("➤", YELLOW),
        "ceremony participant prepared" => ("+", DIM),
        _ => ("·", DIM),
    }
}

fn draw_events(f: &mut Frame, area: Rect, st: &AppState) {
    let items: Vec<ListItem> = st
        .rec
        .events
        .iter()
        .skip(st.log_scroll)
        .map(|e| {
            let ts = e.ts.get(11..19).unwrap_or(&e.ts);
            let (icon, color) = event_decor(&e.message, &e.detail);
            let step_end = e.message == "ceremony step deliberation completed";
            ListItem::new(Line::from(vec![
                TSpan::styled(format!(" {ts} "), Style::default().fg(DIM)),
                TSpan::styled(format!("{icon} "), Style::default().fg(color).add_modifier(Modifier::BOLD)),
                TSpan::styled(
                    e.message.clone(),
                    Style::default().fg(color).add_modifier(if step_end { Modifier::BOLD } else { Modifier::empty() }),
                ),
                TSpan::styled(format!("  {}", e.detail), Style::default().fg(FG)),
            ]))
        })
        .collect();
    let title = vec![
        TSpan::styled(" ☰ evidencia ", Style::default().fg(YELLOW).add_modifier(Modifier::BOLD)),
        TSpan::styled(
            format!("Loki · {} eventos ", st.rec.events.len()),
            Style::default().fg(DIM),
        ),
    ];
    f.render_widget(List::new(items).block(panel(title, st.focus_logs)), area);
}

fn draw_footer(f: &mut Frame, area: Rect, st: &AppState) {
    let msg = match st.rec.worker_alive_now {
        Some(false) => TSpan::styled(
            " ✔ EL WORKER GPU YA NO EXISTE — esta decisión se ha reconstruido solo con la evidencia persistida ",
            Style::default().fg(Color::Black).bg(GREEN).add_modifier(Modifier::BOLD),
        ),
        Some(true) => TSpan::styled(
            " ⚡ el worker sigue vivo (la reconstrucción no depende de él) ",
            Style::default().fg(Color::Black).bg(YELLOW).add_modifier(Modifier::BOLD),
        ),
        None => TSpan::styled(
            " ? estado del worker desconocido (aws cli no disponible) ",
            Style::default().fg(DIM),
        ),
    };
    f.render_widget(
        Paragraph::new(Line::from(vec![
            msg,
            TSpan::styled("   q salir · tab foco · ↑↓ scroll", Style::default().fg(DIM)),
        ]))
        .alignment(Alignment::Left)
        .block(panel(vec![], false)),
        area,
    );
}
