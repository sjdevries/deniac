# deniac.ai.hermes — Hermes Agent in role-compartment jails

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous
Research, **MIT**) is a self-improving agent: persistent memory, skills it
writes from experience, a mutable `~/.hermes` state directory. This
aspect runs it in **role compartments** — least-privilege profiles
(researcher / coder / reviewer / creator) — each enforced by either
[bubblewrap](https://github.com/containers/bubblewrap) (a daemonless,
rootless mount-namespace jail) or [munix](https://git.clan.lol/clan/munix)
(a KVM microVM).

## The security model: remove the capability, not the attack

Prompt injection is a **confused-deputy** attack. The agent is tricked by
text it reads (a web page, a repo file, an MCP response) into doing
something you didn't ask for. You cannot reliably *detect* the malicious
text — it looks like any other text. But you can **remove or bound the
capability**, so a compartment simply cannot touch what it was never given.

The model is three strategies, matched to each role:

| Role | Threat | Strategy | Compartment |
| --- | --- | --- | --- |
| **researcher** | reads untrusted web, may be injected | **remove** — no secrets, no push | web tools only; writes to a `research-out` dir; cannot read `~/.ssh`/`~/.aws` |
| **coder** | edits a repo, may be injected | **keep-away** — scoped to the repo | repo rw; git creds via env; no other home access |
| **reviewer** | reads untrusted code, must not leak | **contain** — no egress | repo ro; `network = "none"` |
| **creator** | runs ComfyUI custom nodes (arbitrary code) | **contain** — microVM | GPU microVM; store ro / output rw / no secrets |

**Handoff is a data diode.** A researcher's output lands in a directory a
*human* reviews before it reaches a privileged compartment. Never
researcher → coder directly; the human is the gate.

## Two enforcement tiers (compose, don't compete)

Match the tier to the threat. They are not alternatives to choose between
globally — each profile picks its tier.

| | **bwrap** (Tier A) | **munix** (Tier B) |
|---|---|---|
| Boundary | mount namespace (shared kernel) | KVM microVM (separate guest kernel) |
| Stops | confused-deputy (filesystem capability) | + jail-escape vs a compromised tool/MCP server |
| Network | all-or-nothing (`--unshare-net` cuts localhost too) | per-VM: `--no-network` is a clean boundary |
| Cost | near-zero | KVM + a guest closure |

**`tier = "munix"` is the default — the target.** The Nix³OS model puts
every agent compartment in a Tier-1 microVM: a uniform strong boundary
(separate guest kernel) with a per-VM routable network. **`tier =
"bwrap"` is the fallback** — for hosts without KVM / nested virt, or a
compartment you deliberately want lighter.

The honest nuance: bwrap + the default-deny allowlist *already* defeats
the confused-deputy / prompt-injection threat — the agent can't touch
what it wasn't given, injected or not. munix doesn't make the *injection*
defense stronger; it adds **jail-escape containment** against a
compromised tool/MCP server, plus the per-VM network. "Always munix" is
the target (uniform boundary + per-VM egress), not a strict requirement
for the injection threat alone. "Don't over-stack" means don't run
bwrap+munix+nono when one boundary suffices — not "don't use munix."

## Model routing (the always-munix crux)

Every compartment needs the model, but a microVM guest can't reach the
host's `127.0.0.1`. The aspect does **not** hardcode the routing — each
profile declares `settings.model.base_url`, and the launcher never
touches the model. That single declared knob is the seam that lets the
topology change without a re-architecture: **today the model is local**
(same box, reached over the VM tap); **the intent is to break it apart**
onto a separate LLM machine reached over netbird/VPN. Same `base_url`
option, different value:

| Topology | `model.base_url` | Notes |
| --- | --- | --- |
| **Local today** — host model, VM-bridge tap | `http://<host-tap-ip>:8731/v1` | one model serves all VMs; tap firewall gates who reaches it |
| **Break-apart later** — separate LLM box over netbird/VPN | `http://<netbird-host>:8731/v1` | the model host is just another allowlisted egress destination — same class as "internet" or "git remote" |
| Model bundled in-VM | `http://127.0.0.1:8731/v1` | cleanest isolation; a model per VM (heavy) |

The netbird/VPN target is the cleanest fit for the egress model: the
model host is a declared destination on the per-VM tap firewall, exactly
like the researcher's internet or the coder's git remote. The
fine-grained per-VM egress (model-host yes / internet maybe / git only)
is enforced by the **host-level tap firewall** over munix's virtio-net —
not by the launcher. The launcher's `network` flag is coarse:
`"none"` → `--no-network` is a *total* boundary (cuts the model too, so
use it only with an in-VM model); `"full"` + a tap rule gives
"model yes / internet no" for the reviewer.

> **Caveats (honest scope).** These compartments defeat the
> confused-deputy / prompt-injection threat. They do **not** defeat a
> kernel exploit or a compromised supply chain (a malicious package in the
> closure runs with whatever the closure has). Granting an MCP server is
> granting its capability — a tool with network + a secret can exfiltrate
> regardless of the jail around the *agent*. Bound the tool, not just the
> agent.

## The default-deny crux

The single most important property: **the real home is never bound.** The
old single-jail model bound `$HOME` read-write and added knobs — which
meant a "researcher" could still read `~/.ssh`, `~/.aws`, and browser
profiles. The compartment model flips this to a **default-deny bind
allowlist**:

- The agent's `HOME` is its own profile `home/` dir (inside the bound
  profile directory), **not** the real home.
