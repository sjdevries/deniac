# deniac.ai.hermes — Hermes Agent in a bubblewrap jail

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous
Research, **MIT**) is a self-improving agent: persistent memory, skills it
writes from experience, a mutable `~/.hermes` state directory. Running it
safely needs a jail where **the agent's state stays writable and the host
stays read-only**. This aspect provides that jail with
[bubblewrap](https://github.com/containers/bubblewrap) — daemonless,
rootless, no sudo.

## Why bubblewrap, not the upstream podman container

The upstream NixOS module's container mode runs the container **as root**
(its own docs: "Podman's rootful containers require sudo"). Rootless
podman is not a configuration of that module — it contradicts it — and on
this fleet the sudoless path failed completely (and the sudo compromise
too). Bubblewrap delivers the same jail properties with none of that:

| | upstream container mode | this jail |
|---|---|---|
| Daemon | podman/dockerd | none |
| Privilege | root (sudo for CLI) | your user |
| Image | Ubuntu base | none (Nix store) |
| Agent can `pip install` | yes (container fs) | yes (`~/.hermes`) |
| Host protection | container boundary | mount namespace, system ro |

**Isolation model:** the jail protects the *system* from the agent — no
writes outside the user's home, no root, no host state. The user's own
`~/.hermes`, `~/.npm`, and declared project dirs are deliberately
read-write: that's the agent's workspace, by design.

## The jail

`hermes-jailed` is a `bwrap` wrapper:

- **Read-only:** `/nix/store`, `/etc`, `/run/current-system/sw`,
  `XDG_RUNTIME_DIR` (audio sockets), plus any `extraReadonlyDirs`
- **Read-write:** the user's `$HOME` (contains `~/.hermes` — sessions,
  skills, memories, the pip layer), plus `extraReadwriteDirs` (project
  workspace)
- **Fresh:** `tmpfs /tmp`, new PID namespace, new session, `LD_PRELOAD`
  stripped
- **PATH:** hermes + `extraPackages` + `~/.hermes/venv/bin` (last —
  pip-installed CLIs win)

## TTS strategy: declare the stable, pip the mutable

The old wrapper baked `python311.withPackages [ neutts ... ]` into Nix —
and rotted the day nixpkgs dropped `neutts`. The jail inverts it:

- **Declared in Nix** (`tts.enable = true`): `espeak-ng`, `ffmpeg`,
  `ESPEAK_DATA_PATH`, `PULSE_SERVER` (→ the user's PipeWire socket).
  Small, stable, version-pinned.
- **Pip-installed in the jail** (once): the heavy voice model.
  [neutts](https://pypi.org/project/neutts/) lives on PyPI (1.4.1) —
  nixpkgs churn can never break it:

  ```sh
  hermes-jailed bash -c 'python3 -m venv ~/.hermes/venv &&
    ~/.hermes/venv/bin/pip install neutts soundfile'
  ```

  The venv lives in `~/.hermes` — inside the jail's mutable layer,
  surviving reboots and rebuilds, invisible to Nix.

This is the general pattern for any Python the agent needs that nixpkgs
doesn't carry: **Nix holds what's stable, the jail holds what's mutable.**

## Options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Install `hermes-jailed` |
| `package` | package | `llm-agents` `hermes-agent` (existing pin — same input that provides dsh) | The hermes build |
| `extraPackages` | [package] | `[]` | Extra jail PATH packages |
| `extraReadonlyDirs` | [str] | `[]` | Extra ro binds |
| `extraReadwriteDirs` | [str] | `[]` | Extra rw binds (project workspace) |
| `env` | attrs | `{}` | Extra env vars in the jail |
| `tts.enable` | bool | `false` | Declare espeak-ng/ffmpeg + audio env (see strategy above) |

## Usage

```nix
den.aspects.tux.includes = [ deniac.ai.hermes ];
den.aspects.tux.homeManager.deniac.ai.hermes = {
  enable = true;
  tts.enable = true;
  extraReadwriteDirs = [ "/home/tux/projects" ];
  env = { CAMOFOX_URL = "http://localhost:9377"; };
};
```

Point Hermes at local models via its own `config.yaml` (in the mutable
`~/.hermes`): `model.base_url = "http://127.0.0.1:8731/v1"` (gufo/
halogen OpenAI-compatible endpoints), keys via env — never in Nix.

## Follow-ups (documented, not yet built)

1. **Gateway as a systemd user service** — `systemd.user.services`
   running `hermes-jailed gateway` with lingering; survives logout,
   restarts on failure. (Home Manager owns lingering.)
2. **MemPalace memory over MCP** — [MemPalace](https://github.com/mempalace/mempalace)
   (MIT, local, ChromaDB-backed) ships as an MCP server, so one palace
   serves both harnesses: Hermes via its `mcpServers` config, dsh via
   `dsh-mcp-client`. The [hermes-mempalace](https://github.com/kjames2001/hermes-mempalace)
   native provider (`pip install` into the jail's venv) is the deeper
   integration.
3. **Jail mount iteration** — bwrap jails need one round of runtime
   "missing mount" tuning per agent version (DNS under systemd-resolved,
   XDG dirs). The `extraReadonlyDirs`/`extraReadwriteDirs` knobs exist
   for exactly this; report gaps and they get baked into defaults.

## Provenance

- Agent: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) (MIT),
  packaged via [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)
  `packages/hermes-agent` — from the **existing** deniac `llm-agents` pin
  (no new input).
- Jail pattern: informed by [andersonjoseph/jailed-agents](https://github.com/andersonjoseph/jailed-agents)
  (community-first survey; current upstream API too minimal for the TTS
  extras, so the wrapper is hand-rolled here) and the fleet's prior
  `jailed-hermes.nix` experiments.
- TTS: [neutts on PyPI](https://pypi.org/project/neutts/) (mutable
  layer); `espeak-ng`/`ffmpeg` from nixpkgs (declared layer).

## Tests

`nix run nixpkgs#nix-unit -- --flake .#.tests.ai-hermes --impure` —
namespace export, homeManager-class-only shape.
