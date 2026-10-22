//! The realtime connection over WebSocket: GET /ws?token=…

use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};

use crate::state::{App, ConnectError, Out, Rx};
use crate::{Shared, error_response};

const CLOSE_TOO_BIG: u16 = 1009;

pub async fn handler(
    State(app): State<Shared>,
    Query(query): Query<HashMap<String, String>>,
    ws: WebSocketUpgrade,
) -> Response {
    let (user, conn, rx) = match app.connect(query.get("token").map(String::as_str)) {
        Ok(c) => c,
        Err(ConnectError::Unauthorized) => {
            return error_response(StatusCode::UNAUTHORIZED, "unauthorized");
        }
        Err(ConnectError::Conflict) => {
            return error_response(StatusCode::CONFLICT, "already connected");
        }
    };
    let failed = app.clone();
    ws.on_failed_upgrade(move |_| failed.disconnect(user, conn))
        .on_upgrade(move |socket| run(app, user, conn, rx, socket))
}

async fn run(app: Arc<App>, user: u64, conn: u64, mut rx: Rx, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let (close_tx, mut close_rx) = tokio::sync::oneshot::channel::<u16>();

    let writer = tokio::spawn(async move {
        loop {
            tokio::select! {
                // The close check first: a close follows the disconnect
                // that also ends `rx`.
                biased;
                code = &mut close_rx => {
                    if let Ok(code) = code {
                        let frame = CloseFrame { code, reason: "message too big".into() };
                        let _ = sink.send(Message::Close(Some(frame))).await;
                    }
                    break;
                }
                out = rx.recv() => {
                    let msg = match out {
                        Some(Out::Text(t)) => Message::Text(t.into()),
                        Some(Out::Media(m)) => Message::Binary(m),
                        None => break,
                    };
                    if sink.send(msg).await.is_err() {
                        break;
                    }
                }
            }
        }
        let _ = sink.close().await;
    });

    app.open(user);
    let mut close_tx = Some(close_tx);
    while let Some(Ok(msg)) = stream.next().await {
        match msg {
            Message::Text(t) => app.text(user, t.as_str()),
            Message::Binary(b) => {
                if app.media(user, &b).is_err() {
                    if let Some(tx) = close_tx.take() {
                        let _ = tx.send(CLOSE_TOO_BIG);
                    }
                    break;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }
    app.disconnect(user, conn);
    drop(close_tx);
    let _ = writer.await;
}
