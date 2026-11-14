# Kubernetes manifests

Applied in file-name order; the two `Job`s run once (`nanobus-init`, then
`nanoadmin-init`) and every other file is a Service + Deployment.

```sh
kubectl apply -f deploy/k8s/
```

- **Secrets first.** `02-secrets.yaml` holds the database URI, the shared internal
  token and the work library's cookie key. Replace every `change-me` before applying;
  `artifact-session-secret` must be the same value in every replica.
- **One database.** Every service points at the same `nanosec` database and writes
  only its own prefix. Splitting a module out later is a `mongodump --nsInclude`
  into a new database — the manifests need no change.
- **Replicas.** The stateless services run 3 (one rolling update plus one failure);
  `nanorunner` stays at 1 because the docker backend has to run one per node and the
  tunnel registry forwards to the replica that holds the connection.
- **No service is published.** The portal's nginx is the only entry point; it
  reaches the others over the cluster network.

## The agent workspace needs a shared volume

An agent's conversation and workspace live on a volume. With `ReadWriteOnce` a
replacement container can only start on the node that already has that volume, so a
node failure leaves the agent unschedulable. Point the provisioner at a storage class
that supports `ReadWriteMany` (NFS, CephFS, EFS, …):

```sh
nanoadmin config set runner.storage.accessMode ReadWriteMany
nanoadmin config set runner.storage.storageClass <your-rwx-class>
```

The provisioner reads both keys from the configuration (no restart needed) and
creates one PVC per user. Without them it falls back to `ReadWriteOnce`, which is
correct for a single node and wrong for a cluster.

## File descriptors

Every replica holds one descriptor per open tunnel, stream subscription and database
connection, and the default soft limit (1024) is reached long before the platform is
busy: the tunnel rules assume room for 65536. Docker Compose and Swarm take that from
the manifests (`ulimits.nofile`); Kubernetes has no such field, so it has to come from
the container runtime. Under containerd the default is inherited from the kubelet
process — set `LimitNOFILE=65536` (or higher) on the nodes' systemd unit, or add
`"default-ulimits": {"nofile": {"Name": "nofile", "Soft": 65536, "Hard": 65536}}` to
`/etc/docker/daemon.json` when Docker is the runtime. Without it a large deployment
fails with `too many open files` in the tunnel and stream logs, not with a crash.
