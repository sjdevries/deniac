# Tests for `ai.ace-step` — same fresh-eval pattern as tests/ai-comfyui.nix.
# The aspect wires the official ACE-Step node into services.comfyui.customNodes
# and warns when the ComfyUI service is off. Flat leaf selections (nix-unit
# 2.x deep-forces `expr`).

{ denTest, ... }:
{
  flake.tests.ai-ace-step = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.ace-step.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.ace-step.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    # Nothing set: no custom nodes installed, aspect inert.
    test-inert-by-default = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.ace-step ];

        expr = {
          enable = igloo.deniac.ai.ace-step.enable;
          hasNode = igloo.services.comfyui.customNodes ? "ACE-Step-ComfyUI";
        };
        expected = {
          enable = false;
          hasNode = false;
        };
      }
    );

    # enable: the official node lands in services.comfyui.customNodes
    # under the expected directory name, as a store path.
    test-node-wiring = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.ace-step ];
        den.aspects.igloo.nixos.deniac.ai.ace-step.enable = true;

        expr = {
          hasNode = igloo.services.comfyui.customNodes ? "ACE-Step-ComfyUI";
          nodeIsPath = builtins.isPath igloo.services.comfyui.customNodes."ACE-Step-ComfyUI";
        };
        expected = {
          hasNode = true;
          nodeIsPath = true;
        };
      }
    );

    # Nodes installed but ComfyUI service off → a warning fires (the
    # nodes have nothing to attach to).
    test-warning-without-comfyui-service = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.ace-step ];
        den.aspects.igloo.nixos.deniac.ai.ace-step.enable = true;

        expr = {
          hasWarning = builtins.any (w: builtins.isInfix "ComfyUI service is not" w) igloo.warnings;
        };
        expected = {
          hasWarning = true;
        };
      }
    );

    # With the ComfyUI service enabled too (the normal pairing), silent.
    test-no-warning-with-comfyui-service = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.comfyui deniac.ai.ace-step ];
        den.aspects.igloo.nixos.deniac.ai.comfyui.enable = true;
        den.aspects.igloo.nixos.deniac.ai.ace-step.enable = true;

        expr = {
          comfyuiEnable = igloo.services.comfyui.enable;
          hasWarning = builtins.any (w: builtins.isInfix "ComfyUI service is not" w) igloo.warnings;
        };
        expected = {
          comfyuiEnable = true;
          hasWarning = false;
        };
      }
    );
  };
}
