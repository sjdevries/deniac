# `ai.model-store` — shared AI model store (substrate)

A **filesystem substrate** that all local AI aspects mount, so model
weights are stored **once**, downloaded **once**, and backed up **once** —
the deniac take on the [Stability Matrix](https://stabilitymatrix.com)
"shared model root" pattern (which shares models/LoRAs/GANs across
ComfyUI / A1111 / Forge).

This aspect owns the substrate — a shared group, a directory tree under
`root` following a fixed subdir convention, and the shared HuggingFace
cache location. It runs **no service**. Consumers (`ai.gufo`,
`ai.comfyui`, future engines) point their model paths into it and
bind-mount read-only.

> The design rationale — the two-layer model (shared root +
> content-addressed `HF_HOME`), the per-engine consumption table, and the
> GGUF convergence point — is covered in this doc: see
> [The two layers](#the-two-layers-how-sharing-actually-works) and
> [Caveats](#caveats).

## ⚠ Tier — "precious bulk" (archive), not cache

Model weights are treated as **precious**: re-download is **not
guaranteed** (platform concentration — the NVIDIA→HuggingFace close is
pending H1 2027; plus model takedowns / re-licensing / link-rot). So
the store is **BACKUP-tier**: checksummed, off-site, ideally mirrored
off-platform. But it is large, so it stays **off the hot impermanent
`/persist` root**.

**Provision `root` on a backed-up mount.** This aspect creates the
directory structure; it cannot enforce the mount or the backup — that is
host-level.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Provision the store (group + dir tree + HF cache dir). Inert by default. |
| `root` | `/var/lib/ai-models` | Shared store root — put this on a **backed-up** mount, not tmpfs / hot `/persist`. |
| `group` | `aimodels` | Shared group that owns the store; service users join it for read access. |
| `hfCache` | `<root>/.hf-cache` | Shared `HF_HOME` — content-addressed download dedup. Follows a `root` override. |
| `subdirs` | `[ llm image video audio loras vae text_encoders gguf ]` | The fixed layout convention (superset of ComfyUI's names). |
| `paths` | *(derived, read-only)* | Map of subdir name → absolute path, for consumers (`paths.llm`, `paths.image`, …). |

## Usage

```nix
# your den config
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

den.aspects.igloo.includes = [ deniac.ai.model-store ];

# provision the substrate:
den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;

# consumers point into it via the derived paths:
den.aspects.igloo.nixos.deniac.ai.gufo.modelsDir =
  den.aspects.igloo.nixos.deniac.ai.model-store.root;   # mounts whole store as /models
# or a single subdir:
#   ... = den.aspects.igloo.nixos.deniac.ai.model-store.paths.llm;
```

### ComfyUI wiring

ComfyUI reads its subdir names via `extra_model_paths.yaml` (or
`COMFYUI_MODEL_PATH`). Point those at the store's subdirs so ComfyUI's
`checkpoints` / `loras` / `vae` / `text_encoders` / `diffusion_models`
map onto the shared tree. (This is a `ai.comfyui`-side change; the store
just provides the paths.)

## The two layers (how sharing actually works)

1. **Shared model root** — one tree, each tool pointed in via its own
   hook (gufo `--model` path; ComfyUI `extra_model_paths.yaml`).
2. **Shared `HF_HOME` cache** (`hfCache`) — `hf download` is
   content-addressed, so the same weights are fetched **once** across
   every tool. Tools that read files by path (gufo) are populated from
   the cache via **hardlinks** (`cp -al`): same bytes, many names, one
   copy on disk.

**Download flow:**
```sh
# 1. fetch into the shared content-addressed cache
HF_HOME=/var/lib/ai-models/.hf-cache hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  --include "UD-Q4_K_XL/*" "MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
# 2. hardlink into the store subdir (zero byte duplication)
cp -al <cache-blob> /var/lib/ai-models/llm/<name>.gguf
```

## Preservation (the "gold" part)

Because re-download is not guaranteed, capture the preservation record
**while the upstream is still cross-checkable**:

- **Record provenance + per-file SHA256** at download time (repo,
  revision, file hashes). If the source vanishes, the manifest is the
  only proof of what you have and that it's authentic.
- **Back it up off-site** (NAS / second disk / object storage).
- **Mirror the truly precious** off-platform (IPFS / Arweave) — the
  open-weight community already does this against platform risk.
- **Licence check** — permissive weights (Apache/MIT) are legally
  mirrorable; some "open" weights carry usage restrictions.

The content-addressed HF cache already computes the SHA256s — the
manifest step is largely reading them off the cache.

## Caveats

- **Cross-format never dedups** — GGUF / `.hgn` / safetensors are
  different bytes; running gufo *and* halogen means holding both.
- **Hardlinks need one filesystem** — the HF cache and the store must be
  on the same fs for `cp -al` to link (not copy); `reflink` relaxes
  this on CoW filesystems.
- **Store-sharing ≠ co-residency** — sharing the store does not let two
  engines be resident in RAM at once (unified-memory contention is
  orthogonal; see the `ai.gufo` / `ai.comfyui` notes).
- **Subdir-layout mismatch** — ComfyUI's names are opinionated; bridge
  them with `extra_model_paths.yaml`.

## Provenance

Design adapted from the Stability Matrix shared-model-root pattern and
the per-engine model-consumption facts verified against gufo
(`docs/SERVER.md`, `docs/CLI.md`), comfyui-nix (`COMFYUI_MODEL_PATH`),
and the HuggingFace Hub content-addressed cache (2026-10-04).

## Tests

`flake.tests.ai-model-store` (denTest, host `igloo`): namespace export
shape; inert-by-default (no group, no store tmpfiles rules); enabled
(shared group + tmpfiles rules for root, every subdir, and the HF cache);
custom `root` respected with `hfCache` following it; derived `paths`
attrset maps each subdir to its absolute path.
