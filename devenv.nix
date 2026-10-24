{ ... }:
{
  # Use the compiler on PATH. anyzig selects the version from build.zig.zon.
  enterShell = ''
    if [ "$(zig version)" != "0.17.0" ]; then
      echo "simd requires Zig 0.17.0 on PATH" >&2
      return 1
    fi
    export PATH="zig-out/bin:$PATH"
  '';
}
