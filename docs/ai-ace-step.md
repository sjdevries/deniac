# deniac.ai.ace-step — ACE-Step music generation in ComfyUI

Wires the **official** [ace-step/ACE-Step-ComfyUI](https://github.com/ace-step/ACE-Step-ComfyUI)
custom-node pack into the ComfyUI service, declaratively and pinned.
ACE-Step ([ace-step/ACE-Step-1.5](https://github.com/ace-step/ACE-Step-1.5),
MIT) is the open-source music-generation model — text-to-music with
vocals in 50+ languages, plus **cover/remix**, **repaint**, and
LLM-assisted sample generation.

## Architecture: the node is a thin API client

The ComfyUI node is **not** the model. Its only Python deps are
`torch`, `numpy`, `requests` — all already present in ComfyUI's
environment, so no `extraPythonPackages` are needed. It talks to an
**ACE-Step 1.5 server** in one of two modes:

| Mode | Endpoint | Notes |
| --- | --- | --- |
| `cloud` | `https://api.acemusic.ai` | Needs an API key (`ACESTEP_API_KEY`) — not this aspect's story |
| `local` | `http://127.0.0.1:8002` (node default) | An ACE-Step 1.5 server colocated on the host |

The node's `server_url` is a **per-workflow input** (a string field on the
Text2Music Server node), so there is nothing for the aspect to wire
beyond installing the node: the local-mode default matches a colocated
server out of the box.

## What the aspect does

With `enable = true`:

- `services.comfyui.customNodes."ACE-Step-ComfyUI"` = the pinned
  official node source (comfyui-nix symlinks it into `custom_nodes/` at
  service start — fully reproducible, version-pinned).

With `enable = true` but the ComfyUI service off: a `config.warnings`
entry (the nodes have nothing to attach to).

**What it does *not* do (v1):** manage the ACE-Step 1.5 server itself.
There is no official prebuilt container image (the upstream repo ships a
Dockerfile you build yourself; community images exist on Docker Hub with
varying provenance), so pinning a server image into a public framework is
a trust decision deliberately left to the operator. See below for
running the server.

## Options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Install the ACE-Step ComfyUI nodes |
| `package` | package | pinned `ace-step/ACE-Step-ComfyUI` input | Node source override |

## Usage

**Requires `deniac.ai.comfyui`** (or the comfyui-nix module directly) to be
included alongside — it provides the `services.comfyui.*` option tree.
The ace-step aspect deliberately does not import the comfyui-nix module
itself: doing so in both aspects double-applies it and collides on
comfyui-nix's unique-priority `services.comfyui.packageSet.default`.

```nix
# ComfyUI on a Strix Halo box + ACE-Step nodes
den.aspects.igloo.includes = [ deniac.ai.comfyui deniac.ai.ace-step ];

den.aspects.igloo.nixos.deniac.ai.comfyui = {
  enable = true;
  gpuSupport = "rocm";
  rocmChannel = "rocm72";   # gfx1151-capable stable
};

den.aspects.igloo.nixos.deniac.ai.ace-step.enable = true;
```

Then in ComfyUI: add the ACE-Step nodes (or load a template), select
`local` mode, and generate.

## Running the ACE-Step 1.5 server (the colocated half)

The server is the GPU-heavy half — the model itself. Options:

1. **Local install** (recommended on NixOS-friendly setups):
   ```sh
   git clone https://github.com/ace-step/ACE-Step-1.5.git
   cd ACE-Step-1.5
   uv sync                      # or: pip install -e .
   uv run acestep-openrouter --host 127.0.0.1 --port 8002
   ```
   Models download to the Hugging Face cache on first run — point
   `HF_HOME` at your model store's shared cache (the
   `deniac.ai.model-store` `hfCache` path) so ACE-Step weights land in
   the same content-addressed pool as everything else.

2. **Container**: build the upstream `Dockerfile` yourself, or evaluate
   a community image's provenance before trusting it. Mount the model
   cache in; expose 8002 on loopback.

**Hardware notes:** ACE-Step is small (a few GB working set — runs from
~4 GB VRAM-class). On a unified-memory box the usual co-residency rule
applies: a music session wants headroom, so run it with the big LLM
powered down or parked.

## The fun part (per the operator)

- **Cover/remix**: feed a source song + a new style caption — the model
  keeps melody shape/rhythm/form and re-performs it in the new genre.
  Country → dubstep ("CowStep"), country → rap ("crap", per the
  release notes) — the genre-distance is the joke.
- **Repaint**: re-render a selected segment (swap the solo, fix the
  bridge) while the rest stays.
- **Lyrics survive covers**: re-interpretation/parody comes free.

## Provenance

- Nodes: [ace-step/ACE-Step-ComfyUI](https://github.com/ace-step/ACE-Step-ComfyUI)
  (official, MIT) — pinned as the `ace-step-comfyui` flake input.
- Model/server: [ace-step/ACE-Step-1.5](https://github.com/ace-step/ACE-Step-1.5)
  (MIT).
- ComfyUI wiring: comfyui-nix `customNodes` (see the `ai.comfyui` doc).

## Tests

`nix run nixpkgs#nix-unit -- --flake .#.tests.ai-ace-step --impure` —
namespace export, inert-by-default, node wiring (customNodes entry is a
store path), warning-without-service, silent-with-service.
