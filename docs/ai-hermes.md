# deniac.ai.hermes — Hermes Agent in a bubblewrap jail

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous
Research, **MIT**) is a self-improving agent: persistent memory, skills it
writes from experience, a mutable `~/.hermes` state directory. This
aspect runs it inside a [bubblewrap](https://github.com/containers/bubblewrap)
jail — daemonless, rootless, no sudo — where the host system is read-only
and the user's home is the workspace.

## Reproducibility model: configuration vs. experience

The line the jail draws is **what the stack IS** (declared in Nix,
hash-pinned) versus **what the agent LEARNED** (mutable, backed up):

| Tier | Contents | Fate |
| --- | --- | --- |
| **Declared** | hermes package, jail wrapper, `extraPackages` | `nix build` — reproducible from the flake |
| **Mutable** | `~/.hermes` — sessions, skills, memories, `config.yaml`, the agent's own `venv/` | **Back it up** like precious-bulk weights; never rebuilt |

The agent's mutable layer is its *experience*, not its configuration.
A fresh host + the flake + a restored `~/.hermes` = the same agent.

## Why bubblewrap, not the upstream podman container

The upstream NixOS module's container mode runs the container **as root**
(its own docs: "Podman's rootful containers require sudo"). Rootless
podman is not a configuration of that module — it contradicts it — and
on this fleet the sudoless path failed completely (and the sudo
compromise too). Bubblewrap delivers the same jail properties with none
of that:

| | upstream container mode | this jail |
|---|---|---|
| Daemon | podman/dockerd | none |
| Privilege | root (sudo for CLI) | your user |
| Image | Ubuntu base | none (Nix store) |
| Agent can extend itself | yes (container fs) | yes (`~/.hermes/venv`) |
| Host protection | container boundary | mount namespace, system ro |

**Isolation model:** the jail protects the *system* from the agent — no
writes outside the user's home, no root, no host state. The user's own
`~/.hermes` and declared project dirs are deliberately read-write:
that's the agent's workspace, by design.

## The jail

`hermes-jailed` is a `bwrap` wrapper:

- **Read-only:** `/nix/store`, `/etc`, `/run/current-system/sw`,
  `XDG_RUNTIME_DIR` (sockets), plus any `extraReadonlyDirs`
- **Read-write:** the user's `$HOME` (contains `~/.hermes`), plus
  `extraReadwriteDirs` (project workspace beyond home)
- **Fresh:** `tmpfs /tmp`, new PID namespace, new session, `LD_PRELOAD`
  stripped
- **PATH:** hermes + `extraPackages` + `~/.hermes/venv/bin` (last —
  the agent's own learned tool layer wins)

## Phases (mirroring the installer's choices)

**Phase 1 — the core jail (this aspect).** Install, run
`hermes-jailed`, configure the model in the agent's own
`~/.hermes/config.yaml` (mutable tier). Point it at local models:
`model.base_url = "http://127.0.0.1:8731/v1"` (gufo/halogen
OpenAI-compatible endpoints) or OpenRouter; keys via `env`/secrets —
never in Nix store values.

**Phase 2 — the gateway as a systemd user service.** `hermes-jailed`
running the messaging gateway under Home Manager's `systemd.user.services`
with lingering: survives logout, restarts on failure, Telegram/Discord/
Slack in.

**Phase 3 — memory providers.** [MemPalace](https://github.com/mempalace/mempalace)
(MIT, local, ChromaDB-backed) ships as an MCP server, so one palace
serves both harnesses: Hermes via its `mcpServers` config, dsh via
`dsh-mcp-client`. The [hermes-mempalace](https://github.com/kjames2001/hermes-mempalace)
native provider (`memory.provider = mempalace`) is the deeper
integration — declared into the agent env when wanted.

**TTS — deliberately out of scope.** Audio stories (sci-fi narrations,
YouTube content) belong in **ComfyUI workflows** (ACE-Step and friends —
see `ai.ace-step`), not in a real-time agent TTS engine. If a real TTS
need ever emerges, the declared path is preserved here for reuse:
neutts 1.4.1 (PyPI) + neucodec as vendored `buildPythonPackage`
expressions riding nixpkgs' `torch`/`torchaudio`/`transformers`/
`librosa`/`soundfile`/`phonemizer` — hash-pinned, store-built. Do NOT
pip-install into the mutable layer for configuration; that tier is for
experience only.

## Options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Install `hermes-jailed` |
| `package` | package | `llm-agents` `hermes-agent` (existing pin — same input that provides dsh) | The hermes build |
| `extraPackages` | [package] | `[]` | Extra jail PATH packages |
| `extraReadonlyDirs` | [str] | `[]` | Extra ro binds |
| `extraReadwriteDirs` | [str] | `[]` | Extra rw binds (project workspace) |
| `env` | attrs | `{}` | Extra env vars in the jail |

## Usage

```nix
den.aspects.tux.includes = [ deniac.ai.hermes ];
den.aspects.tux.homeManager.deniac.ai.hermes = {
  enable = true;
  extraReadwriteDirs = [ "/home/tux/projects" ];
  env = { CAMOFOX_URL = "http://localhost:9337"; };
};
```

## Provenance

- Agent: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
  (MIT), packaged via [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)
  `packages/hermes-agent` — from the **existing** deniac `llm-agents`
  pin (no new input).
- Jail pattern: informed by [andersonjoseph/jailed-agents](https://github.com/andersonjoseph/jailed-agents)
  (community-first survey; current upstream API too minimal for the
  fleet's needs, so the wrapper is hand-rolled) and the fleet's prior
  `jailed-hermes.nix` experiments.

## Tests

`nix run nixpkgs#nix-unit -- --flake .#.tests.ai-hermes --impure` —
namespace export, homeManager-class-only shape.
