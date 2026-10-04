# Tests for `ai.model-store` — same fresh-eval pattern as
# tests/ai-gufo.nix: each denTest re-registers the `deniac` namespace
# from `inputs.self` so `deniac.ai.model-store` resolves. Projections are
# flat leaf selections (nix-unit 2.x deep-forces `expr` and deep-compares).

{ denTest, ... }:
{
  flake.tests.ai-model-store = {

    # Consumer-facing guarantee: `deniac.ai.model-store` resolves to a
    # usable den aspect (description + a NixOS module under `nixos`).
    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.model-store.description != null;
          hasNixosModule = builtins.isFunction deniac.ai.model-store.nixos;
        };
        expected = {
          hasDescription = true;
          hasNixosModule = true;
        };
      }
    );

    # Nothing set: entirely inert — no shared group, no tmpfiles rules
    # touching the store root — and the option defaults hold.
    test-inert-by-default = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];

        expr = {
          groupDefined = builtins.hasAttr "aimodels" igloo.users.groups;
          anyStoreRule = inputs.nixpkgs.lib.any
            (r: builtins.match ".*ai-models.*" r != null)
            igloo.systemd.tmpfiles.rules;
          enable = igloo.deniac.ai.model-store.enable;
          root = igloo.deniac.ai.model-store.root;
          hfCache = igloo.deniac.ai.model-store.hfCache;
        };
        expected = {
          groupDefined = false;
          anyStoreRule = false;
          enable = false;
          root = "/var/lib/ai-models";
          hfCache = "/var/lib/ai-models/.hf-cache";
        };
      }
    );

    # enable = true: the shared group is created and the tmpfiles rules
    # provision the root, every subdir, and the HF cache dir.
    test-enabled = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];
        den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;

        expr = {
          groupDefined = builtins.hasAttr "aimodels" igloo.users.groups;
          rootRule = builtins.elem
            "d /var/lib/ai-models 0775 root aimodels - -"
            igloo.systemd.tmpfiles.rules;
          llmRule = builtins.elem
            "d /var/lib/ai-models/llm 0775 root aimodels - -"
            igloo.systemd.tmpfiles.rules;
          ggufRule = builtins.elem
            "d /var/lib/ai-models/gguf 0775 root aimodels - -"
            igloo.systemd.tmpfiles.rules;
          hfRule = builtins.elem
            "d /var/lib/ai-models/.hf-cache 0775 root aimodels - -"
            igloo.systemd.tmpfiles.rules;
        };
        expected = {
          groupDefined = true;
          rootRule = true;
          llmRule = true;
          ggufRule = true;
          hfRule = true;
        };
      }
    );

    # A custom `root` is respected in the tmpfiles rules, and the
    # `hfCache` default follows the overridden root.
    test-custom-root = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];
        den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;
        den.aspects.igloo.nixos.deniac.ai.model-store.root = "/srv/models";

        expr = {
          rootRule = builtins.elem
            "d /srv/models 0775 root aimodels - -"
            igloo.systemd.tmpfiles.rules;
          hfFollowsRoot = builtins.elem
            "d /srv/models/.hf-cache 0775 root aimodels - -"
            igloo.systemd.tmpfiles.rules;
          llmPath = igloo.deniac.ai.model-store.paths.llm;
        };
        expected = {
          rootRule = true;
          hfFollowsRoot = true;
          llmPath = "/srv/models/llm";
        };
      }
    );

    # The derived `paths` attrset maps each subdir name to its absolute
    # path under the root (the consumer-facing contract).
    test-paths-derived = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];

        expr = {
          llm = igloo.deniac.ai.model-store.paths.llm;
          image = igloo.deniac.ai.model-store.paths.image;
          loras = igloo.deniac.ai.model-store.paths.loras;
          keys = builtins.sort builtins.lessThan
            (builtins.attrNames igloo.deniac.ai.model-store.paths);
        };
        expected = {
          llm = "/var/lib/ai-models/llm";
          image = "/var/lib/ai-models/image";
          loras = "/var/lib/ai-models/loras";
          keys = [ "audio" "gguf" "image" "llm" "loras" "text_encoders" "vae" "video" ];
        };
      }
    );
  };
}
