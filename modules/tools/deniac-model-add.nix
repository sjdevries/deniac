# deniac-model-add — CLI helper exposed as a flake package.
#
# Resolves a CivitAI / HuggingFace / generic model URL into a
# `deniac.ai.model-store.models` config entry (download URL + SHA256,
# no full-file download for CivitAI/HF). The logic lives in the sibling
# `deniac-model-add.pl`; this wraps it so it runs with perl + curl + nix
# on PATH regardless of the host.
#
#   nix run .#deniac-model-add -- <url> [--subdir S] [--name N] ...
#
# Gated models: export CIVITAI_API_KEY / HF_TOKEN; they are sent as
# Bearer headers but never written into the emitted entry.
{ inputs, ... }:
let
  pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
in
{
  imports = [ inputs.den.flakeOutputs.packages ];

  flake.packages.x86_64-linux.deniac-model-add =
    pkgs.writeShellApplication {
      name = "deniac-model-add";
      runtimeInputs = [ pkgs.perl pkgs.curl pkgs.nix ];
      text = ''exec perl ${./deniac-model-add.pl} "$@"'';
    };
}
