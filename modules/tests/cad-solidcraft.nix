# Tests for `cad.solidcraft` — same fresh-eval pattern as tests/ai-comfyui.nix.
#
# What is under test is the aspect's own logic: the option surface and the
# environment it derives for the wrapper (`wrapperEnv`). The wrapper
# *build* (symlinkJoin + wrapProgram over the upstream package) is not
# exercised here — forcing it would build SolidCraft, which is a ~758k-line
# Rust app and belongs in a real build, not a unit test.

{ denTest, ... }:
{
  flake.tests.cad-solidcraft = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.cad.solidcraft.description != null;
          hasNixosModule = builtins.isFunction deniac.cad.solidcraft.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    # Not enabled: nothing installed, but the derived wrapper environment is
    # still the Nix-safe default — managed by nix, no update checks, no
    # window-system pin, control channel left on the app's own port.
    test-inert-by-default = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.cad.solidcraft ];

        expr = {
          enable = igloo.deniac.cad.solidcraft.enable;
          managedBy = igloo.deniac.cad.solidcraft.managedBy;
          checkForUpdates = igloo.deniac.cad.solidcraft.checkForUpdates;
          windowSystem = igloo.deniac.cad.solidcraft.windowSystem;
          controlPort = igloo.deniac.cad.solidcraft.controlPort;
          wrapperEnv = igloo.deniac.cad.solidcraft.wrapperEnv;
        };
        expected = {
          enable = false;
          managedBy = "nix";
          checkForUpdates = false;
          windowSystem = null;
          controlPort = null;
          wrapperEnv = {
            SOLIDCRAFT_MANAGED_BY = "nix";
            SOLIDCRAFT_UPDATE_CHECK = "0";
          };
        };
      }
    );

    # Every knob set: each one lands in the wrapper environment with the
    # value upstream expects (wayland -> "1", x11 -> "0", port -> string).
    test-wrapper-env-all-knobs = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.cad.solidcraft ];
        den.aspects.igloo.nixos.deniac.cad.solidcraft = {
          enable = true;
          managedBy = "nix-testbed";
          checkForUpdates = true;
          windowSystem = "wayland";
          controlPort = 27900;
        };

        expr = {
          enable = igloo.deniac.cad.solidcraft.enable;
          env = igloo.deniac.cad.solidcraft.wrapperEnv;
        };
        expected = {
          enable = true;
          # checkForUpdates = true means the variable is NOT set.
          env = {
            SOLIDCRAFT_MANAGED_BY = "nix-testbed";
            SOLIDCRAFT_WAYLAND = "1";
            SOLIDCRAFT_CONTROL_PORT = "27900";
          };
        };
      }
    );

    # x11 is the "0" side of the same option, and managedBy = null drops
    # the variable entirely (the app may then self-update — not what you
    # want on NixOS, but the option must be able to say it).
    test-wrapper-env-x11-and-unmanaged = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.cad.solidcraft ];
        den.aspects.igloo.nixos.deniac.cad.solidcraft = {
          enable = true;
          managedBy = null;
          windowSystem = "x11";
        };

        expr = {
          env = igloo.deniac.cad.solidcraft.wrapperEnv;
          hasManagedBy = builtins.hasAttr "SOLIDCRAFT_MANAGED_BY" igloo.deniac.cad.solidcraft.wrapperEnv;
          hasControlPort = builtins.hasAttr "SOLIDCRAFT_CONTROL_PORT" igloo.deniac.cad.solidcraft.wrapperEnv;
        };
        expected = {
          env = { SOLIDCRAFT_WAYLAND = "0"; SOLIDCRAFT_UPDATE_CHECK = "0"; };
          hasManagedBy = false;
          hasControlPort = false;
        };
      }
    );

    # The escape hatch: extra variables this aspect does not model ride
    # along via extraWrapperEnv, merged over the derived set rather than
    # replacing it.
    test-wrapper-env-extra-variable = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.cad.solidcraft ];
        den.aspects.igloo.nixos.deniac.cad.solidcraft.extraWrapperEnv = {
          SOLIDCRAFT_RENDERER = "gl";
        };

        expr = {
          renderer = igloo.deniac.cad.solidcraft.wrapperEnv.SOLIDCRAFT_RENDERER;
          stillManaged = igloo.deniac.cad.solidcraft.wrapperEnv.SOLIDCRAFT_MANAGED_BY;
          extra = igloo.deniac.cad.solidcraft.extraWrapperEnv.SOLIDCRAFT_RENDERER;
        };
        expected = {
          renderer = "gl";
          stillManaged = "nix";
          extra = "gl";
        };
      }
    );
  };
}
