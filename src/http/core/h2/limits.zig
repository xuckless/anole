// TokenBucket translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015,
// 2016 Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// lib/nghttp2_ratelim.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES. The
// limit set (`Limits`) is Anole's own.

//! The HTTP/2 engine's flood limits (research/h2h3-takeover/PLAN.md §5.4):
//! a token bucket and the default limit set, as data. The engine charges
//! the buckets and picks the answers; nothing here reads a clock.

const std = @import("std");

/// nghttp2_ratelim: `burst` tokens, refilled at `rate` per second. The
/// caller passes the time in whole seconds.
pub const TokenBucket = struct {
    burst: u64,
    rate: u64,
    val: u64,
    tstamp: u64 = 0,

    /// Full.
    pub fn init(burst: u64, rate: u64) TokenBucket {
        return .{ .burst = burst, .rate = rate, .val = burst };
    }

    /// Refills for the time since the last update. Time going backwards
    /// counts as one second (nghttp2's "timer skew"); an overflow fills
    /// the bucket.
    pub fn update(b: *TokenBucket, now_s: u64) void {
        if (now_s == b.tstamp) return;
        const d: u64 = if (now_s > b.tstamp) now_s - b.tstamp else 1;
        b.tstamp = now_s;
        const gain = std.math.mul(u64, b.rate, d) catch {
            b.val = b.burst;
            return;
        };
        const val = std.math.add(u64, b.val, gain) catch {
            b.val = b.burst;
            return;
        };
        b.val = @min(val, b.burst);
    }

    /// Takes `n` tokens; false (and nothing taken) if there are fewer.
    pub fn drain(b: *TokenBucket, n: u64) bool {
        if (b.val < n) return false;
        b.val -= n;
        return true;
    }
};

/// PLAN §5.4's defaults that have no config key yet, plus nghttp2 1.70's
/// own where it has one. The limits that already have one live only there
/// (config.ServerConfig.Http2: stream_reset_burst/rate, charged per D15
/// point 1 only for streams not yet answered, provoked resets included;
/// refused_stream_burst/rate; max_continuations; conn.Options defaults to
/// them). conn.zig charges these; their config keys come with M3. Every
/// default is here or in config.zig, nowhere else.
pub const Limits = struct {
    /// Queued control answers (PING ACK, SETTINGS ACK, RST_STREAM) before
    /// the connection is closed: nghttp2's max_outbound_ack
    /// (NGHTTP2_DEFAULT_MAX_OBQ_FLOOD_ITEM).
    control_frame_budget: u32 = 1000,
    /// Empty-frame flood (CVE-2019-9518): DATA, HEADERS and CONTINUATION
    /// frames with an empty payload and no END_STREAM, per connection per
    /// second. D15 point 2: unknown and extension frames count too, but not
    /// RFC 9218's PRIORITY_UPDATE. Kept at 100 by the D15 point 5
    /// calibration (legitimate clients sent none).
    empty_frame_rate: u32 = 100,
    /// nghttp2's glitch limiter (session_update_glitch_ratelim; burst and
    /// rate per second), which PLAN §5.4 doesn't name. conn.zig charges it
    /// for what the empty-frame budget doesn't take (header blocks decoded
    /// only for the table), GOAWAY ENHANCE_YOUR_CALM when empty. Not for
    /// PRIORITY or PRIORITY_UPDATE, which nghttp2 charges here: the D15
    /// point 5 calibration measured Chromium above the 330/s rate with
    /// them (h2/INTENTIONAL.md, limits 9).
    glitch_burst: u64 = 10000,
    glitch_rate: u64 = 330,
    /// Bytes queued for the peer and not yet written past which new
    /// streams are refused (CVE-2019-9517, a peer that stops reading; PLAN
    /// §3.3, h2o's H2O_HTTP2_DEFAULT_OUTBUF_SOFT_MAX_SIZE). The write
    /// timeout that then closes the connection is M3's sweeper.
    out_high: usize = 1 << 20,
    /// SETTINGS entries in one frame (nghttp2's NGHTTP2_DEFAULT_MAX_SETTINGS);
    /// more is ENHANCE_YOUR_CALM (frame.Options.max_settings).
    max_settings: u8 = 32,
};
