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

    # The registry: a declared model is fetched (fixed-output) and
    # symlinked into the store tree. The symlink target is a /nix/store
    # path (the fetchurl outPath). No fetch happens at eval — the
    # outPath is computed from url + sha256.
    test-model-fetch-and-link = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];
        den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;
        den.aspects.igloo.nixos.deniac.ai.model-store.models = [
          {
            name = "foo.gguf";
            subdir = "llm";
            url = "https://huggingface.co/example/repo/resolve/main/foo.gguf";
            sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          }
        ];

        expr = {
          linkRulePresent = inputs.nixpkgs.lib.any
            (r: inputs.nixpkgs.lib.hasPrefix "L+ /var/lib/ai-models/llm/foo.gguf" r)
            igloo.systemd.tmpfiles.rules;
          linkToStore = inputs.nixpkgs.lib.any
            (r: inputs.nixpkgs.lib.hasPrefix "L+ /var/lib/ai-models/llm/foo.gguf - - - /nix/store/" r)
            igloo.systemd.tmpfiles.rules;
        };
        expected = {
          linkRulePresent = true;
          linkToStore = true;
        };
      }
    );

    # Multiple models across subdirs each get their own symlink rule.
    test-models-multiple = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];
        den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;
        den.aspects.igloo.nixos.deniac.ai.model-store.models = [
          { name = "a.gguf"; subdir = "llm";
            url = "https://example.com/a.gguf";
            sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
          { name = "b.safetensors"; subdir = "loras";
            url = "https://civitai.com/api/v1/model-versions/1";
            sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
        ];

        expr = {
          llmLink = inputs.nixpkgs.lib.any
            (r: inputs.nixpkgs.lib.hasPrefix "L+ /var/lib/ai-models/llm/a.gguf - - - /nix/store/" r)
            igloo.systemd.tmpfiles.rules;
          lorasLink = inputs.nixpkgs.lib.any
            (r: inputs.nixpkgs.lib.hasPrefix "L+ /var/lib/ai-models/loras/b.safetensors - - - /nix/store/" r)
            igloo.systemd.tmpfiles.rules;
          linkCount = builtins.length
            (builtins.filter (r: inputs.nixpkgs.lib.hasPrefix "L+ /var/lib/ai-models/" r)
              igloo.systemd.tmpfiles.rules);
        };
        expected = {
          llmLink = true;
          lorasLink = true;
          linkCount = 2;
        };
      }
    );

    # Models declared but the store disabled: no symlink rules — the
    # registry only materialises when the store is enabled.
    test-models-inert-when-store-disabled = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };
        den.aspects.igloo.includes = [ deniac.ai.model-store ];
        den.aspects.igloo.nixos.deniac.ai.model-store.models = [
          { name = "foo.gguf"; subdir = "llm";
            url = "https://example.com/foo.gguf";
            sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
        ];

        expr = {
          anyStoreLink = inputs.nixpkgs.lib.any
            (r: inputs.nixpkgs.lib.hasPrefix "L+ /var/lib/ai-models/" r)
            igloo.systemd.tmpfiles.rules;
        };
        expected = { anyStoreLink = false; };
      }
    );

    # The homeManager class: the read-only path surface evaluates
    # STANDALONE (plain evalModules — no NixOS, no home-manager), so
    # per-user consumers in a homeManager eval can read hfCache/paths
    # and follow a custom root. Options-only: no provisioning here.
    test-homemanager-class = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr =
          let
            lib' = inputs.nixpkgs.lib;
            ev = lib'.evalModules {
              modules = [
                deniac.ai.model-store.homeManager
                { deniac.ai.model-store.root = "/srv/models"; }
              ];
            };
          in
          {
            hasHfCacheOption = ev.options.deniac.ai.model-store.hfCache ? _type;
            hfFollowsRoot = ev.config.deniac.ai.model-store.hfCache;
            llmPath = ev.config.deniac.ai.model-store.paths.llm;
            # The hm class declares no `enable`/`models` — those are
            # nixos-side provisioning concerns.
            noEnableOption = !(ev.options.deniac.ai.model-store ? enable);
          };
        expected = {
          hasHfCacheOption = true;
          hfFollowsRoot = "/srv/models/.hf-cache";
          llmPath = "/srv/models/llm";
          noEnableOption = true;
        };
      }
    );
  };
}
