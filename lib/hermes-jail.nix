# lib/hermes-jail.nix — pure jail & config generation for deniac.ai.hermes.
#
# This file lives OUTSIDE modules/ on purpose: den's import-tree loads every
# .nix under modules/ as a module, so shared pure functions can't live there
# (they'd be eval'd as broken aspects). Both the aspect and its tests import
# this file directly.
#
# Every function is a pure function of (pkgs, …) so the security-critical
# logic — the default-deny bind, the per-profile `-p <name>` baking, the
# declared-config rendering — is unit-testable with a real `pkgs` and a
# plain profile attrset, WITHOUT a home-manager eval.
#
# The security model (see the fleet research note for the rationale):
#   * default-DENY — the real home is never bound; the agent's HOME is its
#     own profile `home/` dir, so it cannot read ~/.ssh, ~/.aws, browser
#     profiles, or sibling profiles.
#   * per-profile capability — each profile gets its own tools (mcpServers)
#     and persona (SOUL.md), rendered into its config.yaml.
#   * tier match-to-threat — bwrap (namespace) for the confused-deputy
#     threat; munix (KVM microVM) when a compromised tool/MCP server must
#     not reach the host kernel, plus per-VM network (`--no-network`).

{ lib }:
rec {
  # ── declared config.yaml ───────────────────────────────────────────
  # JSON is a subset of YAML, so this renders a valid config.yaml body.
  # `mcp_servers` is the compartment's tools; `settings` are extra
  # behavioral keys merged in (declared wins over learned).
  declaredConfig = name: prof:
    builtins.toJSON (
      {
        mcp_servers = lib.mapAttrs (_: s: {
          command = s.command;
          args = s.args;
          env = s.env;
        }) prof.mcpServers;
      }
      // prof.settings
    );

  renderProfileConfig = pkgs: name: prof:
    pkgs.writeText "hermes-profile-${name}-config.json" (declaredConfig name prof);

  renderProfileSoul = pkgs: name: prof:
    pkgs.writeText "hermes-profile-${name}-SOUL.md" prof.soul;

  # Preserve-learned-keys merge: deep-merge the declared config over the
  # profile's existing config.yaml. Declared keys win; keys the agent
  # LEARNED (experience tier) are kept. YAML-aware (the agent writes YAML;
  # the declared file is JSON, which is valid YAML).
  mergeScript = pkgs:
    let
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    pkgs.writeShellScript "hermes-merge-config" ''
      set -eu
      declared="$1"; target="$2"
      ${py}/bin/python - "$declared" "$target" <<'PY'
      import yaml, os, sys

      def deep(a, b):  # b (declared) wins over a (learned)
          out = dict(a) if isinstance(a, dict) else {}
          for k, v in b.items():
              if isinstance(v, dict) and isinstance(out.get(k), dict):
                  out[k] = deep(out[k], v)
              else:
                  out[k] = v
          return out

      declared = yaml.safe_load(open(sys.argv[1])) or {}
      target = sys.argv[2]
      learned = {}
      if os.path.exists(target):
          try:
              learned = yaml.safe_load(open(target)) or {}
          except Exception:
              learned = {}
      with open(target, "w") as f:
          yaml.safe_dump(deep(learned, declared), f, default_flow_style=False)
      PY
    '';

  # ── bwrap-tier jail: DEFAULT-DENY bind ─────────────────────────────
  # The real $HOME is NOT bound. The agent's HOME is its profile's own
  # `home/` dir (which lives inside the bound profile dir), so the rest of
  # the real home — ~/.ssh, ~/.aws, browser profiles, sibling profiles —
  # is simply absent inside the jail. XDG_RUNTIME_DIR points at the tmpfs
  # /tmp so the agent gets a fresh runtime dir instead of the real
  # session sockets (wayland/pulse).
  mkBwrapJail = pkgs: hermesPkg: name: prof:
    let
      roBinds = lib.concatStringsSep " "
        (map (d: "--ro-bind-try ${lib.escapeShellArg d} ${lib.escapeShellArg d}") prof.bindReadonly);
      rwBinds = lib.concatStringsSep " "
        (map (d: "--bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") prof.bindReadwrite);
      envArgs = lib.concatStringsSep " "
        (lib.mapAttrsToList (k: v: "--setenv ${k} \"${v}\"") prof.env);
      path = lib.makeBinPath ([ hermesPkg ] ++ prof.extraPackages);
    in
    pkgs.writeShellScriptBin "hermes-jailed-${name}" ''
      set -eu
      : "''${HOME:?HOME must be set (the profile home lives under it)}"
      PH="$HOME/.hermes/profiles/${name}"
      mkdir -p "$PH/home"
      exec ${pkgs.bubblewrap}/bin/bwrap \
        --die-with-parent \
        --new-session \
        --dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --ro-bind /nix/store /nix/store \
        --ro-bind /etc /etc \
        --ro-bind-try /run/current-system/sw /run/current-system/sw \
        --bind "$PH" "$PH" \
        ${roBinds} \
        ${rwBinds} \
        --unsetenv LD_PRELOAD \
        --setenv HOME "$PH/home" \
        --setenv HERMES_HOME "$PH" \
        --setenv XDG_RUNTIME_DIR /tmp \
        --setenv PATH "${path}" \
        ${envArgs} \
        -- ${hermesPkg}/bin/hermes -p ${name} "$@"
    '';

  # ── munix-tier launcher ────────────────────────────────────────────
  # Boots the declared NixOS toplevel closure in a KVM microVM via munix.
  # The bind allowlist is passed as virtiofs mounts; the network posture
  # maps to munix `--no-network` (the reviewer's clean no-net boundary).
  # The guest closure is a declared input (built by the host / a separate
  # aspect); this launcher only wires the flags.
  mkMunixLauncher = pkgs: munixPkg: name: prof:
    let
      netFlag = if prof.network == "none" then "--no-network" else "";
      gpuFlag = if !prof.gpu then "--no-gpu" else "";
      roBinds = lib.concatStringsSep " "
        (map (d: "--ro-bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") prof.bindReadonly);
      rwBinds = lib.concatStringsSep " "
        (map (d: "--bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") prof.bindReadwrite);
    in
    pkgs.writeShellScriptBin "hermes-munix-${name}" ''
      set -eu
      CLOSURE="${prof.munixClosure}"
      if [ -z "$CLOSURE" ]; then
        echo "hermes-munix-${name}: munixClosure is not set (required for tier = munix)" >&2
        exit 1
      fi
      exec ${munixPkg}/bin/munix \
        ${netFlag} ${gpuFlag} \
        ${roBinds} ${rwBinds} \
        "$CLOSURE" \
        hermes -p ${name} "$@"
    '';
}
