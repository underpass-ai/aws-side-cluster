//! Render: un waterfall de spans, el artefacto de decision y la timeline de
//! eventos — y el pie que resume la tesis: el worker ya no existe, la
//! decision si.

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span as TSpan},
    widgets::{Block, Borders, List, ListItem, Paragraph, Wrap},
    Frame,
};

use crate::model::Reconstruction;

pub struct AppState {
    pub rec: Reconstruction,
    pub log_scroll: usize,
    pub span_scroll: usize,
    pub focus_logs: bool,
}

pub fn draw(f: &mut Frame, st: &AppState) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(10), Constraint::Length(3)])
        .split(f.area());

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(55), Constraint::Percentage(45)])
        .split(outer[0]);

    draw_waterfall(f, cols[0], st);

    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(11), Constraint::Min(5)])
        .split(cols[1]);
    draw_artifact(f, right[0], st);
    draw_events(f, right[1], st);
    draw_footer(f, outer[1], st);
}

fn draw_waterfall(f: &mut Frame, area: Rect, st: &AppState) {
    let rec = &st.rec;
    let t0 = rec.spans.iter().map(|s| s.start_ns).min().unwrap_or(0);
    let t1 = rec.spans.iter().map(|s| s.end_ns).max().unwrap_or(1);
    let total = (t1.saturating_sub(t0)).max(1) as f64;
    let bar_w = 24usize;

    let items: Vec<ListItem> = rec
        .spans
        .iter()
        .skip(st.span_scroll)
        .map(|s| {
            let off = ((s.start_ns.saturating_sub(t0)) as f64 / total * bar_w as f64) as usize;
            let len = (((s.end_ns.saturating_sub(s.start_ns)) as f64 / total * bar_w as f64)
                .ceil() as usize)
                .clamp(1, bar_w.saturating_sub(off).max(1));
            let bar = format!(
                "{}{}{}",
                " ".repeat(off),
                "█".repeat(len),
                " ".repeat(bar_w.saturating_sub(off + len))
            );
            let indent = "  ".repeat(s.depth);
            ListItem::new(Line::from(vec![
                TSpan::styled(bar, Style::default().fg(Color::Cyan)),
                TSpan::raw(format!(" {:>8.1}ms ", s.duration_ms())),
                TSpan::styled(
                    format!("{indent}{}", s.name),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                TSpan::styled(format!("  [{}]", s.service), Style::default().fg(Color::DarkGray)),
            ]))
        })
        .collect();

    let title = format!(
        " trace {} · {} spans · {:.1}s total ",
        st.rec.artifact.trace_id,
        rec.spans.len(),
        rec.trace_duration_ms / 1000.0
    );
    let border = if st.focus_logs { Style::default() } else { Style::default().fg(Color::Cyan) };
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title(title).border_style(border)),
        area,
    );
}

fn draw_artifact(f: &mut Frame, area: Rect, st: &AppState) {
    let a = &st.rec.artifact;
    let escape_style = if a.unsupported_claim_escape_count == 0 {
        Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
    };
    let status_style = match a.status.as_str() {
        "accept" => Style::default().fg(Color::Green),
        "reject" => Style::default().fg(Color::Red),
        _ => Style::default().fg(Color::Yellow),
    };
    let mut lines = vec![
        Line::from(vec![
            TSpan::raw("decision  "),
            TSpan::styled(&a.decision_id, Style::default().add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            TSpan::raw("profile   "),
            TSpan::raw(a.profile.as_str()),
        ]),
        Line::from(vec![
            TSpan::raw("status    "),
            TSpan::styled(a.status.as_str(), status_style),
        ]),
        Line::from(format!(
            "claims    {} total · {} con evidencia · {} sin evidencia · {} rechazadas",
            a.final_claims_total, a.claims_with_evidence, a.claims_without_evidence, a.rejected_claims
        )),
        Line::from(vec![
            TSpan::raw("escaped   "),
            TSpan::styled(
                format!("{} unsupported claims llegaron a la decision", a.unsupported_claim_escape_count),
                escape_style,
            ),
        ]),
    ];
    if let Some(w) = &a.worker_lifecycle {
        lines.push(Line::from(format!(
            "worker    {}/{} {} · ephemeral={} · idle_shutdown={}",
            w.provider, w.instance_family, w.instance_id, w.ephemeral, w.idle_shutdown_triggered
        )));
        if let (Some(l), Some(s)) = (&w.launched_at, &w.stopped_at) {
            lines.push(Line::from(format!("lifetime  {l} → {s}")));
        }
    }
    f.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(" decision artifact ")),
        area,
    );
}

fn draw_events(f: &mut Frame, area: Rect, st: &AppState) {
    let items: Vec<ListItem> = st
        .rec
        .events
        .iter()
        .skip(st.log_scroll)
        .map(|e| {
            let ts = e.ts.get(11..19).unwrap_or(&e.ts);
            ListItem::new(Line::from(vec![
                TSpan::styled(format!("{ts} "), Style::default().fg(Color::DarkGray)),
                TSpan::styled(&e.message, Style::default().fg(Color::Yellow)),
                TSpan::raw(format!("  {}", e.detail)),
            ]))
        })
        .collect();
    let border = if st.focus_logs { Style::default().fg(Color::Cyan) } else { Style::default() };
    f.render_widget(
        List::new(items).block(
            Block::default()
                .borders(Borders::ALL)
                .title(format!(" evidencia (Loki) · {} eventos ", st.rec.events.len()))
                .border_style(border),
        ),
        area,
    );
}

fn draw_footer(f: &mut Frame, area: Rect, st: &AppState) {
    let msg = match st.rec.worker_alive_now {
        Some(false) => TSpan::styled(
            " ✔ el worker GPU ya NO existe — esta decision se ha reconstruido solo con la evidencia persistida ",
            Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
        ),
        Some(true) => TSpan::styled(
            " el worker sigue vivo (la reconstruccion no depende de el) ",
            Style::default().fg(Color::Yellow),
        ),
        None => TSpan::raw(" estado del worker desconocido (aws cli no disponible) "),
    };
    f.render_widget(
        Paragraph::new(Line::from(vec![
            msg,
            TSpan::styled("· q salir · tab foco · ↑↓ scroll", Style::default().fg(Color::DarkGray)),
        ]))
        .block(Block::default().borders(Borders::ALL)),
        area,
    );
}
