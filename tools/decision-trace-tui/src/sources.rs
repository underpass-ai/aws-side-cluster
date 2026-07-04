//! Clientes minimos de Tempo y Loki (HTTP, bloqueantes). Sin SDKs: las dos
//! APIs son JSON plano y esto debe poder compilar y correr en cualquier
//! sitio con red al cluster.

use anyhow::{Context, Result};
use serde_json::Value;

use crate::model::{LogEvent, Span};

pub fn fetch_trace(tempo_url: &str, trace_id: &str) -> Result<Vec<Span>> {
    let url = format!("{}/api/traces/{}", tempo_url.trim_end_matches('/'), trace_id);
    let body: Value = reqwest::blocking::get(&url)
        .with_context(|| format!("GET {url}"))?
        .error_for_status()?
        .json()?;

    // Formato OTLP JSON de Tempo: batches[].scopeSpans[].spans[]
    let mut raw: Vec<(String, String, u64, u64, String, String)> = Vec::new();
    for batch in body["batches"].as_array().unwrap_or(&Vec::new()) {
        let service = batch["resource"]["attributes"]
            .as_array()
            .and_then(|attrs| {
                attrs.iter().find(|a| a["key"] == "service.name").and_then(|a| {
                    a["value"]["stringValue"].as_str().map(str::to_owned)
                })
            })
            .unwrap_or_else(|| "?".into());
        for scope in batch["scopeSpans"].as_array().unwrap_or(&Vec::new()) {
            for s in scope["spans"].as_array().unwrap_or(&Vec::new()) {
                raw.push((
                    s["name"].as_str().unwrap_or("?").to_owned(),
                    service.clone(),
                    s["startTimeUnixNano"].as_str().and_then(|v| v.parse().ok()).unwrap_or(0),
                    s["endTimeUnixNano"].as_str().and_then(|v| v.parse().ok()).unwrap_or(0),
                    s["spanId"].as_str().unwrap_or("").to_owned(),
                    s["parentSpanId"].as_str().unwrap_or("").to_owned(),
                ));
            }
        }
    }
    raw.sort_by_key(|r| r.2);

    // Profundidad por cadena de padres (waterfall sencillo).
    let ids: std::collections::HashMap<String, usize> =
        raw.iter().enumerate().map(|(i, r)| (r.4.clone(), i)).collect();
    let mut spans = Vec::with_capacity(raw.len());
    for r in &raw {
        let mut depth = 0usize;
        let mut parent = r.5.clone();
        while !parent.is_empty() && depth < 16 {
            match ids.get(&parent) {
                Some(&i) => {
                    depth += 1;
                    parent = raw[i].5.clone();
                }
                None => break,
            }
        }
        spans.push(Span {
            name: r.0.clone(),
            service: r.1.clone(),
            start_ns: r.2,
            end_ns: r.3,
            depth,
        });
    }
    Ok(spans)
}

/// Eventos clave de la ceremonia desde Loki, filtrados por ceremony_id.
pub fn fetch_events(
    loki_url: &str,
    ceremony_id: &str,
    namespace: &str,
    hours_back: i64,
) -> Result<Vec<LogEvent>> {
    let query = format!(
        "{{namespace=\"{namespace}\", pod=~\"choreographer.*\"}} |= \"{ceremony_id}\""
    );
    let now = chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0);
    let start = now - hours_back * 3_600 * 1_000_000_000;
    let url = format!(
        "{}/loki/api/v1/query_range?query={}&start={}&end={}&limit=500&direction=forward",
        loki_url.trim_end_matches('/'),
        urlencoding::encode(&query),
        start,
        now
    );
    let body: Value = reqwest::blocking::get(&url)
        .with_context(|| format!("GET {url}"))?
        .error_for_status()?
        .json()?;

    const INTERESTING: [&str; 8] = [
        "ceremony participant prepared",
        "proposal drafted",
        "peer critique and revision",
        "validator verdict",
        "proposal scored",
        "deliberation completed",
        "ceremony step deliberation completed",
        "ceremony completed",
    ];

    let mut events = Vec::new();
    for stream in body["data"]["result"].as_array().unwrap_or(&Vec::new()) {
        for v in stream["values"].as_array().unwrap_or(&Vec::new()) {
            let line = v[1].as_str().unwrap_or("");
            let Ok(parsed) = serde_json::from_str::<Value>(line) else { continue };
            let msg = parsed["fields"]["message"].as_str().unwrap_or("");
            if !INTERESTING.contains(&msg) {
                continue;
            }
            let f = &parsed["fields"];
            let detail = [
                f["step_id"].as_str().map(|s| format!("step={s}")),
                f["author"].as_str().map(|s| format!("author={s}")),
                f["reviewer"].as_str().map(|s| format!("reviewer={s}")),
                f["round"].as_u64().map(|r| format!("round={r}")),
                f["validator"].as_str().map(|s| format!("validator={s}")),
                f["passed"].as_bool().map(|p| format!("passed={p}")),
                f["verdict"].as_str().map(|s| format!("verdict={s}")),
                f["winner_score"].as_f64().map(|s| format!("score={s}")),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ");
            events.push(LogEvent {
                ts: parsed["timestamp"].as_str().unwrap_or("?").to_owned(),
                message: msg.to_owned(),
                detail,
            });
        }
    }
    events.sort_by(|a, b| a.ts.cmp(&b.ts));
    Ok(events)
}

/// ¿Sigue vivo el worker? (Para el pie de pantalla: "the worker is gone".)
/// Best-effort via aws cli si esta instalado; None si no se puede saber.
pub fn worker_alive(instance_id: &str) -> Option<bool> {
    if instance_id.is_empty() {
        return None;
    }
    let out = std::process::Command::new("aws")
        .args([
            "ec2",
            "describe-instances",
            "--instance-ids",
            instance_id,
            "--query",
            "Reservations[0].Instances[0].State.Name",
            "--output",
            "text",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let state = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    Some(state == "running")
}
