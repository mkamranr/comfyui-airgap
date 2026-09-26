# Troubleshooting

Ordered roughly by how often each one bites. Most problems on an air-gapped
host trace back to one of the first three.

---

## Build-time (internet machine)

### `torch.cuda.is_available()` is False in the built image

Almost always a CUDA/driver/wheel mismatch.

```bash
# What does the TARGET host actually have?
nvidia-smi
```

Match `CUDA_IMAGE` and `TORCH_INDEX` in `.env` to it — they must agree with
each other *and* be supported by the target's driver:

| Target driver | `CUDA_IMAGE` | `TORCH_INDEX` |
|---|---|---|
| ≥ 525 (CUDA 12.x) | `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04` | `.../whl/cu128` |
| 525–535, conservative | `nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04` | `.../whl/cu124` |
| ≥ 530 | `nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04` | `.../whl/cu121` |

If it is False on the *build* machine only, the NVIDIA Container Toolkit is not
configured there:

```bash
docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
```

A second cause: something reordered the Dockerfile so `requirements.txt` is
installed before the CUDA torch wheel. ComfyUI lists a bare `torch`, which
resolves to the CPU build from PyPI. Torch must come first.

### A node has no pinned commit

```
FATAL: NodeC has no pinned commit in custom_nodes.txt
```

Intentional. Run `./scripts/pin_custom_nodes.sh`.

### `pin_custom_nodes.sh` cannot reach a URL

```
FATAL: cannot reach https://... — are you on the internet-connected machine?
```

Either you are on the wrong machine, behind a proxy, or the repo moved or went
private. Verify with `git ls-remote <url> HEAD`.

### A local node fails to install

```
[local-nodes] FAILURES:
  - Broken-Node: install.py failed
```

All failures are listed at once. Remove the node from `custom_nodes_local/`,
fix it, or accept them with `LOCAL_NODES_STRICT=0`. See
[CUSTOM-NODES.md](CUSTOM-NODES.md).

### A VFI checkpoint cannot be fetched

```
FATAL: could not fetch VFI checkpoint 'rife48.pth' for type 'rife'
```

The filename does not exist on any mirror. Check
`vfi_models/<type>/__init__.py` in the node repo for exact names.

### The build is enormous or very slow

Two usual causes. `custom_nodes_local/` containing downloaded checkpoints
(everything there uploads to the daemon each build). Or the controlnet_aux
prewarm, which is several GB — `PREWARM_CONTROLNET_AUX=0` skips it, at the cost
of preprocessor nodes failing offline.

---

## Verification (`verify_offline.sh`)

### Connection errors in the log scan

```
FAIL  network/import errors found:
      ConnectionError: HTTPSConnectionPool(host='huggingface.co', port=443)
```

**This is the script doing its job.** Something downloads lazily at runtime.
Identify the node from the traceback, add its asset to
`scripts/prewarm_models.sh`, rebuild, re-verify. Do not transfer the image
until this is clean.

### Fewer node types registered than expected

A custom node failed to import. Find it:

```bash
docker logs comfy-airgap-verify 2>&1 | grep -B2 -A10 "IMPORT FAILED"
```

Usually a missing Python dependency the node does not declare in its
`requirements.txt`.

### The server never comes up within the timeout

Large node sets genuinely take a while to import. Raise it:

```bash
BOOT_TIMEOUT=600 ./scripts/verify_offline.sh
```

If it still fails, run it in the foreground to see where it stops:

```bash
docker run --rm --network none --gpus all comfyui-airgap:v0.37.0
```

---

## Transfer

### `docker load` fails on a layer

Corrupt or truncated copy. Always verify before loading:

```bash
sha256sum -c SHA256SUMS
```

Re-copy if it fails. On FAT32, note the 4 GB per-file limit — use
`SPLIT_SIZE=3900M ./scripts/export_image.sh` and rejoin with
`cat comfyui-airgap-*.part-* > comfyui-airgap-v0.37.0.tar.zst`.

### `export_image.sh` refuses to run

It re-runs verification first and will not export a failing image. Fix the
failures. `SKIP_VERIFY=1` exists but exports a known-broken image — only use it
when you know exactly why.

---

## Runtime (air-gapped host)

### Startup stalls ~60s, then connection errors

Something is still reaching out. On a correctly built image this should not
happen — it means a lazy download slipped past verification.

```bash
docker compose logs | grep -iE "connection|timeout|resolve"
```

Add the asset to `prewarm_models.sh` and rebuild on the connected machine.

### ComfyUI-Manager stalls or floods the log

Its config is not in offline mode. Confirm:

```bash
docker exec comfyui grep network_mode /app/ComfyUI/user/__manager/config.ini
```

Expected: `network_mode = offline`. The entrypoint re-asserts this on every
start, so seeing anything else means `./user` is mounted from somewhere
unexpected, or the entrypoint was bypassed.

### Permission denied writing to `output/`

`PUID`/`PGID` do not match the directory owner:

```bash
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> .env
sudo chown -R "$(id -u):$(id -g)" models input output user
docker compose up -d
```

Note that `PUID`/`PGID` are *also* a build arg — they must match the target
host, not the build machine.

### A model does not appear in the UI

Check it is in the right subdirectory and visible inside the container:

```bash
docker exec comfyui ls -la /app/ComfyUI/models/checkpoints
```

If the host directory has files but the container does not, the bind mount is
wrong. If neither has them, the file is in the wrong subdirectory.

### A node-provided model vanished

Classic bind-mount shadowing. Baked files live in `/opt/comfy-defaults/models`
and the entrypoint seeds them into the mount at start:

```bash
docker exec comfyui ls -R /opt/comfy-defaults/models
docker compose restart          # re-runs seeding
```

If the file is in the defaults tree but not the mount, seeding failed —
check `docker compose logs | grep entrypoint`.

### Worker crashes on large models

`/dev/shm` exhaustion. Raise `shm_size` in `docker-compose.yml` (default 8gb).

### The container runs on CPU

The entrypoint warns at startup:

```
[entrypoint] WARNING: torch.cuda.is_available() is False — running on CPU.
```

Check the NVIDIA Container Toolkit on the host and the `deploy.devices` block
in `docker-compose.yml`:

```bash
docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
```

### `image not found` on `docker compose up`

The image was not loaded, or the tag does not match. This error is deliberate —
the run-side compose file has no `build:` key, so it fails honestly instead of
attempting a build that would hang on DNS.

```bash
docker images | grep comfyui-airgap     # what is loaded?
grep IMAGE_TAG .env                     # what is expected?
```

---

## Getting more detail

```bash
docker compose logs --tail=200 -f
docker exec comfyui python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
docker exec comfyui cat /opt/comfy-defaults/meta/comfyui.sha
docker exec comfyui cat /opt/comfy-defaults/meta/requirements.lock.txt
docker exec comfyui ls /app/ComfyUI/custom_nodes
curl -s http://localhost:8188/system_stats | python3 -m json.tool
```
