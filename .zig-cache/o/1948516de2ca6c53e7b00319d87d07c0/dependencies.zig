pub const packages = struct {
    pub const @"1220232ab38d0c2cfb10680115c17ad2fa1a8531dbaf8bbfb359ec67e80c7d5f5758" = struct {
        pub const build_root = "/home/upper/.cache/zig/p/1220232ab38d0c2cfb10680115c17ad2fa1a8531dbaf8bbfb359ec67e80c7d5f5758";
        pub const build_zig = @import("1220232ab38d0c2cfb10680115c17ad2fa1a8531dbaf8bbfb359ec67e80c7d5f5758");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"122074c1b99544936671837d0a8143c148735e7f3e164e676be98085a2f7a466d90b" = struct {
        pub const build_root = "/home/upper/.cache/zig/p/122074c1b99544936671837d0a8143c148735e7f3e164e676be98085a2f7a466d90b";
        pub const build_zig = @import("122074c1b99544936671837d0a8143c148735e7f3e164e676be98085a2f7a466d90b");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"1220795dd7be5bb28a29b7cf1a46233b0c370c158d7f4183c35db27f2b7db9564358" = struct {
        pub const build_root = "/home/upper/.cache/zig/p/1220795dd7be5bb28a29b7cf1a46233b0c370c158d7f4183c35db27f2b7db9564358";
        pub const build_zig = @import("1220795dd7be5bb28a29b7cf1a46233b0c370c158d7f4183c35db27f2b7db9564358");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "buffer", "122074c1b99544936671837d0a8143c148735e7f3e164e676be98085a2f7a466d90b" },
            .{ "metrics", "1220232ab38d0c2cfb10680115c17ad2fa1a8531dbaf8bbfb359ec67e80c7d5f5758" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "pg", "1220795dd7be5bb28a29b7cf1a46233b0c370c158d7f4183c35db27f2b7db9564358" },
};
