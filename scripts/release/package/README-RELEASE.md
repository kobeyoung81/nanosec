# NanoSec — offline release

One release, packed from `versions.lock`: the nine service images, the rendered
compose file, an installer and a manifest with every digest. Nothing here chooses a
version — the lock did.

## Layout

```
nanosec-<release>/
├── images/<service>.tar          # docker save of the locked image
├── docker-compose.yml            # version tags already substituted
├── k8s/ · swarm/                 # manifests rendered from the same lock
├── .env.example                  # copy to .env and fill in
├── install.sh                    # load images, restart the stack
├── verify.sh                     # init containers, healthz, image labels
├── MANIFEST.txt                  # submodule commits, images, artifact digests
└── CHECKSUMS.sha256
```

## Install

```sh
tar -xzf nanosec-<release>.tar.gz && cd nanosec-<release>
./install.sh          # first run writes .env and stops
vi .env               # token, database URI, cookie secret
./install.sh          # loads the images and starts the stack
./verify.sh
```

The stack needs an external MongoDB; this bundle does not include one. Agent data
lives in the volume `nanosec-data-<user>`, which `install.sh` never removes.

## Upgrade and rollback

`install.sh` stops the previous stack (keeping volumes) and starts the new one,
because the init containers are `restart: "no"` and the services wait on them — a
plain `up -d` would not re-run a migration. Rolling back is the same command with the
previous release's bundle: only the services whose version differs are recreated.

## Notes

- Images are public on Docker Hub (`docker.io/kobeyoung81/<service>`), so an online
  host can pull them instead of loading tarballs.
- `nanorunner` mounts the host's Docker socket: it can provision containers, which is
  equivalent to root on that host. Nothing else in the stack mounts it.
- Migrations are applied at start-up by `admin-init`/`bus-init`; a release is only
  safe to roll back one version (see `docs/RELEASING.md` §8).
