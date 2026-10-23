// Adapted from vkiryakov/zefir src/nats/protocol/golden.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Frames recorded from nats-server 2.15.1 on 2026-10-12. INFO lines keep
//! the space nats-server writes before CRLF.

/// The first INFO of a plain server.
pub const info_default_json =
    \\{"server_id":"NDJ4DBN7J4ULMEM3QU2AGOEB5L6AI73JUHMC5MWB73VBXE7NPJENANEX","server_name":"NDJ4DBN7J4ULMEM3QU2AGOEB5L6AI73JUHMC5MWB73VBXE7NPJENANEX","version":"2.15.1","proto":1,"git_commit":"b2fd3ef","go":"go1.27.2","host":"127.0.0.1","port":14222,"headers":true,"max_payload":1048576,"client_id":6,"client_ip":"127.0.0.1","api_lvl":5,"xkey":"XDAPZVFAWRNALOOLEQ3ZMBOPID5RKHQN3LAUVGOR3PFEQADYIMCCX6YO"}
;
/// The INFO a server sends right after the PONG to the first PING.
pub const info_connected_json =
    \\{"server_id":"NDJ4DBN7J4ULMEM3QU2AGOEB5L6AI73JUHMC5MWB73VBXE7NPJENANEX","server_name":"NDJ4DBN7J4ULMEM3QU2AGOEB5L6AI73JUHMC5MWB73VBXE7NPJENANEX","version":"2.15.1","proto":1,"git_commit":"b2fd3ef","go":"go1.27.2","host":"127.0.0.1","port":14222,"headers":true,"max_payload":1048576,"client_id":6,"client_ip":"127.0.0.1","connect_info":true,"remote_account":"$G","api_lvl":5,"xkey":"XDAPZVFAWRNALOOLEQ3ZMBOPID5RKHQN3LAUVGOR3PFEQADYIMCCX6YO"}
;
/// A server with user and password.
pub const info_auth_json =
    \\{"server_id":"NBHOMELYAL5X6QXHH6YK43KEGZRYHLTQA5RQOK65UZUUUEP7QXDRYE5X","server_name":"NBHOMELYAL5X6QXHH6YK43KEGZRYHLTQA5RQOK65UZUUUEP7QXDRYE5X","version":"2.15.1","proto":1,"git_commit":"b2fd3ef","go":"go1.27.2","host":"127.0.0.1","port":14230,"headers":true,"auth_required":true,"max_payload":1048576,"client_id":5,"client_ip":"127.0.0.1","api_lvl":5,"xkey":"XD3YZJF3SDP6HA4PVLRCHNT6G5524RIUTB3A7Q4RU7ZCYMQDK3ET6TDY"}
;
/// A server that requires TLS.
pub const info_tls_json =
    \\{"server_id":"NCFS4HWI7SFOC75437ZFIS5AZSNILWKGSZHRHJKUH2V23JYXRIIXJ5TQ","server_name":"NCFS4HWI7SFOC75437ZFIS5AZSNILWKGSZHRHJKUH2V23JYXRIIXJ5TQ","version":"2.15.1","proto":1,"git_commit":"b2fd3ef","go":"go1.27.2","host":"127.0.0.1","port":14233,"headers":true,"tls_required":true,"max_payload":1048576,"client_id":5,"client_ip":"127.0.0.1","api_lvl":5,"xkey":"XBFPT2LYIPI5IH4LD57CA6WBZUA5PPEESGSX6FVYUFBXGFOTOGJHADJ2"}
;
/// Node A of a two-node cluster, after node B joined.
pub const info_cluster_json =
    \\{"server_id":"NC2KVA7RWGUMMKHI4CHTSZBOIND62ZAVR25N3O5FYW5FTTXTWO4UPLYO","server_name":"A","version":"2.15.1","proto":1,"git_commit":"b2fd3ef","go":"go1.27.2","host":"127.0.0.1","port":14234,"headers":true,"max_payload":1048576,"client_id":5,"client_ip":"127.0.0.1","cluster":"spike","connect_urls":["127.0.0.1:14234","127.0.0.1:14235"],"api_lvl":5,"xkey":"XA4ACQF6QG3SATTJZN5BYKMGXI4HTTUWFBD6KZJJBO35E53Q2WBCCFMK"}
