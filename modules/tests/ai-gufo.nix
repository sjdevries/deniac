# Tests for `ai.gufo` — same fresh-eval pattern as
# tests/ai-halogen-flash-server.nix: each denTest re-registers the
# `deniac` namespace from `inputs.self`, so `deniac.ai.gufo` resolves in
# the fresh eval. Projections are flat leaf selections (nix-unit 2.x
# deep-forces `expr` and deep-compares, so selecting a whole submodule
# whose leaves may be undefined throws).

{ denTest, ... }:
{
  flake.tests.ai-gufo = {

    # Consumer-facing guarantee: once the `deniac` namespace is imported
    # from `inputs.self`, `deniac.ai.gufo` resolves to a usable den
    # aspect (description + a NixOS module under `nixos`).
    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.gufo.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.gufo.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    # Nothing set: the aspect is entirely inert — no podman, no user
    # service, no linger, no firewall hole, no modprobe option — and the
    # option defaults hold.
    test-inert-by-default = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.gufo ];

        expr = {
          podmanEnable = igloo.virtualisation.podman.enable;
          userService = igloo.systemd.user.services.gufo or null;
          linger = igloo.users.users.gufo.linger or null;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
          modprobe = inputs.nixpkgs.lib.filter (l: l != "")
            (inputs.nixpkgs.lib.splitString "\n" igloo.boot.extraModprobeConfig);
          enable = igloo.deniac.ai.gufo.enable;
          port = igloo.deniac.ai.gufo.port;
          speculative = igloo.deniac.ai.gufo.speculative;
          gib = igloo.deniac.ai.gufo.gib;
        };
        expected = {
          podmanEnable = false;
          userService = null;
          linger = null;
          firewallPorts = [ ];
          modprobe = [ ];
          enable = false;
          port = 8080;
          speculative = "mtp";
          gib = null;
        };
      }
    );

    # enable = true: podman on, the rootless user service defined with
    # lingering on the service user, the models dir mounted READ-ONLY,
    # and a firewall hole on the published port.
    test-enabled = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.gufo ];
        den.aspects.igloo.nixos.deniac.ai.gufo.enable = true;

        expr = {
          podmanEnable = igloo.virtualisation.podman.enable;
          linger = igloo.users.users.gufo.linger;
          extraGroups = igloo.users.users.gufo.extraGroups;
          restart = igloo.systemd.user.services.gufo.serviceConfig.Restart;
          timeoutStartSec = igloo.systemd.user.services.gufo.serviceConfig.TimeoutStartSec;
          execStartIsSet = builtins.isString igloo.systemd.user.services.gufo.serviceConfig.ExecStart;
          # The generated runner must mount the models dir READ-ONLY as
          # /models:ro — assert the actual `-v` argument (a config-shape
          # assertion alone lets a typo ship that podman rejects at start).
          mountArg =
            let
              lib' = inputs.nixpkgs.lib;
              script = builtins.readFile igloo.systemd.user.services.gufo.serviceConfig.ExecStart;
              line = lib'.findFirst (lib'.hasInfix "-v ") "" (lib'.splitString "\n" script);
            in builtins.elemAt (builtins.match ".* -v ([^ ]+).*" line) 0;
          wantedBy = igloo.systemd.user.services.gufo.wantedBy;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
        };
        expected = {
          podmanEnable = true;
          linger = true;
          extraGroups = [ "render" "video" ];
          restart = "always";
          timeoutStartSec = "infinity";
          execStartIsSet = true;
          mountArg = "/var/lib/gufo-models:/models:ro";
          wantedBy = [ "default.target" ];
          firewallPorts = [ 8080 ];
        };
      }
    );

    # List options merge across definitions: the host's ports and the
    # aspect's port both stay. Sorted (same-priority list concatenation
    # follows module order, which is not part of the contract).
    test-firewall-merges-with-host = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.gufo ];
        den.aspects.igloo.nixos.deniac.ai.gufo.enable = true;
        den.aspects.igloo.nixos.networking.firewall.allowedTCPPorts = [ 443 ];

        expr = inputs.nixpkgs.lib.sort inputs.nixpkgs.lib.lessThan igloo.networking.firewall.allowedTCPPorts;
        expected = [ 443 8080 ];
      }
    );

    # memoryLow = "32G": the reclaim protection lands on a declared
    # `gufo.slice` in the service user's own manager tree
    # (`systemd.user.slices` — rootless shape), and the runner nests
    # the container under it with `--cgroup-parent=gufo.slice`.
    test-memorylow-user-slice = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.gufo ];
        den.aspects.igloo.nixos.deniac.ai.gufo.enable = true;
        den.aspects.igloo.nixos.deniac.ai.gufo.memoryLow = "32G";

        expr = {
          sliceLow = igloo.systemd.user.slices.gufo.sliceConfig.MemoryLow;
          runnerNests =
            inputs.nixpkgs.lib.hasInfix "--cgroup-parent=gufo.slice"
            (builtins.readFile igloo.systemd.user.services.gufo.serviceConfig.ExecStart);
        };
        expected = {
          sliceLow = "32G";
          runnerNests = true;
        };
      }
    );

    # memoryLow unset (default null) with the service enabled: no
    # `gufo` user slice is defined and the runner carries no
    # `--cgroup-parent` — default placement, byte-identical to the
    # pre-option behaviour.
    test-memorylow-default-inert = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.gufo ];
        den.aspects.igloo.nixos.deniac.ai.gufo.enable = true;

        expr = {
          sliceDefined = igloo.systemd.user.slices ? gufo;
          runnerNests =
            inputs.nixpkgs.lib.hasInfix "--cgroup-parent"
            (builtins.readFile igloo.systemd.user.services.gufo.serviceConfig.ExecStart);
        };
        expected = {
          sliceDefined = false;
          runnerNests = false;
        };
      }
    );

    # gib = 120 (standalone-host GTT ceiling): emitted as the ttm
    # pages_limit modprobe option (120 GiB * 262144 = 31457280 pages).
    test-gib-modprobe = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.gufo ];
        den.aspects.igloo.nixos.deniac.ai.gufo.gib = 120;

        expr = inputs.nixpkgs.lib.filter (l: l != "")
          (inputs.nixpkgs.lib.splitString "\n" igloo.boot.extraModprobeConfig);
        expected = [ "options ttm pages_limit=31457280" ];
      }
    );
  };
}
