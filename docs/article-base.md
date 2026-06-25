# Base Para Articulo: Kubernetes Hibrido Con Workers EC2 Bajo Demanda

## Tesis

Un cluster Kubernetes personal o de laboratorio no tiene por que elegir entre todo local o todo cloud. En esta POC el control-plane queda en una workstation local con GPUs y se anaden workers baratos en AWS EC2 solo cuando hace falta capacidad externa.

La idea central es separar:

- Plano de control: estable, local, bajo control del operador.
- Capacidad elastica: nodos EC2 que se arrancan, se unen al cluster y se paran bajo demanda.
- Red de union: WireGuard, simple y barata.
- Bootstrap de datos: S3 con clase Glacier y descarga desde la propia EC2 usando IAM minimo.

## Estado Del Hito

Validado el 2026-06-25:

- Cluster local sigue funcionando.
- Dos EC2 `t4g.micro` se unen como workers Kubernetes.
- WireGuard conecta el control-plane local con los workers AWS.
- Calico funciona con los nodos externos.
- Se ejecuto un pod de prueba en AWS y se borro.
- Se desplego un servicio HTTP de prueba en `underpass-labs`, expuesto por MetalLB en `192.168.1.242`.
- Se anadio un gateway de demanda POC en `192.168.1.243` que comprueba capacidad, puede arrancar workers y proxya al servicio real.
- Las EC2 descargan un ZIP de S3 en primer arranque.
- El role de EC2 conserva solo permisos minimos sobre S3.

## Arquitectura

```text
Workstation local
wrx80-node1
192.168.1.56
10.90.0.1/24 WireGuard
Kubernetes control-plane
NVIDIA operator / GPUs locales
MetalLB / ingress local
        |
        | WireGuard sobre Internet
        |
AWS eu-south-2
VPC 10.80.0.0/16
Subnet publica 10.80.1.0/24
EC2 worker 10.90.0.11
EC2 worker 10.90.0.12
S3 bootstrap bucket
```

## Narrativa Sugerida

1. El problema inicial:
   - La workstation local ya tiene GPUs y un cluster Kubernetes funcionando.
   - Para ciertos workloads conviene poder anadir capacidad cloud temporal.
   - Mantener nodos cloud siempre encendidos no es deseable por coste.

2. Hipotesis:
   - Se puede mantener el control-plane local y unir workers EC2 por una red WireGuard.
   - Los workers pueden bootstrapearse solos con `cloud-init`, AWS CLI y `kubeadm join`.
   - El coste base puede quedarse casi solo en EBS si los workers estan parados.

3. Implementacion:
   - OpenTofu crea VPC, subnet publica, SG, IAM, S3 y EC2.
   - EC2 instala WireGuard, containerd, kubelet/kubeadm/kubectl.
   - EC2 descarga un ZIP desde S3 solo en primer arranque.
   - EC2 hace `kubeadm join` usando WireGuard.

4. Problemas reales:
   - Calico estaba fijado a una interfaz local.
   - `k8s.local` no resolvia desde AWS.
   - UFW bloqueaba API server y Typha desde el tunel.
   - El control-plane necesitaba retorno por `10.90.0.1` para hablar con kubelet.
   - Reemplazar EC2 deja nodos antiguos en Kubernetes si no se limpian.

5. Resultado:
   - Tres nodos `Ready`: uno local y dos AWS.
   - Calico `1/1` en todos.
   - Servicio HTTP expuesto por MetalLB, con backends corriendo en workers AWS.
   - Gateway HTTP inicial para transformar una llamada externa en wake-up + proxy hacia el servicio.

6. Siguiente fase:
   - Endurecer el gateway de demanda y prueba de arranque desde cero.
   - Scale-down cuando no haya pods pendientes o carga activa.
   - Sustituir `t4g.micro` por workers GPU especializados.
   - Enrutar inferencia por tipo de modelo/carga.

## Decisiones Tecnicas

### WireGuard En Vez De VPN Gateway

WireGuard evita coste fijo de AWS VPN Gateway y encaja con una POC. En este diseno, los workers EC2 inician el tunel hacia un endpoint local estable (`local_wireguard_endpoint`). El proceso de demanda solo arranca EC2 y espera a que Kubernetes vuelva a ver nodos/endpoints.

La condicion critica es que ese endpoint estable sea alcanzable por UDP desde AWS y termine realmente en la workstation o en un relay que llegue a ella. En la POC se separa el nombre de web del nombre de transporte: `aws-demand.underpassai.com` es HTTP/TLS interno por MetalLB; `aws-vpc-wg.underpassai.com` es solo WireGuard para unir la VPC con el cluster local. Un nombre DNS correcto no basta si resuelve a una web o a otro borde que no reenvia `UDP/51820`.

