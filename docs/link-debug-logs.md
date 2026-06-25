# Link Debug Logs

Fecha de la prueba: 2026-06-25

## Resumen

La ruta HTTPS interna funciona. El activador levanta la EC2 correcta. La EC2 arranca, carga WireGuard y queda esperando al API local `192.168.1.56:6443`.

La prueba de enlace local muestra `0 packets captured` en UDP/51820 mientras la EC2 estaba encendida. Por tanto, el bloqueo esta antes de Kubernetes: el trafico UDP/51820 no llega desde AWS a la maquina local.

El endpoint usado inicialmente resolvia correctamente, pero a la IP publica usada por la web. Si esa IP no reenvia `UDP/51820` hasta `192.168.1.56`, WireGuard termina contra el borde equivocado y la workstation no ve ningun paquete.

Decision posterior: separar nombres. `aws-demand.underpassai.com` queda para HTTP/TLS interno por MetalLB; `aws-vpc-wg.underpassai.com` queda reservado para el transporte WireGuard/VPC.

## Vista Desde EC2

Instancia probada:

```text
worker-1: i-07c16d62cc647716e
public_ip during test: 51.49.120.202
wg_address: 10.90.0.11
```

Fragmentos relevantes de consola EC2:

```text
wireguard: WireGuard 1.0.0 loaded. See www.wireguard.com for information.
kubeadm-join.sh[1644]: Waiting for kube-apiserver at 192.168.1.56:6443
kubeadm-join.sh[1644]: Waiting for kube-apiserver at 192.168.1.56:6443
kubeadm-join.sh[1644]: Waiting for kube-apiserver at 192.168.1.56:6443
kubeadm-join.sh[1644]: Waiting for kube-apiserver at 192.168.1.56:6443
```

Lectura: la EC2 completa el arranque base y entra en el join, pero no alcanza el API local por el enlace.

## Vista Desde AWS/VPC

La instancia tenia red publica normal:

```text
state: running
private_ip: 10.80.1.143
public_ip: 51.49.120.202
subnet: subnet-06e142a3f3d96f502
vpc: vpc-0ece93c68a3d23f84
status checks: ok / passed
```

La subnet tenia ruta `0.0.0.0/0` hacia Internet Gateway y el security group permitia salida completa. Desde el punto de vista de AWS, la EC2 podia salir a Internet; el problema no era una ruta de VPC ni una regla de salida.

## Vista Desde La Maquina Local

WireGuard local activo:

```text
interface: aws-workers
  listening port: 51820

peer: M9beMByFaT8Ag4ethFHK1P6ui7a4vo4i/qwDYBknih4=
  allowed ips: 10.90.0.11/32

peer: 7eJlnE7p7hhrO4ePDG0R7M/sID4QmqiHOgPX9dJAqFM=
  allowed ips: 10.90.0.12/32
```

Captura local durante la espera de la EC2:

```text
tcpdump -ni any udp port 51820 -c 5
0 packets captured
0 packets received by filter
0 packets dropped by kernel
```

Lectura: durante la prueba no llego ningun paquete UDP/51820 a la maquina local.

## Vista Desde Kubernetes

Eventos del namespace de prueba:

```text
FailedScheduling pod/aws-echo-worker-1-565b5c7cdc-9zdcr
0/3 nodes are available:
1 node(s) didn't match Pod's node affinity/selector,
2 node(s) had untolerated taint {node.kubernetes.io/unreachable: }.
```

Lectura: Kubernetes no ve un worker AWS listo, por lo que el pod fijado al worker queda pendiente.

## Vista TLS/Ingress

Prueba HTTPS:

```text
aws-demand.underpassai.com resolved to 192.168.1.241
SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
issuer: CN=underpass-labs-demand-ca
HTTP/2 200
```

Lectura: TLS e ingress interno por MetalLB funcionan. El fallo no esta en TLS.

## Estado Final De EC2

Tras la prueba:

```text
i-07c16d62cc647716e  worker-1  stopped
i-03a32b16cf85bdfab  worker-2  stopped
```

## Siguiente Accion

Configurar uno de estos caminos:

1. Si la IP publica es el router de la LAN, configurar NAT/port-forward:

```text
UDP 51820 -> 192.168.1.56:51820
```

2. Si la IP publica pertenece a la maquina de la web, hacer que esa maquina actue como relay WireGuard o que reenvie `UDP/51820` hacia la workstation por una ruta real.

3. Alternativamente, apuntar `aws-vpc-wg.underpassai.com` a una IP publica que termine directamente en el router de la LAN donde vive `192.168.1.56`.

Despues, repetir:

```bash
curl -k https://aws-demand.underpassai.com/worker-1/wake
kubectl get nodes -o wide
curl -k https://aws-demand.underpassai.com/worker-1/hostname
```
