# Tests for `ai.halogen-flash-server` — same fresh-eval pattern as
# tests/ai-amd-strix.nix: each denTest re-registers the `deniac` namespace
# from `inputs.self` (the deniac flake itself), because the aspect under
# test lives in a separate tree file that the fresh eval does not load.
# `deniac` is a module-arg in that fresh eval, so
# `deniac.ai.halogen-flash-server` resolves.
#
# Projections are flat leaf selections: nix-unit 2.x deep-forces `expr`
# and deep-compares, so selecting a whole submodule (whose leaves may be
# undefined) throws.

{ denTest, ... }:
{
  flake.tests.ai-halogen-flash-server = {

    # Consumer-facing guarantee: once the `deniac` namespace is imported
    # from `inputs.self`, `deniac.ai.halogen-flash-server` resolves to a
    # usable den aspect (description + a NixOS module under `nixos`).
    test-namespace-export = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.halogen-flash-server.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.halogen-flash-server.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    # Nothing set: the aspect is entirely inert — no podman, no service,
    # no firewall hole, no modprobe option — and the option defaults hold.
    test-inert-by-default = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.halogen-flash-server ];

        expr = {
          podmanEnable = igloo.virtualisation.podman.enable;
          service = igloo.systemd.services.halogen-flash or null;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
          modprobe = inputs.nixpkgs.lib.filter (l: l != "")
            (inputs.nixpkgs.lib.splitString "\n" igloo.boot.extraModprobeConfig);
          enable = igloo.deniac.ai.halogen-flash-server.enable;
          port = igloo.deniac.ai.halogen-flash-server.port;
          download = igloo.deniac.ai.halogen-flash-server.download;
          gib = igloo.deniac.ai.halogen-flash-server.gib;
        };
        expected = {
          podmanEnable = false;
          service = null;
          firewallPorts = [ ];
          modprobe = [ ]; # no non-empty modprobe lines (baseline is empty lines only)
          enable = false;
          port = 8731;
          download = true;
          gib = null;
        };
      }
    );

    # enable = true: podman on, the service defined with GPU access and
    # the StateDirectory, and a firewall hole on the published port.
    test-enabled = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.halogen-flash-server ];
        den.aspects.igloo.nixos.deniac.ai.halogen-flash-server.enable = true;

        expr = {
          podmanEnable = igloo.virtualisation.podman.enable;
          stateDirectory = igloo.systemd.services.halogen-flash.serviceConfig.StateDirectory;
          supplementaryGroups = igloo.systemd.services.halogen-flash.serviceConfig.SupplementaryGroups;
          restart = igloo.systemd.services.halogen-flash.serviceConfig.Restart;
          timeoutStartSec = igloo.systemd.services.halogen-flash.serviceConfig.TimeoutStartSec;
          execStartIsSet = builtins.isString igloo.systemd.services.halogen-flash.serviceConfig.ExecStart;
          # The generated runner script must mount the models dir as
          # /models — assert the actual `-v` argument. A config-shape
          # assertion alone lets a typo (":+/models") ship, which podman
          # rejects at start with exit 125.
          mountArg =
            let
              lib' = inputs.nixpkgs.lib;
              script = builtins.readFile igloo.systemd.services.halogen-flash.serviceConfig.ExecStart;
              line = lib'.findFirst (lib'.hasInfix "-v ") "" (lib'.splitString "\n" script);
            in builtins.elemAt (builtins.match ".* -v ([^ ]+).*" line) 0;
          wantedBy = igloo.systemd.services.halogen-flash.wantedBy; # non-empty → enabled
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
        };
        expected = {
          podmanEnable = true;
          stateDirectory = "halogen-models";
          supplementaryGroups = [ "render" "video" ];
          restart = "always";
          timeoutStartSec = "infinity";
          execStartIsSet = true;
          mountArg = "/var/lib/halogen-models:/models";
          wantedBy = [ "multi-user.target" ];
          firewallPorts = [ 8731 ];
        };
      }
    );

    # List options merge across definitions: the host's ports and the
    # aspect's port both stay (the host never loses its holes, the aspect
    # never loses its API port). Sorted: same-priority list concatenation
    # follows module order, which is not part of the contract.
    test-firewall-merges-with-host = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.halogen-flash-server ];
        den.aspects.igloo.nixos.deniac.ai.halogen-flash-server.enable = true;
        den.aspects.igloo.nixos.networking.firewall.allowedTCPPorts = [ 443 ];

        expr = inputs.nixpkgs.lib.sort inputs.nixpkgs.lib.lessThan igloo.networking.firewall.allowedTCPPorts;
        expected = [ 443 8731 ];
      }
    );

    # gib = 120 (standalone-host GTT ceiling): emitted as the ttm
    # pages_limit modprobe option (120 GiB * 262144 pages/GiB = 31457280
    # 4 KiB pages).
    test-gib-modprobe = denTest (
      {
        inputs,
        den,
        deniac,
        igloo,
        ...
      }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.halogen-flash-server ];
        den.aspects.igloo.nixos.deniac.ai.halogen-flash-server.gib = 120;

        # `boot.extraModprobeConfig` concatenates every module's lines
        # (the host baseline already contributes empty lines, and the
        # surrounding order is not part of the contract), so reduce to
        # the non-empty lines and assert the ttm line is the only one.
        expr = inputs.nixpkgs.lib.filter (l: l != "")
          (inputs.nixpkgs.lib.splitString "\n" igloo.boot.extraModprobeConfig);
        expected = [ "options ttm pages_limit=31457280" ];
      }
    );
  };
}
