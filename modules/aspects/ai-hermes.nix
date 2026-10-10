# deniac.ai.hermes — Hermes Agent (Nous Research) in role-compartment jails.
#
# This aspect implements the security model documented in the fleet's
# research/hermes-profile-security-model.md: the agent is split into
# least-privilege role compartments (researcher / coder / reviewer /
# creator), each a Hermes *profile* (NousResearch/hermes-agent's native
# `~/.hermes/profiles/<name>/` isolation — per-profile config.yaml, .env,
# SOUL.md, memories, sessions, skills). Prompt injection is a
# confused-deputy attack: you can't detect it, but you can remove or bound
# the capability, so a compartment can't be tricked into touching what it
# was never given.
#
# TWO ENFORCEMENT TIERS (match the tier to the threat — they compose):
#
#   tier = "bwrap"  — a bubblewrap mount-namespace jail. Default-DENY:
#       the real home is NOT bound; the agent's HOME is its own profile
#       `home/` dir, so it literally cannot read ~/.ssh, ~/.aws, browser
#       profiles, or sibling profiles. Protects the system AND bounds the
#       blast radius. Sufficient for the confused-deputy threat.
#
#   tier = "munix"  — a KVM microVM (munix / libkrun). Separate guest
#       kernel → jail-escape resistance against a compromised tool/MCP
#       server, plus per-VM network: `network = "none"` maps to munix
#       `--no-network` (the reviewer's clean no-net boundary). The guest
#       closure is a declared input (built by the host / a separate
#       aspect); this aspect provides the launcher.
#
# Why bubblewrap, not the upstream podman container: the upstream NixOS
# module's container mode runs as root ("Podman's rootful containers
# require sudo"); rootless contradicts it and failed on this fleet. bwrap
# delivers the jail with no daemon, no root, no sudo.
#
# Reproducibility: everything the stack IS lives in Nix (hash-pinned); the
# only mutable part is what the agent LEARNED (~/.hermes: sessions, skills,
# memories) — backed up like precious-bulk weights, never rebuilt.
#
# The pure jail/config logic lives in ../../lib/hermes-jail.nix (outside
# modules/ so import-tree won't load it as an aspect) and is unit-tested
# there. This file is the option surface + wiring.
#
# Usage (per-user, Home Manager class):
#
#   den.aspects.tux.includes = [ deniac.ai.hermes ];
#   den.aspects.tux.homeManager.deniac.ai.hermes = {
#     enable = true;
#     profiles = {
#       researcher = {
#         bindReadwrite = [ "/home/tux/research-out" ];   # its only write target
#         mcpServers.donsetch.command = "donsetch";
#         soul = "You are a research assistant. No secrets, no push.";
#       };
#       coder = {
#         bindReadwrite = [ "/home/tux/work/myrepo" ];
#         env.GIT_SSH_COMMAND = "ssh -i /home/tux/.ssh/deploy_key";
#       };
#       reviewer = {
#         tier = "munix";
#         network = "none";                              # munix --no-network
#         bindReadonly = [ "/home/tux/work/myrepo" ];
#         munixPackage = inputs.munix.packages.x86_64-linux.munix;
#         munixClosure = "/nix/store/...-reviewer-toplevel";
#       };
#     };
#   };
#
#   # then: hermes-jailed-researcher … / hermes-munix-reviewer …

