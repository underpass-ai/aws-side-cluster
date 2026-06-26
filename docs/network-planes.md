# Network Planes

Fecha: 2026-06-25

## Separacion De Nombres

La POC usa dos planos distintos:

- Web/HTTP: `aws-demand.underpassai.com`
- Red VPC/WireGuard: `aws-vpc-wg.underpassai.com:51820`

`aws-demand.underpassai.com` es la entrada HTTP interna del laboratorio. Resuelve a una IP RFC1918 anunciada por MetalLB para `ingress-nginx` y sirve el gateway de demanda con TLS.

`aws-vpc-wg.underpassai.com` es un endpoint de red, no una web. Las EC2 lo usan para iniciar WireGuard hacia el cluster local. Vive en una zona Route53 **privada** (VPC-scoped, `terraform/dns.tf`); **no** esta en la zona publica, asi que no toca la web. Detalle en `docs/network-topology.md`.

## Regla Operativa

El endpoint WireGuard debe terminar en uno de estos sitios:

1. Router de la LAN con port-forward `UDP/51820 -> 192.168.1.56:51820`.
2. Relay WireGuard que tenga ruta real hacia `192.168.1.56`.
3. La propia workstation si tiene IP publica directa.

No debe apuntar a la web publica salvo que esa maquina haga de relay o reenvie `UDP/51820`.

## Configuracion Terraform

```hcl
local_wireguard_endpoint = "aws-vpc-wg.underpassai.com:51820"
```

Las EC2 solo leen este valor en `user_data`. Despues de cambiarlo hay que reemplazar las instancias para una prueba de arranque frio real.

## Comprobacion

Antes de reemplazar workers:

```bash
dig +short aws-vpc-wg.underpassai.com
sudo tcpdump -ni any udp port 51820
```

Durante la prueba, la captura local debe ver paquetes UDP cuando una EC2 arranca. Si sigue en `0 packets captured`, el problema esta antes de Kubernetes y antes del proceso de demanda.
