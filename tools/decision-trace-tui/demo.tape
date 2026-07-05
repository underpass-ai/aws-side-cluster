# VHS tape — GIF de la reconstruccion para el articulo.
# Uso:  cd tools/decision-trace-tui && vhs demo.tape
# (Requiere el binario release compilado y las IPs de Tempo/Loki del cluster;
#  regenerarlas si cambian: kubectl -n monitoring get svc tempo/loki.)

Output decision-trace-tui.gif

Set FontSize 15
Set Width 1800
Set Height 950
Set Theme "Dracula"
Set Padding 12

# Endpoints por env var y fuera de camara: las IPs del cluster no pintan
# nada en el GIF. (El binario lee TEMPO_URL/LOKI_URL via clap env.)
Hide
Type "export TEMPO_URL=http://10.106.230.90:3200 LOKI_URL=http://10.105.22.128:3100"
Enter
Type "clear"
Enter
Show

# Arranque: se ve el comando real (reproducibilidad para el lector)
Type "./target/release/decision-trace-tui ../../experiment/runs/exp-task-1-c-r1-131151/decision.json"
Sleep 1.5s
Enter
Sleep 4s

# Recorrido: foco a la evidencia y scroll hasta los veredictos del gate
Tab
Sleep 1.5s
Down@200ms 6
Sleep 2s
Down@200ms 8
Sleep 3s

# Volver arriba y dejar la pantalla completa un buen rato (el frame estrella)
Up@100ms 14
Tab
Sleep 5s

Type "q"
Sleep 500ms