{ inputs, lib, ... }:
{
  deniac.ai.hermes = {
    description = ''
      Hermes Agent (Nous Research, MIT) in role-compartment jails —
      per-profile least-privilege isolation (researcher / coder / reviewer
      / creator) enforced by bubblewrap (default-deny bind) or munix KVM
      microVMs (jail-escape resistance + per-VM network). The daemonless,
      rootless alternative to the upstream rootful podman container.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      hj = import ../../lib/hermes-jail.nix { inherit lib; };
      cfg = config.deniac.ai.hermes;

      # ── profile submodule ──────────────────────────────────────────
      profileOpts = { name, ... }: {
        options = {
          tier = lib.mkOption {
            type = lib.types.enum [ "bwrap" "munix" ];
            default = "munix";
            description = ''
              Enforcement tier. The TARGET is a munix KVM microVM per
              compartment (Nix³OS Tier 1): a separate guest kernel for
              jail-escape containment plus a per-VM routable network.
              "bwrap" is the FALLBACK — a default-deny bubblewrap jail
              for hosts without KVM / nested virt, or a deliberately
              lighter compartment. munix needs `munixPackage` +
              `munixClosure`.
            '';
          };

          bindReadonly = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/home/tux/work/myrepo" ];
            description = "Host directories bound READ-ONLY into this compartment.";
          };

          bindReadwrite = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/home/tux/research-out" ];
            description = ''
              Host directories bound READ-WRITE into this compartment.
              The real home is NEVER bound (default-deny) — every path the
              agent may touch is declared here.
            '';
          };

          mcpServers = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
              options = {
                command = lib.mkOption { type = lib.types.str; };
                args = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
                env = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
              };
            }));
            default = { };
            example = lib.literalExpression ''{ donsetch.command = "donsetch"; }'';
            description = ''
              This compartment's MCP servers (its TOOLS), rendered into
              the profile's config.yaml as `mcp_servers`. Different
              profiles get different tools.
            '';
          };

          settings = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            example = { model.default = "anthropic/claude-sonnet-4"; };
            description = ''
              Additional behavioral settings merged into the profile's
              config.yaml (declared keys win over the agent's learned keys).
            '';
          };

          soul = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "The compartment's persona, rendered to SOUL.md (null = leave the agent's own).";
          };

          network = lib.mkOption {
            type = lib.types.enum [ "full" "none" ];
            default = "full";
            description = ''
              Coarse egress posture (munix tier). "none" → munix
              `--no-network`: a TOTAL boundary — the guest has no outbound
              at all, including no model. Use it only when the model is
              bundled in-VM. "full" → the guest has network; the
              FINE-GRAINED boundary (model-host yes / internet no /
              git-remote only) is enforced by the host-level tap firewall
              over the per-VM virtio-net, not by this flag. A reviewer
              that reaches a VPN model host uses "full" + a tap rule that
              allows the model host and drops the internet.
            '';
          };

          gpu = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "munix tier: pass GPU through (omit `--no-gpu`). Off by default.";
          };

          munixPackage = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            example = lib.literalExpression "inputs.munix.packages.\${system}.munix";
            description = ''
              munix tier: the munix runner package. Provided by the
              consumer's flake (deniac deliberately does not pin
              libkrun/KVM for an optional tier). Required when
              tier = "munix".
            '';
          };

          munixClosure = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/nix/store/abcd-reviewer-toplevel";
            description = ''
              munix tier: the NixOS toplevel closure the microVM boots
              (built by the host / a separate aspect; munix's input is
              `system.build.toplevel`). Required when tier = "munix".
            '';
          };

          storeSlice = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                image = lib.mkOption {
                  type = lib.types.str;
                  example = "/nix/store/abcd-researcher-store-erofs";
                  description = "Path to the prebuilt erofs store image (--store-dev argument).";
                };
                sandboxPaths = lib.mkOption {
                  type = lib.types.str;
                  example = "/nix/store/efgh-closure-info/store-paths";
                  description = "Path to the closureInfo store-paths file (--sandbox-store argument).";
                };
              };
            });
            default = null;
            example = lib.literalExpression ''
              {
                image = toString guest.packages.\${system}.researcher-store-erofs;
                sandboxPaths = toString guest.packages.\${system}.researcher-store-paths;
              }
            '';
            description = ''
              munix tier: closure-only /nix/store (opt-in). When set, the
              launcher passes `--store-dev <image>` — the guest's
              /nix/store comes from this erofs block-device image,
              mounted by micro-activate before any closure path is read —
              plus `--sandbox-store <sandboxPaths>`, the host paths muvm
              must read pre-activation. `null` keeps the whole-host store
              bind (the default). Requires a munix that has `--store-dev`
              (our fork branch `feat/closure-only-store`; upstream
              clan/munix PR #38). Build the pair with `pkgs.closureInfo`
              + `mkfs.erofs` — see the hermes-munix-guest template's
              `researcher-store-erofs` / `researcher-store-paths`
              outputs.
            '';
          };

          extraPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Extra packages on this compartment's PATH.";
          };

          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Extra environment variables set inside this compartment.";
          };
        };
      };

      jailFor = name: prof:
        if prof.tier == "munix" then
          hj.mkMunixLauncher pkgs prof.munixPackage name prof
        else
          hj.mkBwrapJail pkgs cfg.package name prof;

      profilePackages = lib.mapAttrsToList jailFor cfg.profiles;
    in
    {
      options.deniac.ai.hermes = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install the compartmentalized Hermes jails.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.hermes-agent;
          defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.hermes-agent";
          description = "The hermes-agent package (from the existing llm-agents pin).";
        };

        profiles = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule profileOpts);
          default = { };
          description = ''
            The role compartments. Each generates a launcher
            (`hermes-jailed-<name>` for bwrap, `hermes-munix-<name>` for
            munix) and renders its declared config.yaml + SOUL.md into
            `~/.hermes/profiles/<name>/` with a preserve-learned-keys
            merge.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = profilePackages;

        # Render each profile's declared config + SOUL into its HERMES_HOME,
        # merging over any learned config (declared wins).
        home.activation.hermes-render-profiles = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: prof: ''
            PH="$HOME/.hermes/profiles/${name}"
            mkdir -p "$PH"
            ${hj.mergeScript pkgs} ${hj.renderProfileConfig pkgs name prof} "$PH/config.yaml"
            ${if prof.soul != null then "cp -f ${hj.renderProfileSoul pkgs name prof} \"$PH/SOUL.md\"" else ""}
          '') cfg.profiles)}
        '';
      };
    };
  };
}
