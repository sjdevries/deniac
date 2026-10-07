# hermes-munix-guest — a minimal munix microVM guest for a Hermes role profile.
#
# THE CLOSURE IS THE POLICY.
# A munix guest boots its OWN NixOS closure (boot.isContainer = true, erofs
# root). The guest's /nix/store *is* this closure — it cannot see the host's
# store at all. So whatever you list here is the entire universe the VM can
# see and run. A minimal closure = minimal store visibility = minimal
# capability. This is the store-level default-deny that the bwrap tier cannot
# give you (bwrap binds the host /nix/store read-only, so the agent sees
# every package on the host).
#
# Build the toplevel, point the deniac launcher's `munixClosure` at it, and
# the researcher compartment runs inside this closure — nothing more.
{
  description = "Minimal munix microVM guest for the Hermes researcher (closure = store-visibility allowlist)";

  # munix's own binary cache — without it the guest closure builds from source
  # (slow). Harmless to keep; it only substitutes, never executes.
  nixConfig = {
    extra-substituters = [ "https://cache.clan.lol" ];
    extra-trusted-public-keys = [
      "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
    ];
  };

  inputs = {
    munix.url = "git+https://git.clan.lol/clan/munix?shallow=1&ref=main";
    nixpkgs.follows = "munix/nixpkgs";
    # Same hermes pin deniac uses, so the guest agent == the host agent.
    llm-agents.url = "github:numtide/llm-agents.nix/32f95b57bd11604871fb663c6724da15112860ee";
  };

  outputs =
    { munix, nixpkgs, llm-agents, ... }:
    let
      system = "x86_64-linux";
      hermes = llm-agents.packages.${system}.hermes-agent;

      guest = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          munix.nixosModules.default
          (
            { pkgs, ... }:
            {
              system.stateVersion = "26.05";
              nixpkgs.hostPlatform = system;

              # ── The allowlist ──────────────────────────────────────────
              # hermes is the only app. The base system still provides bash +
              # coreutils (essential, not part of the stripped defaultPackages).
              # Add a tool here ONLY if the researcher genuinely needs it —
              # each entry widens what the VM can see and reach.
              environment.systemPackages = [ hermes ];

              # What runs when the VM starts with no command. The deniac
              # launcher overrides this with `hermes -p <name>`.
              virtualisation.munix.defaultCommand = "hermes -p researcher";
            }
          )
        ];
      };
    in
    {
      packages.${system} = {
        # The wrapped launcher (toplevel + default command baked in). Easiest
        # to run directly: ./result/bin/munix --bind <profile-home> <dst>
        default = guest.config.system.build.munix;

        # The raw toplevel — this is what the deniac launcher's
        # `munixClosure` option points at (the launcher passes it to the
        # raw munix binary alongside its own flags).
        toplevel = guest.config.system.build.toplevel;
      };
    };
}
