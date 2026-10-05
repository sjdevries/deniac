# `ai.unsloth` — Unsloth Studio (rootless podman)

Runs [Unsloth Studio](https://github.com/unslothai/unsloth) — the
headless **web-UI server** form of Unsloth — as a **rootless** podman
container under a systemd *user* service, using the **AMD ROCm** image
`unsloth/unsloth-rocm`. Studio runs and trains LLMs / diffusion / audio
models and serves an OpenAI-compatible API plus a JupyterLab backend.

## The three forms — this is the *server*

Unsloth ships three ways; only one is a service:

| Form | What it is | This aspect? |
| --- | --- | --- |
| **Unsloth Desktop** | Native GUI app (Win/macOS/Linux `.deb`/AppImage) | ❌ not a service — wraps the same engine |
| **Unsloth Studio** | Web-UI server (`unsloth studio`) | ✅ **this aspect** — the headless NixOS-runnable form |
| **Unsloth Core** | The pip package (code-based) | ❌ library, not a service |

The Desktop GUI wraps the same engine Studio runs; on a headless NixOS
box you run **Studio**.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `enable` | `false` | Start the Studio container. Inert by default. |
| `image` | `unsloth/unsloth-rocm:latest` | AMD ROCm image. NVIDIA build is `unsloth/unsloth`. Pin a `sha-<rev>` tag for reproducibility. |
| `host` | `127.0.0.1` | Host-side bind for the published ports. **Loopback by default** — see Security. |
| `port` | `8000` | Studio web UI / OpenAI-compatible API. |
| `jupyterPort` | `8888` | JupyterLab backend. |
| `modelsDir` | `ai.model-store.hfCache` → fallback `/var/lib/ai-models/.hf-cache` | Host dir mounted as the container's HuggingFace cache. Defaults to the shared store. |
| `studioDataDir` | `/var/lib/unsloth-studio` | Persistent Studio state (`/opt/unsloth-studio`). Provision on a persisted mount. |
| `passwordFile` | `null` | Path to an env-file (`UNSLOTH_STUDIO_PASSWORD=…`), passed via `--env-file`. Point at a sops/agenix secret. |
| `user` | `unsloth` | Rootless service user (created with linger). |
| `serveArgs` | `[]` | Extra `unsloth studio` args, appended verbatim. |

## Usage

```nix
imports = [ (inputs.den.namespace "deniac" [ inputs.deniac ]) ];

# include the store so the HF cache is shared:
den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.unsloth ];

den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;
# set the admin password from a secret (file containing KEY=VALUE):
den.aspects.igloo.nixos.deniac.ai.unsloth.passwordFile =
  config.age.secrets.unsloth-studio.path;
```

Then open `http://127.0.0.1:8000` (or point an OpenAI client at
`http://127.0.0.1:8000/v1`).

## Shared model store (batteries-included)

`modelsDir` defaults to the shared
[`ai.model-store`](./ai-model-store.md) `hfCache`, so models Studio
downloads land in the **shared** HuggingFace cache — content-addressed,
downloaded once, shared with gufo / ComfyUI / any other consumer. The
service user joins the store group (`aimodels`) for read-write access to
that cache. A custom store `root` propagates automatically.

## ⚠ Security

Studio ships **server-side tools ON by default**. This aspect binds the
published ports to `host`, **loopback by default**, so nothing is
reachable off-box unless you deliberately set a routable `host`. If you
do:

- **Set `passwordFile`** first (a real secret, not the auto-generated
  one).
- Consider what the exposed tools (JupyterLab, code execution) mean on
  your network.
- The firewall only opens `port`/`jupyterPort` when `host` is non-loopback.

## License

Unsloth is **dual-licensed**: Apache-2.0 (core) + AGPL-3.0 (Studio UI).
The image is pulled from Docker Hub (`unsloth/unsloth-rocm`), not built
here.

## Provenance

Runtime verified from the [unslothai/unsloth
README](https://github.com/unslothai/unsloth) (Desktop/Studio/Core
forms, the `unsloth studio` server, ports 8000/8888, `--ipc=host`, the
HF-cache mount, `UNSLOTH_STUDIO_PASSWORD`) and the AMD image
[`unsloth/unsloth-rocm`](https://hub.docker.com/r/unsloth/unsloth-rocm)
(tags: `latest`, `studio`, `nightly`), retrieved 2026-10-04. The
rootless podman run line, systemd user service, linger, store-group
membership, and firewall gating are deniac's.

## Tests

`flake.tests.ai-unsloth` (denTest, host `igloo`): namespace export;
inert-by-default; enabled (podman on, rootless user service with linger
+ `render`/`video`/store-group, HF cache mounted at the container's
cache path, loopback → no firewall hole); model-store wiring (HF cache
follows the store `hfCache`, custom root propagates, store-group
membership); firewall opens both ports when bound beyond loopback.
