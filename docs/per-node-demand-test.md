# Per-Node Demand Routing Test

Objetivo: demostrar que una llamada externa puede seleccionar un nodo AWS concreto por identidad, y que el gateway puede arrancar solo la EC2 asociada a esa identidad si no esta levantada.

## Identidad

La identidad se mantiene igual en tres sitios:

| Perfil | Ruta gateway | Label Kubernetes | Tag AWS | Servicio real | IP real |
| --- | --- | --- | --- | --- | --- |
| `worker-1` | `/worker-1` | `underpass.ai/worker-index=1` | `aws-side:index=1` | `aws-echo-worker-1` | `192.168.1.244` |
| `worker-2` | `/worker-2` | `underpass.ai/worker-index=2` | `aws-side:index=2` | `aws-echo-worker-2` | `192.168.1.245` |

El gateway publico sigue siendo `192.168.1.243`.

## Flujo

```text
cliente
  -> http://192.168.1.243/worker-1/hostname
  -> demand-gateway profile worker-1
  -> comprueba nodeSelector underpass.ai/worker-index=1
  -> comprueba endpoints de service/aws-echo-worker-1
  -> si falta capacidad: scripts/ec2-pool.sh scale-tag aws-side:index 1 1
  -> worker inicia WireGuard hacia el endpoint local
  -> proxy a http://192.168.1.244/hostname
```

Para `worker-2` se repite el mismo patron con `aws-side:index=2`.

## Despliegue

> Historico: el etiquetado manual sobre node-names `ip-10-80-1-*` era de antes
> de los node-names estables (2026-06-26). Hoy los nodos se llaman
> `aws-worker-N` y el label lo pone Terraform/cloud-init en el join — sin paso
> manual. Este patron por identidad cubre SOLO el pool generico; el pool GPU
> (`aws-gpu-worker-N`, `node-pool=aws-gpu`) no tiene perfil en el gateway.

Terraform deja preparado el label en el `kubeadm join` y los tags AWS:

- `underpass.ai/worker-index=<n>`
- `underpass.ai/node-pool=aws-poc`
- `aws-side:index=<n>`

Aplicar los servicios por nodo y la configuracion del gateway:

```bash
helm upgrade --install underpass-labs charts/underpass-labs \
  -n underpass-labs \
  --take-ownership \
  --wait \
  --timeout 2m

kubectl -n underpass-labs rollout status deployment/aws-echo-worker-1
kubectl -n underpass-labs rollout status deployment/aws-echo-worker-2
```

Ejecutar el gateway:

```bash
AWS_REGION=eu-south-2 scripts/demand-gateway.py \
  --profiles-configmap underpass-labs/aws-demand-gateway-profiles
```

El gateway carga los perfiles desde el ConfigMap `underpass-labs/aws-demand-gateway-profiles`, generado por Helm desde `charts/underpass-labs/values.yaml`.

## Vida Minima

Cada perfil define cuanto vive el nodo desde la ultima invocacion del servicio:

```yaml
profiles:
  - name: worker-1
    idleSeconds: 300
  - name: worker-2
    idleSeconds: 300
```

Las llamadas a `/worker-1/hostname` renuevan solo la vida de `worker-1`. Las llamadas a `/worker-2/hostname` renuevan solo la vida de `worker-2`. Las llamadas a `/status` no renuevan el TTL.

## Prueba En Caliente

Servicios reales:

```bash
curl http://192.168.1.244/hostname
curl http://192.168.1.245/hostname
```

Gateway por perfil:

```bash
curl http://192.168.1.243/worker-1/status
curl http://192.168.1.243/worker-2/status
curl http://192.168.1.243/worker-1/hostname
curl http://192.168.1.243/worker-2/hostname
```

Resultado validado:

```text
/worker-1/hostname -> pod aws-echo-worker-1 en worker-index=1
/worker-2/hostname -> pod aws-echo-worker-2 en worker-index=2
```

## Prueba Desde Frio

Esta es la prueba completa de autolevantado. Hacerla con un solo nodo para limitar impacto:

```bash
AWS_REGION=eu-south-2 scripts/ec2-pool.sh stop-tag aws-side:index 1
```

Esperar a que Kubernetes quite capacidad del perfil:

```bash
curl http://192.168.1.243/worker-1/status
```

Cuando `target_ready=false`, invocar:

```bash
curl http://192.168.1.243/worker-1/wake
curl http://192.168.1.243/worker-1/hostname
curl -k https://aws-demand.underpassai.com/worker-1/hostname
```

Resultado esperado:

1. El gateway ejecuta `scripts/ec2-pool.sh scale-tag aws-side:index 1 1`.
2. Solo arranca la EC2 con `aws-side:index=1`.
3. La EC2 inicia WireGuard hacia `local_wireguard_endpoint`.
4. El nodo vuelve a `Ready`.
5. El endpoint `aws-echo-worker-1` vuelve a existir.
6. La llamada responde desde `aws-echo-worker-1`.

## Limitaciones Actuales

- Justo despues de parar una EC2, Kubernetes puede tardar en marcar el nodo como `NotReady`; durante esa ventana el gateway puede ver endpoints antiguos.
- El arranque desde frio requiere `local_wireguard_endpoint` configurado en Terraform y alcanzable desde AWS.
- Las EC2 creadas antes de configurar `local_wireguard_endpoint` deben reemplazarse para que el arranque frio use ese endpoint.
- El apagado automatico por idle ya es por perfil. Para una prueba controlada, se puede bajar `idleSeconds` temporalmente en Helm.
