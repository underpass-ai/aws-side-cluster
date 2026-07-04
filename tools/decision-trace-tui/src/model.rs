//! Modelo de la reconstruccion: el decision artifact es el punto de entrada;
//! de el salen trace_id (Tempo) y ceremony_id (Loki). La tesis del
//! experimento en tipos: el computo desaparece, esto es lo que queda.

use serde::Deserialize;

/// Artefacto de decision persistido por el runner del experimento
/// (ver docs/experiments/plan-disposable-compute.md, fase 0.2).
#[derive(Debug, Clone, Deserialize)]
pub struct DecisionArtifact {
    pub decision_id: String,
    pub trace_id: String,
    #[serde(default)]
    pub ceremony_id: String,
    pub profile: String,
    pub status: String,
    #[serde(default)]
    pub final_claims_total: u64,
    #[serde(default)]
    pub claims_with_evidence: u64,
    #[serde(default)]
    pub claims_without_evidence: u64,
    #[serde(default)]
    pub rejected_claims: u64,
    #[serde(default)]
    pub unsupported_claim_escape_count: u64,
    #[serde(default)]
    pub worker_lifecycle: Option<WorkerLifecycle>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkerLifecycle {
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub instance_family: String,
    #[serde(default)]
    pub instance_id: String,
    #[serde(default)]
    pub ephemeral: bool,
    #[serde(default)]
    pub launched_at: Option<String>,
    #[serde(default)]
    pub stopped_at: Option<String>,
    #[serde(default)]
    pub idle_shutdown_triggered: bool,
}

/// Span aplanado del trace de Tempo (suficiente para el waterfall).
#[derive(Debug, Clone)]
pub struct Span {
    pub name: String,
    pub service: String,
    pub start_ns: u64,
    pub end_ns: u64,
    pub depth: usize,
}

impl Span {
    pub fn duration_ms(&self) -> f64 {
        (self.end_ns.saturating_sub(self.start_ns)) as f64 / 1_000_000.0
    }
}

/// Linea de log relevante recuperada de Loki (timeline de la decision).
#[derive(Debug, Clone)]
pub struct LogEvent {
    pub ts: String,
    pub message: String,
    pub detail: String,
}

/// Una fase legible del timeline: un step de la ceremonia con su span.
/// (El waterfall crudo de spans cuesta de leer; esto es la narrativa.)
#[derive(Debug, Clone)]
pub struct Phase {
    pub idx: usize,
    pub name: String,
    pub author: String,
    pub start_offset_ms: f64,
    pub duration_ms: f64,
}

/// La reconstruccion completa: todo lo que sobrevive al worker.
#[derive(Debug)]
pub struct Reconstruction {
    pub artifact: DecisionArtifact,
    pub spans: Vec<Span>,
    pub phases: Vec<Phase>,
    pub events: Vec<LogEvent>,
    pub worker_alive_now: Option<bool>,
    pub trace_duration_ms: f64,
}
