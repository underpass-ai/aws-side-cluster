# Demand Gateway POC

`scripts/demand-gateway.py` es la primera pieza de scale-on-demand.

No es todavia un operador Kubernetes. Es un proceso local en el control-plane que:

1. recibe HTTP,
2. comprueba si el servicio objetivo tiene workers AWS listos,
3. si no hay capacidad, arranca las EC2 del perfil (`scale-tag` por tag; el
   perfil default sin tag usa `scale 2`),
4. espera a que nodos y endpoints esten listos,
5. proxya la peticion al servicio real.

**Alcance: SOLO el pool generico (t3.micro).** El worker GPU
(`aws-gpu-worker-1`, g6/L4) NO tiene perfil en el gateway: ni wake ni auto-stop
por idle — se arranca y para a mano (ver "Operacion Del Worker GPU" en el
README raiz). Ademas el reaper mide **HTTP a traves de ESTE gateway**: el
trafico LLM del `llm-gateway` in-cluster (ceremonias, vLLM) le es invisible.

## Flujo Por Defecto

```text
cliente
  -> 192.168.1.243/aws-demand-gateway
  -> proceso local :18080 en wrx80-node1
  -> si hace falta: EC2 scale up
  -> worker inicia WireGuard hacia el control-plane
  -> 192.168.1.242/aws-echo
  -> pods en workers AWS
```

## IPs

- Gateway de demanda: `192.168.1.243`
- Servicio real AWS echo: `192.168.1.242`
- Proceso local: `192.168.1.56:18080`

## Aplicar Service De Entrada

```bash
helm upgrade --install underpass-labs charts/underpass-labs \
  -n underpass-labs \
  --take-ownership \
  --wait \
  --timeout 2m
```

## Ejecutar En Primer Plano

(El idle por perfil del ConfigMap aplica igual en foreground; lo que tiene
`idle_seconds: 0` es el perfil default sin tag.)

```bash
AWS_REGION=eu-south-2 scripts/demand-gateway.py \
  --profiles-configmap underpass-labs/aws-demand-gateway-profiles
```

Con fichero local en vez de ConfigMap:

```bash
AWS_REGION=eu-south-2 scripts/demand-gateway.py \
  --profiles-file config/demand-gateway-profiles.json
```

## Probar

Estado:

```bash
curl http://127.0.0.1:18080/status
curl http://192.168.1.243/status
```

Proxy hacia el servicio real:

```bash
curl http://192.168.1.243/hostname
```

Forzar solo wake-up sin proxy:

```bash
curl http://192.168.1.243/wake
```

## Perfiles Por Nodo

El gateway enruta por perfiles definidos en el ConfigMap Helm `underpass-labs/aws-demand-gateway-profiles`. El fichero `config/demand-gateway-profiles.json` queda como fallback local.

Rutas actuales:

- `/worker-1/*` -> `aws-echo-worker-1`, node label `underpass.ai/worker-index=1`, AWS tag `aws-side:index=1`.
- `/worker-2/*` -> `aws-echo-worker-2`, node label `underpass.ai/worker-index=2`, AWS tag `aws-side:index=2`.

Ejemplos:

```bash
curl http://192.168.1.243/worker-1/status
curl http://192.168.1.243/worker-1/hostname
curl http://192.168.1.243/worker-2/status
curl http://192.168.1.243/worker-2/hostname
```

Cuando un perfil no esta listo, el gateway arranca solo la EC2 que coincide con su tag:

```bash
scripts/ec2-pool.sh scale-tag aws-side:index 1 1
scripts/ec2-pool.sh scale-tag aws-side:index 2 1
```

La prueba completa esta documentada en `docs/per-node-demand-test.md`.

## Vida Minima Del Nodo

Cada perfil tiene un `idleSeconds` gestionado por Helm en `charts/underpass-labs/values.yaml`.

Valor actual:

```yaml
profiles:
  - name: worker-1
    idleSeconds: 300
  - name: worker-2
    idleSeconds: 300
```

El gateway actualiza `last_request_at` solo en `/wake` y en llamadas proxied al servicio. Las consultas `/status` no alargan la vida del nodo. Cuando pasan `idleSeconds` desde la ultima invocacion, el reaper ejecuta:

```bash
scripts/ec2-pool.sh scale-tag aws-side:index <n> 0
```

**Verificado e2e 2026-07-03**: worker-1 despertado via `/worker-1/wake` a las
19:14:18, sin trafico posterior → `stopping` detectado a las 19:20:01 (clavado
a los 300s de idle + tick del reaper).

## Permisos

Para levantar desde frio, el proceso necesita:

- AWS CLI con permisos para arrancar/parar/describir las EC2 tageadas.
- `kubectl` admin o permisos para leer nodes/endpointslices.
- `DEMAND_GATEWAY_SYNC_COMMAND=scripts/wg-sync-ec2-endpoints.sh` en el unit: fija el endpoint WireGuard PC->EC2 (IP publica dinamica) en cada wake.
- `sudoers.d/aws-side-wg` (NOPASSWD `wg`): para que el gateway rootless (systemd `--user`) pueda hacer `sudo wg set`. Sin esto el sync falla y el nodo no rejoinea (regresion del paso a rootless, ya resuelta).

Las EC2 inician el tunel WireGuard hacia un endpoint local estable:

```hcl
local_wireguard_endpoint = "aws-vpc-wg.underpassai.com:51820"
```

Con ese endpoint, WireGuard aprende el peer remoto por roaming autenticado y el gateway solo observa Kubernetes.

Servicio persistente de usuario:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/aws-demand-gateway.service ~/.config/systemd/user/aws-demand-gateway.service
systemctl --user daemon-reload
systemctl --user enable --now aws-demand-gateway.service
```

## TLS y mTLS

El chart ya declara una entrada HTTPS interna sin cambiar el modelo de activacion:

- `aws-demand.underpassai.com` -> `192.168.1.241`, anunciado por MetalLB.
- TLS en `ingress-nginx` delante de `aws-demand-gateway`.
- Issuer de prueba en `underpass-labs` para emitir el certificado del gateway.
- mTLS en ingress preparado en valores Helm, desactivado por defecto para la prueba simple.
- Opcionalmente mTLS interno entre gateway y servicios si se introduce service mesh o sidecars.

## Limitaciones

- El primer request puede tardar minutos si los workers estan parados.
- Si el cliente no tolera ese tiempo, usar `/wake` y luego llamar al servicio real cuando este listo.
- No observa metricas todavia; solo reacciona a HTTP. (Desde 2026-07-03 existen
  metricas vLLM en Prometheus — la via natural para un futuro reaper del nodo
  GPU basado en uso real de inferencia, p.ej. `vllm:num_requests_running == 0`
  sostenido.)
- El apagado por idle es por perfil y se configura en Helm con `idleSeconds`.
- El pool GPU queda fuera del gateway (sin perfil): arranque/parada manual.
- Para arranque desde frio completo, `local_wireguard_endpoint` debe apuntar a un UDP/51820 alcanzable desde AWS.
- Si el DNS de `local_wireguard_endpoint` apunta a una web o a otro borde de red, ese borde debe reenviar `UDP/51820` hasta la workstation o actuar como relay WireGuard.
- Si `local_wireguard_endpoint` se configura despues de crear las EC2, las instancias deben reemplazarse para recoger la nueva configuracion de arranque.
