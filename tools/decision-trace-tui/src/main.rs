//! decision-trace-tui — reconstruye una decision de agentes despues de que
//! el worker GPU que ayudo a producirla haya sido apagado.
//!
//! Punto de entrada: el decision artifact (JSON persistido). De el salen
//! trace_id (Tempo) y ceremony_id (Loki). Uso:
//!
//!   decision-trace-tui decision.json \
//!     --tempo http://<tempo>:3200 --loki http://<loki>:3100
//!
//!   decision-trace-tui decision.json --no-tui   # reconstruccion en texto

mod model;
mod sources;
mod ui;

use anyhow::{Context, Result};
use clap::Parser;
use crossterm::event::{self, Event, KeyCode};
use model::{DecisionArtifact, Reconstruction};

#[derive(Parser)]
#[command(version, about)]
struct Args {
    /// Ruta al decision artifact JSON (el registro persistido de la decision)
    artifact: String,
    /// URL base de Tempo
    #[arg(long, env = "TEMPO_URL", default_value = "http://localhost:3200")]
    tempo: String,
    /// URL base de Loki
    #[arg(long, env = "LOKI_URL", default_value = "http://localhost:3100")]
    loki: String,
    /// Namespace de los logs del choreographer
    #[arg(long, default_value = "underpass-labs")]
    namespace: String,
    /// Horas hacia atras para buscar logs
    #[arg(long, default_value_t = 168)]
    hours_back: i64,
    /// Imprimir la reconstruccion como texto plano (sin TUI)
    #[arg(long)]
    no_tui: bool,
}

fn reconstruct(args: &Args) -> Result<Reconstruction> {
    let raw = std::fs::read_to_string(&args.artifact)
        .with_context(|| format!("leyendo {}", args.artifact))?;
    let artifact: DecisionArtifact = serde_json::from_str(&raw).context("decision artifact invalido")?;

    let spans = sources::fetch_trace(&args.tempo, &artifact.trace_id)
        .with_context(|| format!("Tempo: trace {}", artifact.trace_id))?;
    let events = sources::fetch_events(&args.loki, &artifact.ceremony_id, &args.namespace, args.hours_back)
        .unwrap_or_default();

    let t0 = spans.iter().map(|s| s.start_ns).min().unwrap_or(0);
    let t1 = spans.iter().map(|s| s.end_ns).max().unwrap_or(0);
    let worker_alive_now = artifact
        .worker_lifecycle
        .as_ref()
        .and_then(|w| sources::worker_alive(&w.instance_id));

    Ok(Reconstruction {
        artifact,
        spans,
        events,
        worker_alive_now,
        trace_duration_ms: (t1.saturating_sub(t0)) as f64 / 1_000_000.0,
    })
}

fn print_plain(rec: &Reconstruction) {
    let a = &rec.artifact;
    println!("== decision {} ({}) ==", a.decision_id, a.profile);
    println!(
        "status: {} · trace: {} ({:.1}s, {} spans)",
        a.status,
        a.trace_id,
        rec.trace_duration_ms / 1000.0,
        rec.spans.len()
    );
    println!(
        "claims: {} total, {} con evidencia, {} rechazadas, {} ESCAPED",
        a.final_claims_total, a.claims_with_evidence, a.rejected_claims, a.unsupported_claim_escape_count
    );
    if let Some(w) = &a.worker_lifecycle {
        println!(
            "worker: {} {} idle_shutdown={} alive_now={:?}",
            w.instance_family, w.instance_id, w.idle_shutdown_triggered, rec.worker_alive_now
        );
    }
    println!("-- spans --");
    for s in &rec.spans {
        println!("{}{} ({:.1}ms)", "  ".repeat(s.depth), s.name, s.duration_ms());
    }
    println!("-- eventos ({}) --", rec.events.len());
    for e in &rec.events {
        println!("{} {} {}", e.ts, e.message, e.detail);
    }
}

fn run_tui(rec: Reconstruction) -> Result<()> {
    let mut terminal = ratatui::init();
    let mut st = ui::AppState { rec, log_scroll: 0, span_scroll: 0, focus_logs: false };
    loop {
        terminal.draw(|f| ui::draw(f, &st))?;
        if let Event::Key(k) = event::read()? {
            match k.code {
                KeyCode::Char('q') | KeyCode::Esc => break,
                KeyCode::Tab => st.focus_logs = !st.focus_logs,
                KeyCode::Down => {
                    if st.focus_logs {
                        st.log_scroll = (st.log_scroll + 1).min(st.rec.events.len().saturating_sub(1));
                    } else {
                        st.span_scroll = (st.span_scroll + 1).min(st.rec.spans.len().saturating_sub(1));
                    }
                }
                KeyCode::Up => {
                    if st.focus_logs {
                        st.log_scroll = st.log_scroll.saturating_sub(1);
                    } else {
                        st.span_scroll = st.span_scroll.saturating_sub(1);
                    }
                }
                _ => {}
            }
        }
    }
    ratatui::restore();
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();
    let rec = reconstruct(&args)?;
    if args.no_tui {
        print_plain(&rec);
        return Ok(());
    }
    run_tui(rec)
}
