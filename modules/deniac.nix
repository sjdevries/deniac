# deniac — namespace declaration.
#
# Declares the `deniac` namespace (namespace + output, so consumers get the
# `deniac` specialArg and `flake.denful.deniac`) and pulls in the den flake
# core. Every module in `modules/` (this file, `aspects/`, `tests/`) is
# loaded into one eval by import-tree, so aspects and tests live side by
# side without importing each other.
{ inputs, ... }:
{
  imports = [
    inputs.den.flakeModule
    (inputs.den.namespace "deniac" true)
    # denTest harness: exposes the `denTest` module-arg (and the
    # `igloo`/`iceberg`/... lazy host helpers) that the test modules in
    # `modules/tests/` destructure. Mirrors den's own CI template
    # (templates/ci/modules/test-support/eval-den.nix).
    inputs.den.flakeModules.denTest
    inputs.den.flakeOutputs.tests
  ];
}