- `XDG_RUNTIME_DIR` points at the tmpfs `/tmp`, so the agent gets a
  fresh runtime dir instead of the real session sockets (wayland/pulse).
- Every path the agent may touch is declared in `bindReadonly` /
  `bindReadwrite`. Everything else — the rest of the real home, sibling
  profiles — is simply absent inside the jail.

This is asserted in the test suite (`test-bwrap-default-deny`), not just
documented.

## Reproducibility model: configuration vs. experience

The line the jail draws is **what the stack IS** (declared in Nix,
hash-pinned) versus **what the agent LEARNED** (mutable, backed up):

| Tier | Contents | Fate |
| --- | --- | --- |
| **Declared** | hermes package, jail wrappers, per-profile `config.yaml` (tools/settings) + `SOUL.md`, bind allowlists | `nix build` — reproducible from the flake |
| **Mutable** | `~/.hermes/profiles/<name>/` — sessions, skills, memories, the agent's own learned config keys | **Back it up** like precious-bulk weights; never rebuilt |

Declared config is merged over the agent's learned `config.yaml` with a
**preserve-learned-keys** merge (declared keys win; learned keys are
kept). So you can declare a compartment's tools and persona without
clobbering what the agent has learned in it.

## Why bubblewrap, not the upstream podman container

The upstream NixOS module's container mode runs the container **as root**
(its own docs: "Podman's rootful containers require sudo"). Rootless
podman is not a configuration of that module — it contradicts it — and
on this fleet the sudoless path failed completely (and the sudo
compromise too). Bubblewrap delivers the jail with none of that:

| | upstream container mode | bwrap tier |
|---|---|---|
| Daemon | podman/dockerd | none |
| Privilege | root (sudo for CLI) | your user |
| Image | Ubuntu base | none (Nix store) |
| Host protection | container boundary | mount namespace, system ro, default-deny home |

## Options

Top level:

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Install the compartmentalized jails |
| `package` | package | `llm-agents` `hermes-agent` (existing pin — same input that provides dsh) | The hermes build |
| `profiles` | attrs of profile | `{}` | The role compartments (below) |

