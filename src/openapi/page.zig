// Adapted from vkiryakov/zefir src/openapi/Docs.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.

//! The page that shows the document: Scalar's API reference, loaded by the
//! browser from jsDelivr (a release pinned here and checked by its hash, with
//! Subresource Integrity), never bundled or distributed. A
//! `Content-Security-Policy` of the application must allow scripts of
//! https://cdn.jsdelivr.net, the `<style>` elements Scalar adds
//! (`style-src 'unsafe-inline'`) and its fonts (`font-src
//! https://fonts.scalar.com`). The requests of "Try it" go from the browser
//! straight to the API, never through a proxy, so the `connect-src` of a
//! strict policy must allow the API's origin. The page has no AI panel, which
//! would send the document and a developer's questions to Scalar's servers.
const std = @import("std");

/// Scalar, the reference of the page: a file of a release of its npm package
/// on jsDelivr, which never changes, and the hash the browser checks it by.
/// MAINTAINING.md: bump the version together with its SRI hash.
pub const scalar = struct {
    pub const version = "1.75.1";
    pub const url = "https://cdn.jsdelivr.net/npm/@scalar/api-reference@" ++ version ++ "/dist/browser/standalone.js";
    pub const integrity = "sha384-G+2Q2i9l3PPfmYkk0b4BAIUrs7xb/DNaTL1wCYYab4c9dIKlCyiqzC0Qx3eq9Wf6";
    /// The configuration of the reference, as JSON, which it reads from the
    /// attribute `data-configuration`: an empty `proxyUrl` sends each request
    /// of "Try it" from the browser straight to the API (without it, a default
    /// of Scalar's may send it through https://proxy.scalar.com), and a
    /// disabled `agent` leaves out the AI panel.
    pub const configuration = "{\"proxyUrl\":\"\",\"agent\":{\"disabled\":true}}";
};

/// The page for the document titled `title`, which it loads from `data_url`
/// (a path from the server's root). The caller frees the result.
pub fn render(gpa: std.mem.Allocator, title: []const u8, data_url: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>{f}</title>
        \\  </head>
        \\  <body>
        \\    <script id="api-reference" data-configuration="{f}" data-url="{f}"></script>
        \\    <script src="{s}" integrity="{s}" crossorigin="anonymous"></script>
        \\  </body>
        \\</html>
        \\
    , .{ Html{ .text = title }, Html{ .text = scalar.configuration }, Html{ .text = data_url }, scalar.url, scalar.integrity });
}

/// Text in HTML, as an element's content or an attribute's value.
const Html = struct {
    text: []const u8,

    pub fn format(h: Html, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (h.text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        };
    }
};

test "render: the title and the data url are escaped; the script is pinned by its hash" {
    const page = try render(std.testing.allocator, "A <b> & \"c\"", "/api/openapi.json");
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<title>A &lt;b&gt; &amp; &quot;c&quot;</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "data-url=\"/api/openapi.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, scalar.integrity) != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "&quot;proxyUrl&quot;:&quot;&quot;") != null);
}
