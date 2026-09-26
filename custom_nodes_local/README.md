# custom_nodes_local/

Drop the contents of an existing ComfyUI `custom_nodes` directory in here and
every node folder is baked into the image at build time.

```bash
# from the machine that has your working ComfyUI install:
rsync -a --delete \
  --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  /path/to/ComfyUI/custom_nodes/  ./custom_nodes_local/
```

Layout expected — one directory per node, exactly as ComfyUI stores them:

```
custom_nodes_local/
├── My-Private-Node/
│   ├── __init__.py
│   └── requirements.txt
└── Another-Node/
    └── __init__.py
```

## Behaviour

- Installed **before** the git-pinned nodes, and **wins** on a name collision —
  a matching entry in `custom_nodes.txt` is skipped with a warning.
- `requirements.txt` is pip-installed and `install.py` is run for each node,
  at build time, while the network is still available.
- `.git`, `.github`, `__pycache__` and `*.pyc` are stripped on the way in.
- Folders ending in `.disabled` are skipped (that is how ComfyUI-Manager
  disables a node).
- Failures are collected and reported together at the end of the build.
  Override with `LOCAL_NODES_STRICT=0` to accept them as warnings.

## Two things to watch

**Build context size.** Everything here is uploaded to the Docker daemon on
every build. If your node folders contain downloaded checkpoints (`ckpts/`,
`models/`) that can be many GB. That is usually what you want for an air-gapped
image — those weights would otherwise be a runtime download — but expect a slow
`Sending build context` step.

**These nodes are not version-pinned.** Unlike `custom_nodes.txt`, whatever is
in this folder is what ships. For anything with a public git repo, prefer
adding it to `custom_nodes.txt` with a pinned SHA so rebuilds stay reproducible.
Use this folder for private, modified, or unreleased nodes.
