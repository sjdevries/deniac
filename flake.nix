{
  description = "deniac — den aspect library";

  inputs = {
    den.url = "github:denful/den";
    import-tree.url = "github:vic/import-tree";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    nix-amd-ai.url = "github:noamsto/nix-amd-ai";
    # dsh (DeepSeek Harness) + hermes-agent package source. Pinned to
    # 0784674 (llm-agents main, 2026-10-26) — dsh 0.2.1-rc.3 + hermes-agent
    # 0.22.5. This bump unblocks the dsh upgrade: 0.1.6+ used to crash at boot
    # with `node-addon-require-builtin unsupported` (llm-agents#9994), fixed
    # upstream by e442eb67 ("dsh: avoid node-addon-require-builtin"). Both
    # packages verified building AND starting on this box at this pin.
    # NOTE: this input is SHARED between dsh and hermes-agent — bumping it moves
    # both. hermes went 0.8.4 -> 0.22.5 here (deliberate, user-approved).
    llm-agents.url = "github:numtide/llm-agents.nix/0784674971b3ee4681aea5b5e9641c75faf7e846";
    # ComfyUI (node-graph image/video gen UI) — TEMPORARILY pinned to the
    # sjdevries fork's `feat/rocm-nightly-channel` branch to test the
    # rocmNightly wheel-channel change on real gfx1151 hardware before the
    # upstream PR merges. Re-point to github:utensils/comfyui-nix once merged.
    comfyui-nix.url = "github:sjdevries/comfyui-nix/feat/rocm-nightly-channel";
    # Official ACE-Step ComfyUI nodes — a thin API client (torch/numpy/
    # requests only) for the ACE-Step 1.5 music-gen server: text2music,
    # cover/remix, repaint. Plain node repo (no flake.nix), so it is
    # locked with flake = false and consumed as a source-tree path for
    # services.comfyui.customNodes.
    ace-step-comfyui = {
      url = "github:ace-step/ACE-Step-ComfyUI";
      flake = false;
    };
  };

  outputs = inputs: (
    inputs.nixpkgs.lib.evalModules {
      specialArgs = { inherit inputs; };
      modules = [ (inputs.import-tree ./modules) ];
    }
  ).config.flake;
}
