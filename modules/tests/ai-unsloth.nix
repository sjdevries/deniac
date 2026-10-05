# Tests for `ai.unsloth` — same fresh-eval pattern as tests/ai-gufo.nix.
# Flat leaf selections (nix-unit 2.x deep-forces `expr`).

{ denTest, ... }:
{
  flake.tests.ai-unsloth = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.unsloth.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.unsloth.nixos;
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
        den.aspects.igloo.includes = [ deniac.ai.unsloth ];

        expr = {
          podmanEnable = igloo.virtualisation.podman.enable;
          userService = igloo.systemd.user.services.unsloth or null;
          linger = igloo.users.users.unsloth.linger or null;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
          enable = igloo.deniac.ai.unsloth.enable;
          image = igloo.deniac.ai.unsloth.image;
          host = igloo.deniac.ai.unsloth.host;
          port = igloo.deniac.ai.unsloth.port;
        };
        expected = {
          podmanEnable = false;
          userService = null;
          linger = null;
          firewallPorts = [ ];
          enable = false;
          image = "unsloth/unsloth-rocm:latest";
          host = "127.0.0.1";
          port = 8000;
        };
      }
    );

    # enable = true: podman on, rootless user service with linger +
    # render/video + the store group, the HF cache mounted at the
    # container's cache path, and NO firewall hole (loopback bind).
    test-enabled = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;

        expr = {
          podmanEnable = igloo.virtualisation.podman.enable;
          linger = igloo.users.users.unsloth.linger;
          extraGroups = igloo.users.users.unsloth.extraGroups;
          restart = igloo.systemd.user.services.unsloth.serviceConfig.Restart;
          timeoutStartSec = igloo.systemd.user.services.unsloth.serviceConfig.TimeoutStartSec;
          wantedBy = igloo.systemd.user.services.unsloth.wantedBy;
          firewallPorts = igloo.networking.firewall.allowedTCPPorts;
          # The runner mounts the HF cache at the container's cache path.
          hfMount =
            let lib' = inputs.nixpkgs.lib;
            in builtins.any (lib'.hasInfix "/workspace/.cache/huggingface")
                 (lib'.splitString "\n"
                   (builtins.readFile igloo.systemd.user.services.unsloth.serviceConfig.ExecStart));
        };
        expected = {
          podmanEnable = true;
          linger = true;
          extraGroups = [ "render" "video" "aimodels" ];
          restart = "always";
          timeoutStartSec = "infinity";
          wantedBy = [ "default.target" ];
          firewallPorts = [ ];
          hfMount = true;
        };
      }
    );

    # Batteries-included: with the store included, the HF cache mounts
    # the store's hfCache, and a custom store root propagates.
    test-model-store-wiring = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;

        expr = {
          modelsDir = igloo.deniac.ai.unsloth.modelsDir;
          storeGroupMember = builtins.elem "aimodels" igloo.users.users.unsloth.extraGroups;
        };
        expected = {
          modelsDir = "/var/lib/ai-models/.hf-cache";
          storeGroupMember = true;
        };
      }
    );

    test-model-store-wiring-follows-custom-root = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;
        den.aspects.igloo.nixos.deniac.ai.model-store.root = "/srv/models";

        expr = igloo.deniac.ai.unsloth.modelsDir;
        expected = "/srv/models/.hf-cache";
      }
    );

    # Exposing beyond loopback opens the firewall for both ports.
    test-firewall-when-exposed = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;
        den.aspects.igloo.nixos.deniac.ai.unsloth.host = "0.0.0.0";

        expr = inputs.nixpkgs.lib.sort inputs.nixpkgs.lib.lessThan
                 igloo.networking.firewall.allowedTCPPorts;
        expected = [ 8000 8888 ];
      }
    );

    # Safety net: exposed beyond loopback with NO passwordFile must
    # produce a build-time warning naming the fix (Studio ships
    # server-side tools ON — this combination is RCE otherwise).
    test-exposed-without-password-warns = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;
        den.aspects.igloo.nixos.deniac.ai.unsloth.host = "0.0.0.0";

        expr = inputs.nixpkgs.lib.any
          (w: inputs.nixpkgs.lib.hasInfix "deniac.ai.unsloth" w
               && inputs.nixpkgs.lib.hasInfix "passwordFile" w)
          igloo.warnings;
        expected = true;
      }
    );

    # The warning is specifically about the missing secret: exposing
    # WITH a passwordFile set must be silent.
    test-exposed-with-password-no-warn = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;
        den.aspects.igloo.nixos.deniac.ai.unsloth.host = "0.0.0.0";
        den.aspects.igloo.nixos.deniac.ai.unsloth.passwordFile =
          "/run/secrets/unsloth-studio.env";

        expr = inputs.nixpkgs.lib.any
          (w: inputs.nixpkgs.lib.hasInfix "deniac.ai.unsloth" w)
          igloo.warnings;
        expected = false;
      }
    );

    # Loopback (the default) never warns — nothing is reachable off-box.
    test-loopback-no-warn = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.unsloth ];
        den.aspects.igloo.nixos.deniac.ai.unsloth.enable = true;

        expr = inputs.nixpkgs.lib.any
          (w: inputs.nixpkgs.lib.hasInfix "deniac.ai.unsloth" w)
          igloo.warnings;
        expected = false;
      }
    );
  };
}
