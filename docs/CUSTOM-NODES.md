# Managing custom nodes

Two ways to get nodes into the image. Both run at build time on the
internet-connected machine; neither needs the network on the target.

| | `custom_nodes.txt` | `custom_nodes_local/` |
|---|---|---|
| Source | public git repo | a folder on your disk |
| Version pinning | exact commit SHA | none — ships as-is |
| Reproducible rebuild | yes | only if the folder is unchanged |
| Best for | public nodes | private, modified, or unreleased nodes |
| Wins a name collision | no | **yes** |

**Prefer `custom_nodes.txt`** for anything with a public repo. Use the local
folder for what it cannot express.

---

## Pinned nodes (`custom_nodes.txt`)

Format is one node per line: a git URL, whitespace, and a full commit SHA.
Blank lines and `#` comments are ignored.

```
https://github.com/rgthree/rgthree-comfy.git    449c58fcdd612f7733e54c51f6758ead63fa180b
```

### Adding one

```bash
echo "https://github.com/author/SomeNode.git" >> custom_nodes.txt
./scripts/pin_custom_nodes.sh      # resolves the missing SHA
./scripts/build.sh
./scripts/verify_offline.sh        # catches any lazy download the node makes
```

`pin_custom_nodes.sh` fills in only missing pins and leaves existing ones
alone. `--update` re-pins everything to current HEAD — a deliberate act that
changes what ships, so rebuild and re-verify afterwards.

### Why pinning is mandatory

`install_custom_nodes.sh` treats a missing SHA as a **fatal build error**. An
unpinned `HEAD` means two builds of the "same" image can contain different code
with different runtime download behaviour. On a connected machine that is an
annoyance; across an air gap it is a failure you cannot debug from the
affected side.

### What the installer does per node

1. `git clone --filter=blob:none`, then `checkout <sha>`
2. `rm -rf .git` — dead weight, and it stops anyone `git pull`-ing on the target
3. `pip install -r requirements.txt`, if present
4. run `install.py`, if present — this is where nodes fetch their models, and
   exactly what we want happening while the network still exists

Any failure aborts the build.

---

## Your own folder (`custom_nodes_local/`)

Copy in the contents of an existing ComfyUI `custom_nodes` directory:

```bash
rsync -a --delete \
  --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  /path/to/ComfyUI/custom_nodes/  ./custom_nodes_local/
```

That is the whole step — the build picks it up automatically.

Expected layout, exactly as ComfyUI stores it:

```
custom_nodes_local/
├── My-Private-Node/
│   ├── __init__.py
│   └── requirements.txt
└── Another-Node/
    └── __init__.py
```

### Behaviour

- Installed **before** pinned nodes, and **wins** a name collision. A matching
  `custom_nodes.txt` entry is skipped with a warning, so an existing
  `ComfyUI-Manager` in your folder simply supersedes ours.
- `requirements.txt` is pip-installed and `install.py` is run for each node.
- `.git`, `.github`, `__pycache__` and `*.pyc` are stripped on the way in.
- `*.disabled` folders are skipped — that is how ComfyUI-Manager disables a node.
- Loose files (`*.py.example`) are copied through.

### Failure handling

Failures are **collected and reported together** at the end of the build rather
than aborting on the first one. An inherited `custom_nodes` folder often has
several stale nodes, and finding them one build at a time is miserable.

```
[local-nodes] FAILURES:
  - Broken-Node: install.py failed
  - Old-Node: pip install -r requirements.txt failed
```

Strict by default (the build aborts). To accept them as warnings:

```bash
LOCAL_NODES_STRICT=0 ./scripts/build.sh
```

### Two caveats

**Build context size.** Everything in the folder uploads to the Docker daemon
on every build. Node folders containing downloaded checkpoints can be many GB.
That is usually what you want for an air-gapped image — those weights would
otherwise be a runtime download — but expect a slow "sending build context".

**No version pinning.** Whatever is in the folder ships. There is no record of
what commit it came from.

---

## Lazy downloads: the thing to actually watch for

A node that downloads its models inside `install.py` is handled automatically.
A node that downloads them the **first time it executes** is not, and is
invisible until the box is offline.

Two nodes in the default set behave this way, and both are pre-warmed:

### controlnet_aux

Pulls annotator checkpoints from HuggingFace into its own `ckpts/` directory.
Controlled by `PREWARM_CONTROLNET_AUX` (default `1`) and `PREWARM_HF_REPOS`
(default `lllyasviel/Annotators`, which covers most preprocessors).

A preprocessor that pulls from a different repo needs its repo id added:

```bash
PREWARM_HF_REPOS="lllyasviel/Annotators some-org/other-repo" ./scripts/build.sh
```

This is several GB. Set `PREWARM_CONTROLNET_AUX=0` only if you will never use a
preprocessor node.

### ComfyUI-Frame-Interpolation

Fetches VFI checkpoints from GitHub releases into `ckpts/<model_type>/`.
Controlled by `VFI_PREWARM`, a space-separated list of `<model_type>:<filename>`
pairs:

```bash
VFI_PREWARM="rife:rife47.pth rife:rife49.pth film:film_net_fp32.pt"
```

Model types are the directory names under the node's `vfi_models/`: `rife`,
`film`, `cain`, `amt`, `gmfss_fortuna`, `ifrnet`, `ifunet`, `m2m`, `sepconv`,
`stmfnet`, `flavr`, `eisai`, `xvfi`, `atm`, `momo`.

The default (~172 MB) covers RIFE and FILM. **A checkpoint not listed cannot be
fetched later.** Exact filenames are in the node's
`vfi_models/<type>/__init__.py`; a wrong name is a build-time error.

### Finding ones we have not anticipated

This is what `./scripts/verify_offline.sh` is for. It runs the image under
`--network none` and scans the log for connection errors. When a new node
misbehaves you will see it there:

```
FAIL  network/import errors found:
      ConnectionError: HTTPSConnectionPool(host='huggingface.co', port=443)
      ^ each of these is something the air-gapped host will also hit.
```

Add the missing asset to `scripts/prewarm_models.sh`, rebuild, re-verify.

---

## The default node set

| Node | Purpose | Download behaviour |
|---|---|---|
| ComfyUI-Manager | node management (offline mode) | — |
| ComfyUI-VideoHelperSuite | video / image-sequence IO | needs `ffmpeg` (installed) |
| ComfyUI-Impact-Pack | detailer & segmentation | SAM at install |
| ComfyUI-Impact-Subpack | Ultralytics detector provider | 3 YOLO models at install |
| comfyui_controlnet_aux | ControlNet preprocessors | **lazy** — pre-warmed |
| ComfyUI_essentials | image / mask / text utilities | — |
| ComfyUI-KJNodes | masking, batching, scheduling | — |
| rgthree-comfy | workflow quality of life | — |
| was-node-suite-comfyui | large general-purpose suite | — |
| ComfyUI-Frame-Interpolation | RIFE / FILM / GMFSS interpolation | **lazy** — pre-warmed |

Remove any you do not need — every node is build time, image size, and one more
thing that can fail offline.
