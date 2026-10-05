# Tests for `ai.unsloth-desktop` — same fresh-eval pattern as the other
# deniac tests. The aspect is a homeManager-class module; a full
# homeManager eval (rendered session vars through a real user + home)
# needs the home-manager input, which this flake does not carry (same
# situation as ai.dsh). So the guarantee asserted here is the
# consumer-facing shape: the aspect resolves and exposes its
# homeManager class.

{ denTest, ... }:
{
  flake.tests.ai-unsloth-desktop = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.unsloth-desktop.description != null;
          hasHomeManagerClass = builtins.isFunction deniac.ai.unsloth-desktop.homeManager;
          hasNixosClass = deniac.ai.unsloth-desktop ? nixos;
        };
        expected = {
          hasDescription = true;
          hasHomeManagerClass = true;
          # Desktop is per-user: homeManager class ONLY, no nixos class.
          hasNixosClass = false;
        };
      }
    );
  };
}
