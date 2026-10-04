# `deniac-model-add` — model URL → `model-store` config entry

A small CLI that turns a **browsed** model URL into a declarative
[`ai.model-store.models`](./ai-model-store.md) entry. The workflow is
deliberate: **you browse in the real CivitAI / HuggingFace site** (that
*is* the GUI — search, previews, ratings, trigger words), copy the model
URL, and this resolves the **download URL + SHA256** and prints a Nix
attrset to paste into your host's `models` list.

It does **not** download the whole file to hash it — CivitAI's API and
HuggingFace's tree API both publish the SHA256, so resolution is fast
even for tens-of-GB checkpoints.

## Usage

```sh
nix run .#deniac-model-add -- <url> [options]
```

| Option | Meaning |
| --- | --- |
| `--subdir S` | Store subdir (`llm`/`image`/`video`/`audio`/`loras`/`vae`/`text_encoders`/`gguf`). Default: inferred from the model type (CivitAI) or `llm` (HF). |
| `--name N` | Filename in the store (default: the source's filename). |
| `--file F` | Pick a specific file by name (multi-file versions/repos). |
| `--source S` | `auto` (default) / `civitai` / `huggingface` / `generic`. |
| `-h`, `--help` | Usage. |

## Sources & what each resolves

- **CivitAI** — accepts
  `civitai.com/models/<id>?modelVersionId=<v>`,
  `civitai.com/api/v1/model-versions/<v>`, or a bare
  `civitai.com/models/<id>` (latest version). Reads the primary file's
  `downloadUrl` + `hashes.SHA256` (hex→SRI) + `type` (→ subdir) +
  trigger words. **No download.**
- **HuggingFace** — a `…/resolve/<rev>/<file>` URL. Reads the file's
  `lfs.oid` (SHA256) from the tree API. **No download.** Falls back to
  `nix-prefetch-url` for non-LFS files.
- **Generic** — any direct file URL; hashed via `nix-prefetch-url` +
  `nix hash convert --to sri`.

## Example

```sh
$ nix run .#deniac-model-add -- https://civitai.com/api/v1/model-versions/1
# CivitAI: Model / SD 1.5  (trigger: comicmay)
{ source = "civitai";
  subdir = "image";
  name = "superheroDiffusion_v1.ckpt";
  url = "https://civitai.com/api/download/models/1?fileId=472";
  sha256 = "sha256-ysCpcs+kDP5E48ANOkiNy+NGaL8pHdYkXXAmYkdkOnw="; }
```

Paste that into a host:

```nix
den.aspects.myhost.nixos.deniac.ai.model-store.models = [
  # CivitAI: Model / SD 1.5  (trigger: comicmay)
  { source = "civitai"; subdir = "image"; name = "superheroDiffusion_v1.ckpt";
    url = "https://civitai.com/api/download/models/1?fileId=472";
    sha256 = "sha256-ysCpcs+kDP5E48ANOkiNy+NGaL8pHdYkXXAmYkdkOnw="; }
];
```

`nixos-rebuild` then fetches it (or pulls it from a peer substituter) and
symlinks it into the store tree.

## Auth (gated models)

Export the source's token before running:

```sh
export CIVITAI_API_KEY=…   # https://civitai.com → account → API Keys
export HF_TOKEN=…          # https://huggingface.co → settings → Access Tokens
```

They are sent as `Authorization: Bearer …` headers to the API/download
but are **never written into the emitted entry** — the entry is public
config. In the fleet these come from **sops-nix / agenix** (the secret
wiring is a tracked TODO; see `research/ai-model-store-sharing.md` §8.4).

## Implementation

- `modules/tools/deniac-model-add.pl` — the logic (perl: `JSON::PP` +
  `MIME::Base64`; `curl` for HTTP; `nix-prefetch-url` / `nix hash
  convert` for the generic path).
- `modules/tools/deniac-model-add.nix` — the flake package
  (`writeShellApplication`, `perl`+`curl`+`nix` on PATH), exposed via
  den's `flakeOutputs.packages`.

## Provenance

deniac-original. The CivitAI / HuggingFace API shapes (downloadUrl,
`hashes.SHA256`, tree `lfs.oid`) were verified live against the public
APIs. The "browse in the real site, capture with a CLI" pattern is the
deniac answer to Stability Matrix's in-app model browser — see
`research/ai-model-store-sharing.md` §8.3.
