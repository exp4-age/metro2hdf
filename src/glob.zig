const std = @import("std");

pub fn globMatch(pat: []const u8, str: []const u8) bool {
    var back_pat: ?[*]const u8 = null;
    var back_str: ?[*]const u8 = null;

    var p: [*]const u8 = pat.ptr;
    var s: [*]const u8 = str.ptr;

    outer: while (true) {
        const c: u8 = s[0]; s += 1;
        var d: u8 = p[0]; p += 1;

        switch (d) {
            '?' => { // Wildcard: anything but nul
                if (c == 0) return false;
            },
            '*' => { // Any-length wildcard
                if (p[0] == 0) return true; // Optimize trailing * case
                back_pat = p;
                s -= 1;
                back_str = s; // Allow zero-length match
            },
            '[' => { // Character class
                if (c == 0) return false; // No possible match

                var match = false;
                const inverted = p[0] == '!';
                var class = if (inverted) p + 1 else p;

                var a: u8 = class[0]; class += 1;

                while (true) {
                    var b: u8 = a;

                    if (a == 0) {
                        // goto literal
                        if (c == d) {
                            if (d == 0) return true;
                            continue :outer;
                        }
                        if (c == 0 or back_pat == null) return false;
                        p = back_pat.?;
                        back_str = back_str.? + 1;
                        s = back_str.?;
                        continue :outer;
                    }

                    if (class[0] == '-' and class[1] != ']') {
                        b = class[1];

                        if (b == 0) {
                            // goto literal
                            if (c == d) {
                                if (d == 0) return true;
                                continue :outer;
                            }
                            if (c == 0 or back_pat == null) return false;
                            p = back_pat.?;
                            back_str = back_str.? + 1;
                            s = back_str.?;
                            continue :outer;
                        }

                        class += 2;
                        // Any special action if a > b?
                    }

                    if (a <= c and c <= b) match = true;

                    a = class[0]; class += 1;
                    if (a == ']') break;
                }

                if (match == inverted) {
                    // goto backtrack
                    if (c == 0 or back_pat == null) return false;
                    p = back_pat.?;
                    back_str = back_str.? + 1;
                    s = back_str.?;
                    continue;
                }

                p = class;
            },
            '\\' => {
                d = p[0]; p += 1;
                // fallthrough
                if (c == d) {
                    if (d == 0) return true;
                    continue;
                }
                if (c == 0 or back_pat == null) return false;
                p = back_pat.?;
                back_str = back_str.? + 1;
                s = back_str.?;
            },
            else => { // Literal character
                if (c == d) {
                    if (d == 0) return true;
                    continue;
                }
                if (c == 0 or back_pat == null) return false; // No point continuing
                // Try again from last *, one character later in str.
                p = back_pat.?;
                back_str = back_str.? + 1;
                s = back_str.?;
            },
        }
    }
}

test "literal match" {
    try std.testing.expect(globMatch("hello", "hello"));
    try std.testing.expect(!globMatch("hello", "world"));
}

test "? wildcard" {
    try std.testing.expect(globMatch("h?llo", "hello"));
    try std.testing.expect(!globMatch("h?llo", "hllo"));
    try std.testing.expect(!globMatch("h?llo", "heello"));
    try std.testing.expect(!globMatch("hello?", "hello"));
}

test "* wildcard" {
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(globMatch("*.c", "foo.c"));
    try std.testing.expect(!globMatch("*.c", "foo.h"));
    try std.testing.expect(globMatch("foo*", "foobar"));
    try std.testing.expect(globMatch("*bar", "foobar"));
    try std.testing.expect(globMatch("*oba*", "foobar"));
}

test "character classes" {
    try std.testing.expect(globMatch("*.[ch]", "foo.c"));
    try std.testing.expect(globMatch("*.[ch]", "foo.h"));
    try std.testing.expect(!globMatch("*.[ch]", "foo.o"));
}

test "negated character class" {
    try std.testing.expect(globMatch("[!abc]", "d"));
    try std.testing.expect(!globMatch("[!abc]", "a"));
}

test "character class range" {
    try std.testing.expect(globMatch("[a-z]", "m"));
    try std.testing.expect(!globMatch("[a-z]", "M"));
}

test "escape sequences" {
    try std.testing.expect(globMatch("foo\\*", "foo*"));
    try std.testing.expect(!globMatch("foo\\*", "foobar"));
}
