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
          firewallPorts = igloo.services.firewall.allowedTCPPorts;
          modprobe = igloo.boot.extraModprobeConfig;
          enable = igloo.deniac.ai.halogen-flash-server.enable;
          port = igloo.deniac.ai.halogen-flash-server.port;
          download = igloo.deniac.ai.halogen-flash-server.download;
          gib = igloo.deniac.ai.halogen-flash-server.gib;
        };
        expected = {
          podmanEnable = false;
          service = null;
          firewallPorts = [ ];
          modprobe = "";
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
          serviceEnabled = igloo.systemd.services.halogen-flash.enable;
          stateDirectory = igloo.systemd.services.halogen-flash.serviceConfig.StateDirectory;
          supplementaryGroups = igloo.systemd.services.halogen-flash.serviceConfig.SupplementaryGroups;
          restart = igloo.systemd.services.halogen-flash.serviceConfig.Restart;
          timeoutStartSec = igloo.systemd.services.halogen-flash.serviceConfig.TimeoutStartSec;
          execStartIsSet = builtins.isString igloo.systemd.services.halogen-flash.serviceConfig.ExecStart;
          wantedBy = igloo.systemd.services.halogen-flash.wantedBy;
          firewallPorts = igloo.services.firewall.allowedTCPPorts;
        };
        expected = {
          podmanEnable = true;
          serviceEnabled = true;
          stateDirectory = "halogen-models";
          supplementaryGroups = [ "render" "video" ];
          restart = "always";
          timeoutStartSec = "infinity";
          execStartIsSet = true;
          wantedBy = [ "multi-user.target" ];
          firewallPorts = [ 8731 ];
        };
      }
    );

    # The firewall hole stays overridable: a host list at default priority
    # wins over the aspect's mkDefault (the host owns its firewall).
    test-firewall-overridable = denTest (
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
        den.aspects.igloo.nixos.services.firewall.allowedTCPPorts = [ 443 ];

        expr = igloo.services.firewall.allowedTCPPorts;
        expected = [ 443 ];
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

        expr = igloo.boot.extraModprobeConfig;
        expected = "options ttm pages_limit=31457280\n";
      }
    );
  };
}
