# lib/hermes-jail.nix — hermes-specific config generation + compartment wiring.
#
# This file used to own the containment mechanics. It no longer does: those
# moved to ./compartment.nix, because they turned out to carry no hermes
# content. What remains here is the two genuinely app-specific holes:
#
#   1. WHAT gets rendered into the compartment's state dir
#      — config.yaml (mcp_servers + settings, with provider inference)
#      — SOUL.md (the persona)
#      — and the preserve-learned merge that reconciles declared vs learned
#
#   2. WHAT runs inside, and under which identity
#      — `hermes -p <name>`, with HERMES_HOME at the profile dir
#
# Everything else — default-deny binds, store-slice dispatch, headless
# flags, runtime secret injection — is the generic shape in compartment.nix
# and is shared with every future "run this app as a VM" aspect.
#
# This file lives OUTSIDE modules/ on purpose: den's import-tree loads every
# .nix under modules/ as a module, so shared pure functions can't live
# there (they'd be eval'd as broken aspects). Both the aspect and its tests
# import this file directly.
#
# The security model is documented in ./compartment.nix and is unchanged.

{ lib }:
let
  c = import ./compartment.nix { inherit lib; };
in
rec {
  # ── declared config.yaml ───────────────────────────────────────────
  # JSON is a subset of YAML, so this renders a valid config.yaml body.
  # `mcp_servers` is the compartment's tools; `settings` are extra
  # behavioral keys merged in (declared wins over learned).
  #
  # Provider inference: hermes requires an EXPLICIT `model.provider`. A
  # profile that declares only `model.base_url` + `model.default` fails at
  # agent init with
  #   ProviderNotConfiguredError: No LLM provider configured
  # (verified live against hermes-agent 0.22.5 in the munix guest). A
  # declared `base_url` is by definition a custom OpenAI-compatible
  # endpoint, so fill in `provider = "custom"` — but ONLY when the profile
  # declares a base_url and does NOT already declare a provider, so an
  # explicit provider always wins and a profile that declares no `model`
  # section at all is left completely untouched.
  declaredConfig = name: prof:
    let
      settings = prof.settings or { };
      model = if builtins.isAttrs (settings.model or null) then settings.model else null;
      needsProvider =
        model != null && (model ? base_url) && !(model ? provider);
      settings' =
        if needsProvider then
          settings // { model = model // { provider = "custom"; }; }
        else
          settings;
    in
    builtins.toJSON (
      {
        mcp_servers = lib.mapAttrs (_: s: {
          command = s.command;
          args = s.args;
          env = s.env;
        }) prof.mcpServers;
      }
      // settings'
    );

  renderProfileConfig = pkgs: name: prof:
    pkgs.writeText "hermes-profile-${name}-config.json" (declaredConfig name prof);

  renderProfileSoul = pkgs: name: prof:
    pkgs.writeText "hermes-profile-${name}-SOUL.md" prof.soul;

  # Preserve-learned-keys merge. Now generic — see
  # compartment.mergeDeclaredOverLearned. Kept under this name because the
  # aspect's home.activation calls it, and because "merge the declared
  # config over what the agent learned" is the hermes phrasing of a general
  # rule.
  mergeScript = c.mergeDeclaredOverLearned;

  # ── bwrap-enforced jail: DEFAULT-DENY bind ─────────────────────────
  # The mechanics are generic; the hermes parts are the identity
  # (`hermes -p <name>`), the state dir (`~/.hermes/profiles/<name>`), and
  # HERMES_HOME pointing at it.
  #
  # `stateVar = "PH"` (profile home) keeps the generated script identical
  # to the pre-extraction one, so the existing default-deny tests remain a
  # valid regression net without being edited to match the refactor.
  mkBwrapJail = pkgs: hermesPkg: name: prof:
    c.mkBwrapCompartment pkgs {
      inherit name;
      label = "hermes-jailed-${name}";
      stateVar = "PH";
      stateDirExpr = ''"$HOME/.hermes/profiles/${name}"'';
      stateEnvVar = "HERMES_HOME";
      homeSubdir = "home";
      command = "${hermesPkg}/bin/hermes -p ${name}";
      packages = [ hermesPkg ] ++ (prof.extraPackages or [ ]);
      env = prof.env or { };
      bindReadonly = prof.bindReadonly or [ ];
      bindReadwrite = prof.bindReadwrite or [ ];
    };

  # ── munix-enforced microVM launcher ────────────────────────────────
  # Boots the declared NixOS toplevel closure in a KVM microVM via munix.
  #
  # Profile-config delivery mirrors the bwrap jail: the host activation
  # renders this profile's config.yaml + SOUL.md into
  # $HOME/.hermes/profiles/<name>, and the launcher binds THAT directory
  # read-write into the VM so learned keys and session state persist back
  # to the host. Only this profile's dir is bound, so sibling profiles stay
  # isolated. Without this the VM's hermes boots with no soul, no settings,
  # and no MCP servers.
  #
  # The model key is the runtime-secret case: `modelKeySecret` names a
  # DECRYPTED file (agenix /run/agenix/<n> or sops /run/secrets/<n>) that
  # the launcher reads at run time and passes in as HERMES_MODEL_KEY. It is
  # never a build-time string — the closure is the guest's store-visibility
  # allowlist, so a baked secret would be visible to everything that can
  # see the closure.
  mkMunixLauncher = pkgs: munixPkg: name: prof:
    let
      keySecret =
        if prof.modelKeySecret or null != null
        then [ { var = "HERMES_MODEL_KEY"; file = prof.modelKeySecret; } ]
        else [ ];
    in
    c.mkMunixCompartment pkgs {
      inherit name;
      label = "hermes-munix-${name}";
      what = "deniac.ai.hermes";
      stateVar = "PH";
      munixPackage = munixPkg;
      closure = prof.munixClosure;
      stateDirExpr = ''"$HOME/.hermes/profiles/${name}"'';
      stateEnvVar = "HERMES_HOME";
      homeSubdir = "home";
      command = "hermes -p ${name}";
      network = prof.network or "full";
      gpu = prof.gpu or false;
      storeSlice = prof.storeSlice or null;
      guestEnv = c.secretEnvAssignments keySecret;
      bindReadonly = prof.bindReadonly or [ ];
      bindReadwrite = prof.bindReadwrite or [ ];
    };
}
