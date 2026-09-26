# Architecture

Why this repository looks the way it does, and what each safeguard defends
against. If you only want to build and ship, [README.md](../README.md) is enough
— read this when something behaves unexpectedly, or before you add a node.

---

## The core problem

ComfyUI and its custom-node ecosystem reach the network in three distinct
phases, and only the first is obvious:

| Phase | Example | Caught by a normal Docker build? |
|---|---|---|
| Dependency install | `pip install -r requirements.txt` | Yes |
| Node install hook | Impact Pack's `install.py` fetching SAM | Yes, if you run `install.py` |
| **First node execution** | controlnet_aux fetching HF annotators | **No** |

The third category is what makes air-gapped ComfyUI deceptively hard. A build
that completes cleanly and a container that starts happily can still fail weeks
later, the first time somebody drags a ControlNet preprocessor onto the canvas.

The whole design follows from this: **move every network access to build time
on a connected machine, then prove none remain.**

---

## Five safeguards

### 1. `--disable-api-nodes`

From ComfyUI's own `comfy/cli_args.py`:

> *"Disable loading all api nodes. Also prevents the frontend from
> communicating with the internet."*

The second sentence is the important one. Without this flag the **browser UI**
itself makes outbound calls, independent of anything the Python process does.
Set in both the Dockerfile and `docker-compose.yml`. Do not remove it.

### 2. ComfyUI-Manager forced into offline mode

ComfyUI-Manager fetches its node database from GitHub *during ComfyUI startup*.
With no route out, that is a long stall followed by a wall of connection errors
before the server finally comes up — which reads to an operator as a hung or
broken container.

`config/manager-config.ini` sets `network_mode = offline`, and
`scripts/entrypoint.sh` re-asserts it on every start.

**Accepted trade-off:** Manager's install / update / uninstall buttons do
nothing useful offline. Adding a node means rebuilding on the connected
machine. This is a deliberate exchange of convenience for determinism.

### 3. Bind mounts shadow baked-in content

This is the subtle one, and the one most likely to waste an afternoon.

A bind mount **replaces** whatever the image had at that path. Mounting the
host's `./models` over `/app/ComfyUI/models` hides every file baked in there at
build time — including Impact Pack's SAM checkpoint and Impact Subpack's YOLO
models. The same applies to `./user` and ComfyUI-Manager's config.

```
image:   /app/ComfyUI/models/sams/sam_vit_b_01ec64.pth   ← baked at build
mount:   ./models  ->  /app/ComfyUI/models               ← hides all of it
result:  the file is simply gone at runtime
```

**The fix**, in two halves:

1. Node installers write into `/opt/comfy-defaults/models`, never
   `/app/ComfyUI/models`. The Dockerfile sets `COMFYUI_MODEL_PATH` to redirect
   them; both Impact Pack and Impact Subpack honour it.
2. `scripts/entrypoint.sh` copies the defaults into the mounted tree on every
   start with `cp -rn` (no-clobber).

`/opt/comfy-defaults` is never mounted over, so it always survives. The copy is
purely local, idempotent, safe across restarts, and never overwrites a file the
operator put there.

### 4. Lazy downloads, forced early

Install-time downloads are caught by the build. The lazy ones must be hunted
deliberately:

| Node | Downloads | When | Handled by |
|---|---|---|---|
| Impact Pack | `sam_vit_b_01ec64.pth` | install | `COMFYUI_MODEL_PATH` redirect |
| Impact Subpack | 3 YOLO models → `ultralytics/{bbox,segm}` | install | `COMFYUI_MODEL_PATH` redirect |
| controlnet_aux | HF annotator checkpoints | **first execution** | `prewarm_models.sh` |
| Frame-Interpolation | VFI checkpoints | **first execution** | `prewarm_models.sh` (`VFI_PREWARM`) |

