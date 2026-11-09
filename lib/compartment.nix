# lib/compartment.nix — the generic compartment shape, extracted from
# lib/hermes-jail.nix.
#
# WHY THIS FILE EXISTS
#
# `ai.hermes` was the first aspect that needed a compartment: a default-deny
# sandbox that a piece of software runs inside, with a declared bind allowlist,
# a materialised state dir, and a choice of enforcement backend. Everything it
# needed turned out to be **app-agnostic** — the only hermes-specific parts
# were *what gets rendered into the state dir* and *what command runs
# inside*. The mechanics of containment had no hermes content at all.
#
# So the mechanics live here, and an app aspect supplies the two app-specific
# holes. This is the shape every "run this app as a VM" aspect reuses:
#
#     enforcement     how it is contained   (bwrap | munix)
#     binds           what it may touch     (default-DENY allowlist)
#     stateDirExpr    where its state lives (materialised, not baked)
#     command         what actually runs    (argv inside the compartment)
#
# Like hermes-jail, this lives OUTSIDE modules/ on purpose: den's import-tree
# loads every .nix under modules/ as a module, so shared pure functions
# cannot live there. Every function is pure in (pkgs, …) so the
# security-critical logic — the default-deny bind, the store-slice mode
# dispatch, the runtime-only secret read — is unit-testable with a real
# `pkgs` and a plain attrs, WITHOUT a home-manager eval.
#
# THE SECURITY MODEL (unchanged from hermes-jail; see the fleet research
# note for rationale):
#   * default-DENY — the real home is never bound. The compartment's HOME is
#     its own state dir, so it cannot read ~/.ssh, ~/.aws, browser profiles,
#     or sibling compartments.
#   * declared capability — every path the compartment may write is named in
#     the config; nothing is inherited.
#   * enforcement matched to threat — bwrap (mount namespace) for the
#     confused-deputy threat; munix (KVM microVM) when a compromised payload
#     must not reach the host kernel, plus a per-VM network boundary.
#   * secrets never enter the store — a secret is read from its decrypted
#     runtime path at launch and passed in as env. It is NEVER a build-time
#     string, because the closure is the visibility allowlist and a baked
#     secret would be visible to everything that can see the closure.

