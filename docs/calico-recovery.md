# Calico Change And Recovery Runbook

Objective: document and recover the Calico node address detection change required for AWS workers over WireGuard.

The cluster originally used the local-only interface selector `enp211s0`. That worked for the single local node, but EC2 workers do not have that interface. The current desired state is Kubernetes `NodeInternalIP`.

Current local state:

- Control-plane node: `wrx80-node1`
- Local node IP: `192.168.1.56`
- API endpoint in kubeconfig: `https://k8s.local:6443`
- `k8s.local` resolves locally to `192.168.1.56`
- Historical Calico autodetection: `interface=enp211s0`
- Current Calico autodetection: `kubernetes=NodeInternalIP`
- AWS worker node IPs are WireGuard IPs: `10.90.0.11`, `10.90.0.12`

## Preflight

```bash
scripts/calico-status.sh
scripts/calico-backup.sh
```

Expected healthy state:

- all active nodes are `Ready`
- `tigera status` resources are available
- `calico-node`, `calico-typha`, `calico-kube-controllers` are `Running`
- ingress service still exposes `192.168.1.241`

## Reapply Current Change

```bash
scripts/calico-use-nodeinternalip.sh
```

This script creates a backup first, applies the `NodeInternalIP` patch, waits for reconciliation, and prints the rollback command.

The patch it applies is:

```json
{
  "spec": {
    "calicoNetwork": {
      "nodeAddressAutodetectionV4": {
        "kubernetes": "NodeInternalIP",
        "interface": null,
        "canReach": null,
        "cidrs": null,
        "firstFound": null,
        "skipInterface": null
      }
    }
  }
}
```

## Rollback

If Calico or workloads degrade on the local-only cluster and AWS workers are not needed:

```bash
scripts/calico-rollback-enp211s0.sh
```

This restores:

```json
{
  "spec": {
    "calicoNetwork": {
      "nodeAddressAutodetectionV4": {
        "interface": "enp211s0"
      }
    }
  }
}
```

## Break Glass

If the current shell context cannot reach the API, run from the local control-plane host:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf scripts/calico-rollback-enp211s0.sh
```

If `k8s.local` resolution is suspect, verify:

```bash
getent hosts k8s.local
```

It should resolve to `192.168.1.56`.

## Success Criteria

For the hybrid cluster:

```bash
kubectl get nodes -o wide
kubectl get installation.operator.tigera.io default -o jsonpath='{.spec.calicoNetwork.nodeAddressAutodetectionV4}'
kubectl -n calico-system get pods -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
```

Expected:

- local node remains `Ready`
- AWS workers remain `Ready`
- Calico autodetection shows `{"kubernetes":"NodeInternalIP"}`
- Calico pods are `Running` and `calico-node` is `1/1` on each active node
- ingress still exposes `192.168.1.241`

## Notes From AWS Worker Join (historico, pre 2026-06-26)

> Desde los node-names estables (`--node-name aws-worker-N` en cloud-init,
> 2026-06-26) el replace reutiliza el mismo nombre de nodo y este escenario ya
> no ocurre en el flujo normal. Aplica solo a nodos anteriores a esa fecha o a
> renombrados de pool.

If EC2 workers are replaced, stale Kubernetes node objects may remain `NotReady` with the same WireGuard IPs. Delete stale nodes to avoid Calico IP conflicts:

```bash
kubectl delete node <old-node-name>
```

If a new `calico-node` reports that an old node is already using `10.90.0.11` or `10.90.0.12`, first confirm the old Kubernetes node object is gone, then recreate the affected `calico-node` pod:

```bash
kubectl -n calico-system delete pod <calico-node-pod>
```

## Modos De Fallo De Typha (verificados 2026-07-02/03)

Dos fallos reales de Calico sufridos y resueltos en este cluster; ninguno lo
cubre el runbook de arriba:

**1. Typhas "Running" stale en nodos AWS parados.** Al parar las EC2, sus pods
typha siguen figurando `Running` (estado stale del kubelet muerto). Si los N
replicas de typha caen todos en nodos parados, no hay typha vivo y
`calico-node` del nodo local queda `0/1` (felix aguanta con el ultimo estado,
pero no converge nada nuevo). Remediacion verificada:

```bash
kubectl -n calico-system delete pod <typhas-en-nodos-parados> --force --grace-period=0
# el ReplicaSet reprograma typha en un nodo vivo (wrx80) y calico-node vuelve a 1/1
```

**2. Contenedor typha huerfano reteniendo el puerto 5473.** Causa: cambiar
`default_runtime` de cri-o (p.ej. el toolkit del GPU Operator al flipar de
modo) con contenedores vivos. El estado de crun es por-runtime-root: el kill
del contenedor viejo delega en el runtime nuevo → "container does not exist" →
el proceso sobrevive reteniendo `:5473` (hostNetwork) → cada typha nuevo
crashea con `bind: address already in use` (cientos de restarts). Remediacion:
identificar el PID por cgroup (`ss -tlnpe` muestra `crio-<id>`), `sudo kill -9`,
force-delete del pod. Prevencion: tras tocar runtime/config de cri-o,
`systemctl restart crio` y **reciclar los pods hostNetwork** (typha), vigilando
"Killing container ... failed" en el journal. Cronologia completa del incidente
en `choreographer/runs/csi-typha-1.md` (seccion de puntuacion).
