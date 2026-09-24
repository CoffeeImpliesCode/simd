const lib = @import("src/root.zig");

test "source-local library tests" {
    _ = lib;
    _ = @import("test/yaml_extended_test.zig");
}
