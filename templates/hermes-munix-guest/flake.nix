# munix-guest — a PARAMETRIC microVM guest builder.
#
# THE CLOSURE IS THE SYSTEM (per app).
# A munix guest boots its OWN NixOS closure (boot.isContainer = true, erofs
# root): its /run/current-system, PATH, and default package set are all this
# closure. NOTE (verified 2026-10-08): the closure is a set of *symlinks* to
# store paths — it does NOT contain /nix/store. The munix runner mounts the
# HOST's whole /nix/store read-only (runner line 302, unconditional), so the
# guest can see every host package. The closure scopes the guest's SYSTEM,
# NOT its store visibility. (True store isolation — the guest seeing only its
# own closure's paths — is the d2b "hardlink farm" model, which munix lacks.)
# The real blast-radius limit is the separate kernel + the un-bound host
# /home, /etc, /run (no user data, no secrets).
#
# This is the reusable foundation for sandboxing MANY desktop apps the same
# way — not just Hermes. Each app gets its own closure via `mkGuest`:
#
#   researcher  = mkGuest { app = hermes; graphics = false; ... }   # headless
#   steam-guest = mkGuest { app = steam;  graphics = true;  ... }   # full GPU
#
# `graphics = false` drops mesa entirely (headless agents). `graphics = true`
# pulls the full GPU stack (games / GUI apps). The mesa build is a SHARED
# cached closure: built once, reused by every graphics=true guest on the same
# pin — so slimming the researcher is a pure win, and the GPU guests still
# get everything they need.
#
# Trust note: keep DIFFERENT-trust apps in DIFFERENT closures/VMs. Never let
# an untrusted app's closure share a hermes kanban board with a trusted one —
# the shared board is the confused-deputy surface. Cross-trust handoff is a
# human gate, not kanban/peer automation.
{
  description = "Parametric munix microVM guest builder (closure = per-app system definition; store is shared ro by munix)";

  # munix's binary cache — without it the guest closure builds from source.
  nixConfig = {
    extra-substituters = [ "https://cache.clan.lol" ];
    extra-trusted-public-keys = [
      "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
    ];
  };

  inputs = {
    # Fork pin (2026-10-10): sjdevries/munix feat/closure-only-store
    # carries --store-dev/--sandbox-store (erofs block-device store
    # slice), not yet in upstream main. Superseding PR: clan/munix #38.
    # Re-point to clan/munix once that merges.
    munix.url = "git+https://git.clan.lol/sjdevries/munix?shallow=1&ref=feat/closure-only-store";
    nixpkgs.follows = "munix/nixpkgs";
    # Same hermes pin deniac uses, so the guest agent == the host agent.
    llm-agents.url = "github:numtide/llm-agents.nix/32f95b57bd11604871fb663c6724da15112860ee";
  };

  outputs =
    { munix, nixpkgs, llm-agents, ... }:
    let
      system = "x86_64-linux";
      hermes = llm-agents.packages.${system}.hermes-agent;

      # ── The parametric builder ───────────────────────────────────────
      # mkGuest { app, graphics, packages, defaultCommand, extraModules }
      #   app            the one application this VM exists to run
      #   graphics       false → no mesa (headless); true → full GPU stack
      #   packages       extra packages the app needs (added to the allowlist)
      #   defaultCommand what runs on boot with no args (the launcher overrides)
      #   extraModules   any additional NixOS modules for this guest
      #
      # Returns the nixosSystem; take .config.system.build.munix for the
      # wrapped launcher, or .config.system.build.toplevel for the raw
      # closure the deniac launcher's munixClosure points at.
      mkGuest =
        {
          app,
          graphics ? false,
          packages ? [ ],
          defaultCommand ? "bash",
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            munix.nixosModules.default
            (
              { pkgs, lib, ... }:
              {
                system.stateVersion = "26.05";
                nixpkgs.hostPlatform = system;

                # The munix module hard-sets graphics=true; mkForce lets the
                # caller turn it OFF for headless agents (dropping mesa).
                hardware.graphics.enable = lib.mkForce graphics;

                # The allowlist: the app + whatever it genuinely needs.
                environment.systemPackages = [ app ] ++ packages;

                virtualisation.munix.defaultCommand = defaultCommand;
              }
            )
          ]
          ++ extraModules;
        };
    in
    {
      # The reusable builder — other flakes: inputs.<this-flake>.lib.mkGuest { … }
      lib.mkGuest = mkGuest;

      packages.${system} =
        let
          # Instance #1 — the headless researcher: hermes, NO graphics.
          researcherGuest = mkGuest {
            app = hermes;
            graphics = false;
            defaultCommand = "hermes -p researcher";
          };
        in
        {
          # The wrapped launcher — bakes MICROVM_DEFAULT_COMMAND, run directly.
          researcher = researcherGuest.config.system.build.munix;

          # The RAW toplevel — the closure the deniac `ai.hermes` launcher's
          # `munixClosure` points at (that launcher supplies its own
          # `hermes -p <name>` + binds, so it wants the bare closure, not the
          # baked launcher). A consumer flake wires it as:
          #   munixPackage = <munix>;
          #   munixClosure = toString inputs.<this>.packages.${system}.researcher-toplevel;
          researcher-toplevel = researcherGuest.config.system.build.toplevel;

          # Re-expose the munix runner so a consumer needs only THIS one input
          # for both the closure and the launcher binary (the runner is pinned
          # to the same munix the guest was built against — they must match).
          munix = munix.packages.${system}.munix;
        };

      # Instance #2 — the GPU pattern (Steam). Unfree, so left as the
      # shape to copy rather than a built output:
      #
      # steam = (mkGuest {
      #   app = nixpkgs.legacyPackages.${system}.steam;
      #   graphics = true;
      #   packages = [ ];   # + any game-specific libs
      # }).config.system.build.munix;
    };
}
