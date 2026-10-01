{ pkgs, ... }:

let
  zig = pkgs.zig_0_16;
in
rec {
  # The library has no package dependencies. Pin its compiler here; the
  # external gate tools (zig-gate, zbc, zwanzig, cross-test) come from PATH.
  # Keep the compiler aligned with build.zig.zon's minimum_zig_version.
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