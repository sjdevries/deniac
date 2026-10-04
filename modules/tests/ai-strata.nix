# Tests for `ai.strata` — same fresh-eval pattern as tests/ai-gufo.nix.
# Flat leaf selections (nix-unit 2.x deep-forces `expr`).

{ denTest, ... }:
{
  flake.tests.ai-strata = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.strata.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.strata.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    test-inert-by-default = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.strata ];

        expr = {
          service = igloo.systemd.services.strata or null;
          user = igloo.users.users.strata or null;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
          enable = igloo.deniac.ai.strata.enable;
          model = igloo.deniac.ai.strata.model;
          port = igloo.deniac.ai.strata.port;
        };
        expected = {
          service = null;
          user = null;
          firewallPorts = [ ];
          enable = false;
          model = "IQ2_XS";
          port = 8080;
        };
      }
    );

    # enable = true: a system service around the installed run script,
    # the service user with render/video, the store GGUF dir wired, and
    # no firewall hole (loopback bind).
    test-enabled = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.strata ];
        den.aspects.igloo.nixos.deniac.ai.strata.enable = true;

        expr = {
          user = igloo.users.users.strata.isSystemUser;
          extraGroups = igloo.users.users.strata.extraGroups;
          wantedBy = igloo.systemd.services.strata.wantedBy;
          restart = igloo.systemd.services.strata.serviceConfig.Restart;
          ggufDir = igloo.deniac.ai.strata.ggufDir;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
          # The runner runs the installed run-<model>.sh with --gguf-dir.
          runsInstalled =
            let lib' = inputs.nixpkgs.lib;
            in builtins.any (lib'.hasInfix "/opt/strata/run-IQ2_XS.sh")
                 (lib'.splitString "\n"
                   (builtins.readFile igloo.systemd.services.strata.serviceConfig.ExecStart));
        };
        expected = {
          user = true;
          extraGroups = [ "render" "video" ];
          wantedBy = [ "multi-user.target" ];
          restart = "always";
          ggufDir = "/var/lib/ai-models/gguf";
          firewallPorts = [ ];
          runsInstalled = true;
        };
      }
    );

    # Batteries-included: with the store included, the GGUF dir follows
    # the store's `gguf` path, and a custom store root propagates.
    test-model-store-wiring = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.strata ];
        den.aspects.igloo.nixos.deniac.ai.strata.enable = true;

        expr = igloo.deniac.ai.strata.ggufDir;
        expected = "/var/lib/ai-models/gguf";
      }
    );

    test-model-store-wiring-follows-custom-root = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.strata ];
        den.aspects.igloo.nixos.deniac.ai.strata.enable = true;
        den.aspects.igloo.nixos.deniac.ai.model-store.root = "/srv/models";

        expr = igloo.deniac.ai.strata.ggufDir;
        expected = "/srv/models/gguf";
      }
    );
  };
}
