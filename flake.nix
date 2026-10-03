{
  description = "deniac — den aspect library";

  inputs = {
    den.url = "github:denful/den";
    import-tree.url = "github:vic/import-tree";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    nix-amd-ai.url = "github:noamsto/nix-amd-ai";
    # dsh (DeepSeek Harness) package source. Pinned to the commit that set
    # dsh 0.1.5-rc.2 ("dsh: 0.1.5-rc.1 -> 0.1.5-rc.2") — a known-good
    # version for this fleet. `main` has since moved to 0.2.0-rc.2, which is
    # unverified here; bump deliberately (AGENTS.md §3) after testing.
    llm-agents.url = "github:numtide/llm-agents.nix/32f95b57bd11604871fb663c6724da15112860ee";
    # ComfyUI (node-graph image/video gen UI) — TEMPORARILY pinned to the
    # sjdevries fork's `feat/rocm-nightly-channel` branch to test the
    # rocmNightly wheel-channel change on real gfx1151 hardware before the
    # upstream PR merges. Re-point to github:utensils/comfyui-nix once merged.
    comfyui-nix.url = "github:sjdevries/comfyui-nix/feat/rocm-nightly-channel";
  };

  outputs = inputs: (
    inputs.nixpkgs.lib.evalModules {
      specialArgs = { inherit inputs; };
      modules = [ (inputs.import-tree ./modules) ];
    }
  ).config.flake;
}
