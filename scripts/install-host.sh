#!/usr/bin/env bash
# Renderiza las plantillas host-specific (sudoers + units systemd) para ESTA
# maquina y las instala. Las plantillas (.in) llevan @USER@/@HOME@/@REPO_DIR@
# para que el repo no contenga paths ni usuarios de nadie.
#
# Uso:
#   scripts/install-host.sh render    # solo renderiza en build/host/
#   scripts/install-host.sh check     # diff renderizado vs instalado (no toca nada)
#   scripts/install-host.sh install   # instala (pide sudo para sudoers y unit de sistema)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_DIR=$(pwd)
OUT="$REPO_DIR/build/host"
MODE="${1:-render}"

render() { # <plantilla> <salida>
  sed -e "s|@USER@|$USER|g" -e "s|@HOME@|$HOME|g" -e "s|@REPO_DIR@|$REPO_DIR|g" "$1" >"$2"
}

mkdir -p "$OUT"
render sudoers.d/aws-side-wg.in "$OUT/aws-side-wg"
render systemd/aws-demand-gateway.service.in "$OUT/aws-demand-gateway.service"
render systemd/aws-side-pc-net.service.in "$OUT/aws-side-pc-net.service"

case "$MODE" in
  render)
    echo "renderizado en $OUT:"
    ls -1 "$OUT"
    ;;
  check)
    rc=0
    # Units: byte a byte contra lo instalado.
    for pair in \
      "$OUT/aws-demand-gateway.service:$HOME/.config/systemd/user/aws-demand-gateway.service" \
      "$OUT/aws-side-pc-net.service:/etc/systemd/system/aws-side-pc-net.service"; do
      rendered="${pair%%:*}" installed="${pair##*:}"
      if [ ! -f "$installed" ]; then
        echo "AUSENTE: $installed (no instalado)"; rc=1
      elif diff -u "$installed" "$rendered" >/dev/null; then
        echo "OK: $(basename "$installed") == instalado"
      else
        echo "DIFIERE: $installed"; diff -u "$installed" "$rendered" || true; rc=1
      fi
    done
    # Sudoers: /etc/sudoers.d no es legible sin root; test funcional en su lugar.
    if sudo -n /usr/bin/wg show >/dev/null 2>&1; then
      echo "OK: regla sudoers activa (sudo -n wg show responde sin password)"
    else
      echo "FALLO: 'sudo -n wg show' no funciona (regla sudoers ausente o distinta)"; rc=1
    fi
    exit $rc
    ;;
  install)
    sudo install -m 0440 -o root -g root "$OUT/aws-side-wg" /etc/sudoers.d/aws-side-wg
    sudo visudo -cf /etc/sudoers.d/aws-side-wg
    install -D -m 0644 "$OUT/aws-demand-gateway.service" "$HOME/.config/systemd/user/aws-demand-gateway.service"
    sudo install -m 0644 "$OUT/aws-side-pc-net.service" /etc/systemd/system/aws-side-pc-net.service
    systemctl --user daemon-reload
    sudo systemctl daemon-reload
    echo "instalado. Habilitar si es primera vez:"
    echo "  systemctl --user enable --now aws-demand-gateway"
    echo "  sudo systemctl enable --now aws-side-pc-net"
    ;;
  *)
    echo "modo desconocido: $MODE (render|check|install)" >&2; exit 2
    ;;
esac
