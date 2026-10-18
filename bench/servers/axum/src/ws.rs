//! WebSockets: /ws/echo, /ws/feed (one global ticker) and /ws/trade (shared positions).
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    Router,
    extract::{
        State,
        ws::{Message, Utf8Bytes, WebSocket, WebSocketUpgrade},
    },
    response::Response,
    routing::any,
};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::env_or;

#[derive(Clone)]
struct WsState {
    feed: broadcast::Sender<Utf8Bytes>,
    positions: Arc<Mutex<HashMap<String, i64>>>,
}

pub fn routes() -> Router {
    let (feed, _) = broadcast::channel(4096);
    tokio::spawn(ticker(feed.clone(), env_or("TICK_HZ", 1000)));
    let state = WsState { feed, positions: Arc::default() };
    // `any` rather than `get`, so WebSockets over HTTP/2 (RFC 8441 CONNECT) work too.
    Router::new()
        .route("/ws/echo", any(ws_echo))
        .route("/ws/feed", any(ws_feed))
        .route("/ws/trade", any(ws_trade))
        .with_state(state)
}

async fn ws_echo(ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(|mut socket| async move {
        while let Some(Ok(msg)) = socket.recv().await {
            match msg {
                Message::Text(_) | Message::Binary(_) => {
                    if socket.send(msg).await.is_err() {
                        break;
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
    })
}

#[derive(Serialize)]
struct Tick {
    seq: u64,
    ts: u128,
    sym: &'static str,
    px: u64,
    qty: u64,
}

/// One ticker per process: wakes every 10 ms and broadcasts TICK_HZ/100 ticks.
async fn ticker(tx: broadcast::Sender<Utf8Bytes>, tick_hz: u64) {
    let mut interval = tokio::time::interval(Duration::from_millis(10));
    let mut seq = 0;
    loop {
        interval.tick().await;
        for _ in 0..tick_hz / 100 {
            seq += 1;
            let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_micros();
            let tick = Tick { seq, ts, sym: "BTCUSD", px: 100_000 + seq % 1000, qty: 1 + seq % 10 };
            // An error only means that nobody is subscribed right now.
            let _ = tx.send(serde_json::to_string(&tick).unwrap().into());
        }
    }
}

async fn ws_feed(ws: WebSocketUpgrade, State(state): State<WsState>) -> Response {
    ws.on_upgrade(move |mut socket| async move {
        let mut ticks = state.feed.subscribe();
        loop {
            tokio::select! {
                tick = ticks.recv() => match tick {
                    Ok(text) => {
                        if socket.send(Message::Text(text)).await.is_err() {
                            break;
                        }
                    }
                    Err(RecvError::Lagged(_)) => continue,
                    Err(RecvError::Closed) => break,
                },
                // Client messages are ignored; stop when it goes away.
                msg = socket.recv() => match msg {
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
            }
        }
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Side {
    Buy,
    Sell,
}

#[derive(Deserialize)]
struct Order {
    id: i64,
    sym: String,
    side: Side,
    px: i64,
    qty: i64,
    t: i64,
}

#[derive(Serialize)]
struct Fill {
    id: i64,
    status: &'static str,
    px: i64,
    qty: i64,
    pos: i64,
    t: i64,
}

async fn ws_trade(ws: WebSocketUpgrade, State(state): State<WsState>) -> Response {
    ws.on_upgrade(move |socket| trade_session(socket, state.positions))
}

async fn trade_session(mut socket: WebSocket, positions: Arc<Mutex<HashMap<String, i64>>>) {
    while let Some(Ok(msg)) = socket.recv().await {
        let order: Order = match &msg {
            Message::Text(text) => match serde_json::from_str(text) {
                Ok(order) => order,
                Err(_) => continue,
            },
            Message::Close(_) => break,
            _ => continue,
        };
        let delta = match order.side {
            Side::Buy => order.qty,
            Side::Sell => -order.qty,
        };
        let pos = {
            let mut positions = positions.lock().unwrap();
            let net = positions.entry(order.sym).or_insert(0);
            *net += delta;
            *net
        };
        let fill = Fill { id: order.id, status: "filled", px: order.px, qty: order.qty, pos, t: order.t };
        let reply = serde_json::to_string(&fill).unwrap();
        if socket.send(Message::Text(reply.into())).await.is_err() {
            break;
        }
    }
}