;
/// Node B entering lame duck mode: it lists only the other node.
pub const info_ldm_json =
    \\{"server_id":"NCIR2H6TM6AK6XIZZMCGZR3R7GA2YYIWFGWRTNI7R7G67GI43TMDKSC3","server_name":"B","version":"2.15.1","proto":1,"git_commit":"b2fd3ef","go":"go1.27.2","host":"127.0.0.1","port":14235,"headers":true,"max_payload":1048576,"client_id":9,"client_ip":"127.0.0.1","cluster":"spike","connect_urls":["127.0.0.1:14234"],"ldm":true,"api_lvl":5,"xkey":"XAE64553FB45733UPUEHBKRMDYYHN7ANIG2YF3J23RWEL7JC4M2HTDYG"}
;

pub const info_default = "INFO " ++ info_default_json ++ " \r\n";
pub const info_connected = "INFO " ++ info_connected_json ++ " \r\n";
pub const ping = "PING\r\n";
pub const pong = "PONG\r\n";
pub const msg_plain = "MSG foo 1 5\r\nhello\r\n";
pub const msg_reply = "MSG foo 1 reply.to.me 5\r\nworld\r\n";
pub const msg_empty = "MSG foo.bar 2 0\r\n\r\n";
pub const msg_queue = "MSG q.work 3 4\r\njob1\r\n";
pub const hmsg_multi = "HMSG h.test 4 53 61\r\nNATS/1.0\r\nX-Multi: one\r\nX-Multi: two\r\nX-Single: v\r\n\r\npayload!\r\n";
pub const hmsg_header_only = "HMSG h.test 4 reply.h 32 32\r\nNATS/1.0\r\nX-Only-Header: yes\r\n\r\n\r\n";
pub const hmsg_no_responders = "HMSG _INBOX.spike.1 5 46 46\r\nNATS/1.0 503\r\nNats-Subject: nobody.listens\r\n\r\n\r\n";
pub const msg_auto_unsubscribe = "MSG once 6 1\r\na\r\n";
pub const err_authorization = "-ERR 'Authorization Violation'\r\n";
pub const err_authentication_timeout = "-ERR 'Authentication Timeout'\r\n";
pub const err_publish_permission = "-ERR 'Permissions Violation for Publish to \"secret.x\"'\r\n";
pub const err_subscription_permission = "-ERR 'Permissions Violation for Subscription to \"forbidden\"'\r\n";
pub const err_stale = "-ERR 'Stale Connection'\r\n";
pub const err_unknown_operation = "-ERR 'Unknown Protocol Operation'\r\n";
pub const err_max_payload = "-ERR 'Maximum Payload Violation'\r\n";

/// The server side of the recorded session, in order.
pub const session = info_default ++ pong ++ info_connected ++ msg_plain ++ msg_reply ++ msg_empty ++ msg_queue ++ pong ++
    hmsg_multi ++ hmsg_header_only ++ pong ++ hmsg_no_responders ++ pong ++ msg_auto_unsubscribe ++ pong ++ ping;

/// Every frame on its own, for the fuzz corpus.
pub const frames = [_][]const u8{
    info_default,      info_connected,             ping,                   pong,
    msg_plain,         msg_reply,                  msg_empty,              msg_queue,
    hmsg_multi,        hmsg_header_only,           hmsg_no_responders,     msg_auto_unsubscribe,
    err_authorization, err_authentication_timeout, err_publish_permission, err_subscription_permission,
    err_stale,         err_unknown_operation,      err_max_payload,
};