### Ingress Interno Con MetalLB

El endpoint HTTP visible para la prueba no publica una carga nueva en AWS. `aws-demand.underpassai.com` resuelve a una IP RFC1918 de la LAN (`192.168.1.241`), anunciada por MetalLB para `ingress-nginx`. El certificado de laboratorio lo emite un issuer propio del namespace de pruebas, suficiente para validar el flujo antes de endurecer confianza de clientes.

### Public IPv4 Dinamica En Vez De Elastic IP

Evita coste idle de Elastic IP. El endpoint estable que importa para el arranque desde frio es el endpoint WireGuard local, no la IP publica dinamica de cada worker.

### IAM Minimo

El role final de EC2 solo necesita:

- `s3:GetObject`
- `s3:RestoreObject`
- `s3:ListBucket` limitado al prefijo del objeto

SSM se probo para diagnostico, pero se retiro para mantener privilegios minimos.

### `t4g.micro` Como Minimo Practico

`t4g.nano` es mas barato, pero 512 MiB es muy justo para containerd, kubelet, Calico y una carga de prueba. Para esta POC `t4g.micro` fue el minimo razonable.

### `GLACIER_IR` Para La POC

Permite decir "clase Glacier" sin bloquear el primer arranque durante horas. Para `GLACIER` o `DEEP_ARCHIVE`, el bootstrap ya contempla `restore-object`.

## Comandos Clave

Crear o actualizar token de join:

```bash
KUBEADM_JOIN_ENDPOINT=192.168.1.56:6443 scripts/create-kubeadm-join-command.sh
```

Levantar workers:

```bash
AWS_REGION=eu-south-2 scripts/ec2-pool.sh scale 2
kubectl get nodes -o wide
```

Parar workers:

```bash
AWS_REGION=eu-south-2 scripts/ec2-pool.sh scale 0
```

Validar Calico:

```bash
kubectl -n calico-system get pods -o wide
```

Smoke test:

```bash
kubectl run aws-worker-smoke \
  --image=registry.k8s.io/pause:3.10 \
  --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"underpass.ai/node-pool":"aws-poc"}}}'

kubectl wait --for=condition=Ready pod/aws-worker-smoke --timeout=120s
kubectl get pod aws-worker-smoke -o wide
kubectl delete pod aws-worker-smoke
```

Servicio de prueba persistente, gestionado por Helm:

```bash
helm upgrade --install underpass-labs charts/underpass-labs \
  -n underpass-labs \
  --take-ownership \
  --wait \
  --timeout 2m

kubectl -n underpass-labs rollout status deployment/aws-echo
curl http://192.168.1.242/hostname
```

## Evidencia Del Hito

Nodos esperados:

```text
wrx80-node1                                  Ready  control-plane  192.168.1.56
ip-10-80-1-235.eu-south-2.compute.internal  Ready  worker         10.90.0.11
ip-10-80-1-72.eu-south-2.compute.internal   Ready  worker         10.90.0.12
```

Calico esperado:

```text
calico-node on wrx80-node1      1/1 Running
calico-node on AWS worker .11   1/1 Running
calico-node on AWS worker .12   1/1 Running
```

Servicio de prueba esperado:

```text
namespace: underpass-labs
deployment: aws-echo
replicas: 2/2
service: LoadBalancer 192.168.1.242
pods: uno en cada worker AWS
```

Gateway de demanda esperado:

```text
namespace: underpass-labs
service: aws-demand-gateway
service: LoadBalancer 192.168.1.243
backend local: wrx80-node1:18080
target real: http://192.168.1.242
```

## Ideas De Titulos

- Kubernetes hibrido casero: control-plane local y workers EC2 bajo demanda
- Uniendo una workstation GPU a AWS con WireGuard y kubeadm
- De workstation a cluster elastico: workers cloud baratos para Kubernetes local
- Preparando inferencia distribuida: Kubernetes local, EC2 y una red WireGuard

## Pendientes Para Fase 2

- Convertir el gateway POC en servicio persistente u operador.
- Politica de apagado segura cuando no haya pods activos en nodos AWS.
- Taints/tolerations por tipo de inferencia.
- Node pools GPU con AMIs y drivers adecuados.
- Cache de modelos por nodo.
- Metricas de coste por minuto de inferencia.
