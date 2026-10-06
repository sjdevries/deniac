# Tests for `ai.hermes` — shape tests only, matching the other Home Manager
# aspects (ai.dsh, ai.unsloth-desktop): deniac has no home-manager flake
# input, so the jail derivation is verified by building it in a real Home
# Manager eval downstream, not here. What we CAN assert: the aspect exports
# with a homeManager class and no nixos class (the jail is per-user state).

{ denTest, ... }:
{
  flake.tests.ai-hermes = {

    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.hermes.description != null;
          hasHomeManagerClass = builtins.isFunction deniac.ai.hermes.homeManager;
          hasNixosClass = deniac.ai.hermes ? nixos;
        };
        expected = {
          hasDescription = true;
          hasHomeManagerClass = true;
          hasNixosClass = false;
        };
      }
    );
  };
}