{ lib }:
rec {
  # ── store slice → munix flags ──────────────────────────────────────
  # Closure-only /nix/store for the guest. `null` keeps the whole-host store
  # bind (the unchanged default).
  #
  # Two modes, one option, both consuming the SAME pkgs.closureInfo
  # `store-paths` file:
  #
  #   closure — `--store-mode closure --store-paths <file>`. Each closure
  #     path becomes its own virtiofs submount. ZERO extra disk: the guest
  #     reads the host store's own bytes, so N guests cost N×0. This is the
  #     default and the mode a fleet should run.
  #
  #   erofs — `--store-mode erofs --store-dev <image> --sandbox-store
  #     <file>`. The closure is materialised as one erofs block device
  #     mounted by micro-activate. Cheaper at boot (1 mount, not ~1.2k) but
  #     it costs a full copy of the closure on disk PER GUEST — measured
  #     2.65 GiB compressed (lz4) for a researcher slice. Kept as the
  #     explicit opt-in for boot-latency-sensitive guests.
  #
  # Both need a munix that has `--store-mode` (fork branch `feat/store-mode`;
  # upstream clan/munix PR #40).
  #
  # `what` is the caller's human-readable label, used only so a bad mode
  # throws an error that names the thing that broke rather than this lib.
  storeSliceFlags = what: slice:
    let
      mode = if slice == null then null else slice.mode or "closure";
    in
    if slice == null then ""
    else if mode == "closure" then
      "--store-mode closure --store-paths ${lib.escapeShellArg slice.storePaths}"
    else if mode == "erofs" then
      "--store-mode erofs --store-dev ${lib.escapeShellArg slice.image} "
      + "--sandbox-store ${lib.escapeShellArg slice.storePaths}"
    else
      throw ''
        ${what}: storeSlice.mode must be "closure" or "erofs", got "${mode}".
      '';

  # ── posture → munix virtualisation flags ────────────────────────────
  # `network = "none"` maps to munix's clean no-net boundary.
  #
  # A GPU-less profile is headless, and `--no-gpu` alone is NOT enough:
  # munix still tries to bind the host Wayland socket, so on a headless host
  # the run dies before the VM even starts with
  #   bwrap: Can't find source path $XDG_RUNTIME_DIR/wayland-1
  # Verified live 2026-10-30. Audio has the same problem via pipewire, so
  # both are turned off together. This is a munix fact, not an app fact —
  # which is exactly why it belongs here rather than in one aspect.
  virtFlags = { network ? "full", gpu ? false }:
    let
      netFlag = if network == "none" then "--no-network" else "";
      gpuFlag = if !gpu then "--no-gpu" else "";
      headlessFlags = if !gpu then "--no-wayland --no-pipewire" else "";
    in
    "${netFlag} ${gpuFlag} ${headlessFlags}";

  # ── bind allowlists → munix virtiofs flags ──────────────────────────
  munixBindFlags = { bindReadonly ? [ ], bindReadwrite ? [ ] }:
    let
      ro = lib.concatStringsSep " "
        (map (d: "--ro-bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") bindReadonly);
      rw = lib.concatStringsSep " "
        (map (d: "--bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") bindReadwrite);
    in
    "${ro} ${rw}";

  # ── runtime secrets → shell env assignments ──────────────────────────
  # Each secret is `{ var = "SOME_ENV"; file = "/run/agenix/some-key"; }`.
  # The file is read at RUN time by the launcher, never at build time, so the
  # plaintext never lands in the store. `[]` renders to nothing.
  secretEnvAssignments = secrets:
    lib.concatStrings (map (s: ''${s.var}="$(cat ${lib.escapeShellArg s.file})" '') secrets);

  # ── generic bwrap compartment ───────────────────────────────────────
  # DEFAULT-DENY bind. The real $HOME is NOT bound. The compartment's HOME
  # is `<stateDir>/<homeSubdir>`, so the rest of the real home — ~/.ssh,
  # ~/.aws, browser profiles, sibling compartments — is simply absent
  # inside the jail. XDG_RUNTIME_DIR points at a tmpfs so the compartment
  # gets a fresh runtime dir instead of the real session sockets
  # (wayland/pulse).
  #
  #   name          compartment identity (used in the script name)
  #   stateDirExpr  SHELL expression for the host-side state dir, e.g.
  #                 ''"$HOME/.compartments/foo"'' — evaluated at run time so
  #                 it can depend on $HOME.
  #   stateEnvVar   optional env var pointing at the state dir itself
  #                 (e.g. "HERMES_HOME"), distinct from HOME.
  #   homeSubdir    subdir of the state dir used as HOME inside. Default "home".
  #   command       RAW argv string run inside the compartment, e.g.
  #                 ''"${pkg}/bin/foo -p bar"''. Deliberately not a list and
  #                 deliberately not shell-escaped: this comes from aspect
  #                 config (declared, reviewed, built-in), never from runtime
  #                 input, and escaping it would rewrite the very command
  #                 line the tests pin. Treat it like a template in a
  #                 Makefile, not like user data.
  #   packages      packages providing PATH inside the compartment.
  #   env           extra --setenv pairs.
  mkBwrapCompartment = pkgs:
    { name
    , stateDirExpr
    , stateEnvVar ? null
    , homeSubdir ? "home"
    , command
    , packages ? [ ]
    , env ? { }
    , bindReadonly ? [ ]
    , bindReadwrite ? [ ]
    , label ? "compartment-${name}"
    , stateVar ? "STATE"
    }:
    let
      roBinds = lib.concatStringsSep " "
        (map (d: "--ro-bind-try ${lib.escapeShellArg d} ${lib.escapeShellArg d}") bindReadonly);
      rwBinds = lib.concatStringsSep " "
        (map (d: "--bind ${lib.escapeShellArg d} ${lib.escapeShellArg d}") bindReadwrite);
      envArgs = lib.concatStringsSep " "
        (lib.mapAttrsToList (k: v: "--setenv ${k} \"${v}\"") env);
      path = lib.makeBinPath packages;
      stateEnvLine =
        if stateEnvVar == null then ""
        else ''--setenv ${stateEnvVar} "$${stateVar}" \'';
    in
    pkgs.writeShellScriptBin label ''
      set -eu
      : "''${HOME:?HOME must be set (the compartment state lives under it)}"
      ${stateVar}=${stateDirExpr}
      mkdir -p "$${stateVar}/${homeSubdir}"
      exec ${pkgs.bubblewrap}/bin/bwrap \
        --die-with-parent \
        --new-session \
        --dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --ro-bind /nix/store /nix/store \
        --ro-bind /etc /etc \
        --ro-bind-try /run/current-system/sw /run/current-system/sw \
        --bind "$${stateVar}" "$${stateVar}" \
        ${roBinds} \
        ${rwBinds} \
        --unsetenv LD_PRELOAD \
        --setenv HOME "$${stateVar}/${homeSubdir}" \
        ${stateEnvLine} \
        --setenv XDG_RUNTIME_DIR /tmp \
        --setenv PATH "${path}" \
        ${envArgs} \
        -- ${command} "$@"
    '';

  # ── generic munix microVM compartment ───────────────────────────────
  # Boots a declared NixOS toplevel closure in a KVM microVM via munix. The
  # bind allowlist is passed as virtiofs mounts; the network posture maps to
  # `--no-network`. The guest closure is a declared input (built by the host
  # or a separate aspect); this launcher only wires the flags.
  #
  # State delivery mirrors the bwrap jail: the host activation renders the
  # compartment's declared config into `stateDirExpr` on the host, and the
  # launcher binds THAT directory read-write into the VM so learned state
  # persists back. Only this compartment's dir is bound, so siblings stay
  # isolated.
  #
  #   closure       the NixOS toplevel the guest boots (a store path)
  #   command       RAW argv string run inside the guest after the `--`
  #                 terminator (same convention as mkBwrapCompartment above)
  #   guestEnv      env assignments prefixed to the guest command (a raw
  #                 shell fragment — see secretEnvAssignments)
  mkMunixCompartment = pkgs:
    { name
    , munixPackage
    , closure
    , stateDirExpr
    , stateEnvVar ? null
    , homeSubdir ? "home"
    , command
    , bindReadonly ? [ ]
    , bindReadwrite ? [ ]
    , network ? "full"
    , gpu ? false
    , storeSlice ? null
    , guestEnv ? ""
    , label ? "munix-${name}"
    , what ? label
    , stateVar ? "STATE"
    }:
    let
      stateEnvAssign =
        if stateEnvVar == null then ""
        else ''${stateEnvVar}="$${stateVar}" '';
    in
    pkgs.writeShellScriptBin label ''
      set -eu
      CLOSURE="${closure}"
      if [ -z "$CLOSURE" ]; then
        echo "${label}: closure is not set (required for enforcement = munix)" >&2
        exit 1
      fi
      : "''${HOME:?HOME must be set (the compartment state lives under it)}"
      ${stateVar}=${stateDirExpr}
      mkdir -p "$${stateVar}/${homeSubdir}"
      exec ${munixPackage}/bin/munix \
        ${virtFlags { inherit network gpu; }} \
        ${storeSliceFlags what storeSlice} \
        --bind "$${stateVar}" "$${stateVar}" \
        ${munixBindFlags { inherit bindReadonly bindReadwrite; }} \
        "$CLOSURE" -- \
        env ${guestEnv}${stateEnvAssign}HOME="$${stateVar}/${homeSubdir}" ${command} "$@"
    '';

  # ── preserve-learned-keys merge (generic) ───────────────────────────
  # Deep-merge a declared config over an existing one. Declared keys win;
  # keys the program LEARNED at run time are kept. This is what makes an
  # immutable closure compatible with mutable user settings: the closure
  # declares, the state dir accumulates, and activation reconciles them
  # without either side clobbering the other.
  #
  # YAML-aware (programs write YAML; declared files are JSON, which is valid
  # YAML). A corrupt or unreadable existing file is treated as empty rather
  # than aborting the activation.
  mergeDeclaredOverLearned = pkgs:
    let
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    pkgs.writeShellScript "merge-declared-over-learned" ''
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
}
