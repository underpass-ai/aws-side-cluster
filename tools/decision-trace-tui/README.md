# decision-trace-tui

Reconstruye una decision de agentes **despues de que el worker GPU que ayudo a
producirla haya sido apagado**. Es el artefacto-climax del experimento
*Disposable Compute, Persistent Evidence*: el computo es desechable, la
evidencia no.

Punto de entrada: el **decision artifact** (JSON persistido por el runner del
experimento). De el salen el `trace_id` (Tempo) y el `ceremony_id` (Loki); el
TUI junta las tres fuentes y ensenia en una pantalla el waterfall de spans, el
artefacto (claims/evidencia/escaped) y la timeline de eventos — con un pie que
dice si el worker sigue existiendo (via aws cli, best-effort).

```bash
TEMPO=$(kubectl -n monitoring get svc tempo -o jsonpath='{.spec.clusterIP}')
LOKI=$(kubectl -n monitoring get svc loki -o jsonpath='{.spec.clusterIP}')

cargo run -- decision.json --tempo http://$TEMPO:3200 --loki http://$LOKI:3100

# reconstruccion en texto plano (tests, CI, citas del articulo):
cargo run -- decision.json --tempo ... --loki ... --no-tui
```

Teclas: `q` salir · `tab` cambia el foco spans/logs · `↑↓` scroll.

Primera reconstruccion real (2026-07-04): la ceremonia `csi-typha-appeal-1`
del dia anterior — 8 spans, 78 eventos, `alive_now=false` (la g6 estaba
parada). La decision se reconstruyo integra sin el worker.
