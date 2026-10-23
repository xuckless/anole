// Adapted from rockorager/libvaxis src/ctlseqs.zig (MIT, Copyright (c) 2023 Tim Culverhouse),
// commit bb94364. See THIRD_PARTY_NOTICES.
//! The control sequences the console uses: alternate screen, cursor, SGR,
//! synchronized output and bracketed paste. A subset of libvaxis's constants.

// sync
pub const sync_set = "\x1b[?2026h";
pub const sync_reset = "\x1b[?2026l";

// bracketed paste
pub const bp_set = "\x1b[?2004h";
pub const bp_reset = "\x1b[?2004l";

// cursor
pub const home = "\x1b[H";
pub const cup = "\x1b[{d};{d}H";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";

// erase
pub const erase_below_cursor = "\x1b[J";

// alt screen
pub const smcup = "\x1b[?1049h";
pub const rmcup = "\x1b[?1049l";

// sgr reset all
pub const sgr_reset = "\x1b[m";

// colors (the 16 basic ones: 0-7 normal, 0-7 bright)
pub const fg_base = "\x1b[3{d}m";
pub const fg_bright = "\x1b[9{d}m";
pub const bg_base = "\x1b[4{d}m";
pub const bg_bright = "\x1b[10{d}m";
pub const fg_reset = "\x1b[39m";
pub const bg_reset = "\x1b[49m";

// attributes
pub const bold_set = "\x1b[1m";
pub const dim_set = "\x1b[2m";
pub const reverse_set = "\x1b[7m";
pub const ul_single = "\x1b[4m";
pub const bold_dim_reset = "\x1b[22m";
pub const reverse_reset = "\x1b[27m";
pub const ul_off = "\x1b[24m";