Each profile (`profiles.<name>`):

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `tier` | `"bwrap"` \| `"munix"` | `"munix"` | Enforcement tier (munix = target; bwrap = fallback for non-KVM hosts) |
| `bindReadonly` | [str] | `[]` | Host dirs bound read-only |
| `bindReadwrite` | [str] | `[]` | Host dirs bound read-write (the compartment's workspace) |
| `mcpServers` | attrs | `{}` | The compartment's tools, rendered to `config.yaml` `mcp_servers` |
| `settings` | attrs | `{}` | Extra behavioral keys merged into `config.yaml` |
| `soul` | nullOr str | `null` | Persona rendered to `SOUL.md` (null = leave the agent's own) |
| `network` | `"full"` \| `"none"` | `"full"` | munix egress posture (`none` → `--no-network`) |
| `gpu` | bool | `false` | munix: pass GPU through |
| `munixPackage` | nullOr package | `null` | munix runner (consumer-provided; deniac doesn't pin libkrun/KVM) |
| `munixClosure` | nullOr str | `null` | the NixOS toplevel the microVM boots |
| `extraPackages` | [package] | `[]` | Extra PATH packages |
| `env` | attrs | `{}` | Extra env vars in the compartment |

Each profile generates a launcher: `hermes-jailed-<name>` (bwrap) or
`hermes-munix-<name>` (munix), and renders its declared `config.yaml` +
`SOUL.md` into `~/.hermes/profiles/<name>/` at activation.

## Usage

```nix
den.aspects.tux.includes = [ deniac.ai.hermes ];
den.aspects.tux.homeManager.deniac.ai.hermes = {
  enable = true;

  # The model base_url is the seam: local today, a separate netbird LLM
  # box later — same knob, different value.
  profiles = {
    # Reads the web, gets injected, has nothing to steal. munix by default.
    researcher = {
      munixPackage = inputs.munix.packages.x86_64-linux.munix;
      munixClosure = "/nix/store/...-researcher-toplevel";
      bindReadwrite = [ "/home/tux/research-out" ];   # its only write target
      mcpServers.donsetch.command = "donsetch";
      settings.model.base_url = "http://100.64.0.1:8731/v1";  # local today
      soul = "You are a research assistant. No secrets, no push.";
    };

    # Edits one repo. Git creds via env; nothing else from home.
    coder = {
      munixPackage = inputs.munix.packages.x86_64-linux.munix;
      munixClosure = "/nix/store/...-coder-toplevel";
      bindReadwrite = [ "/home/tux/work/myrepo" ];
      env.GIT_SSH_COMMAND = "ssh -i /home/tux/.ssh/deploy_key";
      settings.model.base_url = "http://100.64.0.1:8731/v1";
    };

    # Reads untrusted code, must not leak. No internet; reaches the model
    # over the tap (network="full" + a host tap rule: model yes, internet
    # no). Use network="none" only if the model is bundled in-VM.
    reviewer = {
      munixPackage = inputs.munix.packages.x86_64-linux.munix;
      munixClosure = "/nix/store/...-reviewer-toplevel";
      network = "full";
      bindReadonly = [ "/home/tux/work/myrepo" ];
      settings.model.base_url = "http://100.64.0.1:8731/v1";
    };

    # A deliberately-lighter compartment opts into the bwrap fallback
    # (e.g. a host without KVM, or a trusted local-only task).
    trusted-local = {
      tier = "bwrap";
      bindReadwrite = [ "/home/tux/work/trusted" ];
    };
  };
};
```

Then `hermes-munix-researcher …`, `hermes-munix-coder …`,
`hermes-munix-reviewer …`, `hermes-jailed-trusted-local …`. The
researcher's `research-out` is reviewed by a human before anything in it
reaches the coder — the data diode.

**Runtime tuning.** bwrap jails need one round of missing-mount tuning per
agent version. Start strict (default-deny); if hermes reports a missing
path, add it to that profile's `bindReadonly`/`bindReadwrite` and bake it
into the default.

## Semi-autonomous handoff: the coder's jail + approval gate

A compartment can be **semi-autonomous** — driven forward by a peer signal
("research done, continue coding") — while keeping its blast radius small.
The rule that makes both true at once:

> **A peer message can only trigger what the receiver is *capable of* and
> *approved to do*.** Bound those two, and the sender's trust stops mattering.

Two independent gates on the coder:

**1. The jail (capability) — what it can touch.** No push credentials bound.
The coder works in a local worktree; it physically cannot push to `main`
because the key is not in its world.

```nix
coder = {
  tier = "munix";
  bindReadwrite = [ "/home/tux/coder-worktree" "/home/tux/coder-scratch" ];
  bindReadonly  = [ "/home/tux/research-out" ];   # researcher's findings, read-only
  # NOT bound: ~/.ssh, ~/.aws, the creator compartment, host secrets.
  settings.model.base_url = "http://100.64.0.1:8731/v1";
};
```

**2. The approval gate (command) — what it can run unattended.**
`approvals.mode = "smart"` has an auxiliary LLM assess every shell command:
low-risk auto-runs, high-risk denies, uncertain prompts. The `command_allowlist`
makes the *reversible* work run without friction:

```nix
settings.approvals.mode = "smart";
settings.command_allowlist = [
  "git status" "git diff" "git log" "git add" "git commit"
  "git checkout" "git branch"
  "pytest" "cargo test" "npm test" "make test"
];
# NOT allowlisted → smart gate / deny:
#   git push, git push --force, git reset --hard, rm -rf, sudo, deploy.
# Destructive classes are never auto-approved regardless of the allowlist.
```

**The split that reconciles autonomy with blast radius:**

| Reversible → auto-run | Irreversible → human gate |
| --- | --- |
| edit, test, commit to a branch | push to main, deploy, spend |
| read `research-out` | touch credentials |

So the researcher can genuinely drive the coder —
`hermes peer run coder "research done: <summary>, continue"` — and the worst
a *compromised* researcher can produce is a **tested branch awaiting your
merge**. The ceiling is set by the coder's jail + allowlist, not by trusting
the researcher.

**The credential caveat.** `peer` requires the sender to hold the receiver's
`API_SERVER_KEY` (stored in the sender's `~/.hermes/.env`). A web-compromised
researcher holding the coder's key is a hostile sender with a live credentialed
channel — which is exactly why the coder's jail + approvals are the wall, not
the peer auth.

**Prefer pull over push.** To remove the credential exposure entirely, flip
the direction: the coder (more trusted) holds the researcher's key and *polls*
`research-out` / a scoped board for "done," then self-triggers. The untrusted
researcher then holds **no credential to the coder at all** — same
semi-autonomy, strictly smaller blast radius.

## Phases (mirroring the installer's choices)

**Phase 1 — the core jail + compartments (this aspect).** Declare
profiles, run the launchers, configure models in the rendered
`config.yaml` (or point at local models:
`model.base_url = "http://127.0.0.1:8731/v1"` — gufo/halogen
OpenAI-compatible endpoints — or OpenRouter; keys via `env`/secrets,
never in Nix store values).

**Phase 2 — the gateway as a systemd user service.** Run a compartment's
gateway under Home Manager's `systemd.user.services` with lingering:
survives logout, restarts on failure, Telegram/Discord/Slack in.

**Phase 3 — memory providers.** [MemPalace](https://github.com/mempalace/mempalace)
(MIT, local, ChromaDB-backed) ships as an MCP server, so one palace
serves both harnesses: Hermes via its `mcpServers` config, dsh via
`dsh-mcp-client`. Note the security caveat: a shared memory provider is a
channel between compartments — treat cross-compartment memory as a
handoff that needs the same human gate as files.

**TTS — deliberately out of scope.** Audio stories (sci-fi narrations,
YouTube content) belong in **ComfyUI workflows** (ACE-Step and friends —
see `ai.ace-step`), not in a real-time agent TTS engine. If a real TTS
need ever emerges, the declared path is preserved here for reuse:
neutts 1.4.1 (PyPI) + neucodec as vendored `buildPythonPackage`
expressions riding nixpkgs' `torch`/`torchaudio`/`transformers`/
`librosa`/`soundfile`/`phonemizer` — hash-pinned, store-built. Do NOT
pip-install into the mutable layer for configuration; that tier is for
experience only.

## Provenance

- Agent: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
  (MIT), packaged via [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix)
  `packages/hermes-agent` — from the **existing** deniac `llm-agents`
  pin (no new input).
- bwrap jail pattern: informed by [andersonjoseph/jailed-agents](https://github.com/andersonjoseph/jailed-agents)
  (community-first survey) and prior jail experiments; the wrapper is
  hand-rolled because the current upstream API is too minimal for the
  compartment model.
- munix tier: [Clan munix](https://git.clan.lol/clan/munix) (muvm /
  libkrun), consumed as a consumer-provided package (`munixPackage`),
  not pinned in deniac.

## Tests

`nix run nixpkgs#nix-unit -- --flake .#.tests.ai-hermes --impure` —
4 tests: namespace export (homeManager-class-only shape); **bwrap
default-deny** (real home not bound, profile-home `HOME`, declared binds
present, `-p <name>` baked in); **munix posture** (`--no-network`,
closure + virtiofs binds); **declared config** renders `mcp_servers` +
settings. The pure jail/config logic lives in `lib/hermes-jail.nix`
(outside `modules/` so import-tree won't load it as an aspect) and is
unit-tested directly.
