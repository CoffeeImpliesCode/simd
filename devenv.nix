{ pkgs, ... }:

let
  zig = pkgs.zig_0_16;
in
rec {
  # build.zig.zon has no external dependencies, so the environment needs
  # nothing beyond the toolchain. Assert the version so the environment can
  # never drift away from .minimum_zig_version in build.zig.zon.
  packages = [
    (assert zig.version == "0.16.0"; zig)
  ];

  env = {
    PATH = "${zig}/bin:zig-out/bin:$PATH";
  };

  # https://devenv.sh/basics/
  enterShell = ''
    export PATH="${zig}/bin:zig-out/bin:$PATH"
  '';
}