`scripts/prewarm_models.sh` pulls both lazy sets at build time. For
Frame-Interpolation it walks the same three GitHub release mirrors the node
itself uses, so a wrong filename is a build-time error naming the checkpoint
rather than a runtime surprise. The mirrors genuinely matter — of the three
default checkpoints, none are on the first mirror and one is only on the third.

### 5. Offline env vars as tripwires

`HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `PIP_NO_INDEX=1` and friends are
not there to *restrict* the container — by that point it has no route out
anyway. They exist to change the **failure mode**.

Without them, a stray network call blocks on DNS for 30–60 seconds and looks
exactly like a hung process. With them, it fails instantly with a readable
error naming the library that tried. That difference is the difference between
a five-minute diagnosis and an afternoon.

---

## Build ordering

The Dockerfile's stage order is load-bearing:

```
1. apt packages                 root
2. create user, mkdir, chown    root   ← on EMPTY dirs
3. USER comfy ────────────────────────────────────┐
4. venv + pip upgrade                             │
5. clone ComfyUI (pinned tag)                     │  everything below
6. torch from the CUDA wheel index                │  runs unprivileged and
7. ComfyUI requirements.txt                       │  already correctly owned
8a. local nodes  (custom_nodes_local/)            │
8b. pinned nodes (custom_nodes.txt)               │
9. prewarm lazy assets                            │
10. pip freeze -> lockfile                        │
11. ENV offline switches ─────────────────────────┘
```

Three ordering decisions worth stating explicitly:

**The user is created before any heavy content exists.** A `chown -R` applied
after ~10 GB of installs rewrites every file into a new layer and very nearly
doubles the image size. Creating the user first and building as that user means
no recursive chown is ever needed.

**Torch is installed before `requirements.txt`.** ComfyUI's requirements list a
bare `torch`, which resolves to the CPU-only build from PyPI. Installing the
CUDA build first means the later requirement is already satisfied. Get this
backwards and you get a silently CPU-only image — it starts fine, it just
generates at a fiftieth of the speed.

**Local nodes install before pinned ones.** A node already present is skipped by
`install_custom_nodes.sh` with a warning, so your working copy wins over our
pin. See [CUSTOM-NODES.md](CUSTOM-NODES.md).

**Offline env vars come last.** Every step above them legitimately needs the
network.

---

## Two compose files, on purpose

`docker-compose.yml` (the one on the air-gapped host) has **no `build:` key**.

This is structural, not stylistic. If the run-side file could build, then a
mistyped tag or a missing image on the target would silently trigger a build
that hangs on DNS. With no build section, the same mistake produces an
immediate, honest `image not found`.

| File | Machine | Has `build:` |
|---|---|---|
| `docker-compose.build.yml` | internet | yes |
| `docker-compose.yml` | air-gapped | **no** |

---

## What lives where

```
/opt/venv                        python environment (PATH points here)
/opt/comfy-defaults/models       node-installed models, seeded into the mount
/opt/comfy-defaults/user         default user config incl. Manager offline ini
/opt/comfy-defaults/meta         comfyui.sha, requirements.lock.txt
/app/ComfyUI                     the application
/app/ComfyUI/custom_nodes        nodes (baked, never mounted)
/app/ComfyUI/models              ← bind mount, seeded at start
/app/ComfyUI/{input,output,user} ← bind mounts
/app/cache/{huggingface,torch}   caches, pointed at by HF_HOME / TORCH_HOME
```

Note that `custom_nodes` is **not** bind-mounted. Node code ships in the image
and is versioned with it; that is what makes a rollback a single tag change.

---

## Why models are not baked in

Models are bind-mounted and transferred as a separate payload. Baking them in
would mean:

- a 50–100+ GB image instead of ~10–15 GB
- `docker save` and the transfer becoming genuinely painful
- a full rebuild and re-transfer to add one checkpoint

The image is the *software*, versioned and replaceable. The models are *data*,
long-lived and independently managed. Keeping them separate means adding a
checkpoint on the air-gapped host is a file copy and a restart, not a build.
