# deniac.ai.dsh tests — runs against the pinned den + llm-agents inputs.
#
# Same denTest shape as the other deniac tests: each case is a fresh den eval
# that re-registers the `deniac` namespace from `inputs.self`, so `deniac.*`
# resolves. nix-unit deep-forces `expr` and deep-compares with `expected`, so
# `expr` must be a flat leaf projection.
#
# Scope note: dsh is a `homeManager`-class aspect. A full homeManager eval
# (a user with a homeManager class, projecting the rendered settings.yaml)
# needs the home-manager input + the hm-host entity wired into the test tree;
# that lands with the Phase-2 profile work. For now the namespace/shape
# guarantee is asserted directly.

{ denTest, ... }:
{
  flake.tests.ai-dsh = {

    # Consumer-facing guarantee: with the `deniac` namespace imported from
    # `inputs.self`, `deniac.ai.dsh` resolves to a den aspect that exposes a
    # `homeManager` class module (the per-user install surface). This checks
    # the attr shape without calling the class function.
    test-namespace-export = denTest (
      { inputs, den, deniac, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        expr = deniac.ai.dsh ? homeManager;
        expected = true;
      }
    );
  };
}
