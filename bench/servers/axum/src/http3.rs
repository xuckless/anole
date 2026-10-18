//! HTTP/3: quinn accepts QUIC connections, h3 parses requests, and each request goes
//! through the same axum Router as a tower Service.
use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::{Router, body::Body};
use bytes::{Buf, Bytes, BytesMut};
use h3::server::RequestResolver;
use http_body_util::BodyExt;
use quinn::crypto::rustls::QuicServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use tower::ServiceExt;

use crate::BoxError;

pub async fn serve(addr: SocketAddr, cert: &str, key: &str, app: Router) -> Result<(), BoxError> {
    let certs = CertificateDer::pem_file_iter(cert)?.collect::<Result<Vec<_>, _>>()?;
    let key = PrivateKeyDer::from_pem_file(key)?;
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;
    tls.alpn_protocols = vec![b"h3".to_vec()];
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    // quinn's default idle timeout is 30 s; the bench keeps idle connections for 75 s or more.
    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(Duration::from_secs(120).try_into()?));
    config.transport_config(Arc::new(transport));
    let endpoint = quinn::Endpoint::server(config, addr)?;

    while let Some(incoming) = endpoint.accept().await {
        let app = app.clone();
        tokio::spawn(async move {
            let Ok(conn) = incoming.await else { return };
            let Ok(mut conn) = h3::server::Connection::new(h3_quinn::Connection::new(conn)).await
            else {
                return;
            };
            // Ok(None) and Err both end the connection (closing is not an error worth logging).
            while let Ok(Some(resolver)) = conn.accept().await {
                let app = app.clone();
                tokio::spawn(async move {
                    if let Err(err) = request(resolver, app).await {
                        eprintln!("h3 request: {err}");
                    }
                });
            }
        });
    }
    Ok(())
}

async fn request(
    resolver: RequestResolver<h3_quinn::Connection, Bytes>,
    app: Router,
) -> Result<(), BoxError> {
    let (req, mut stream) = resolver.resolve_request().await?;

    // Collect the request body, then hand the request to the Router.
    let mut body = BytesMut::new();
    while let Some(mut chunk) = stream.recv_data().await? {
        while chunk.has_remaining() {
            let part = chunk.chunk();
            body.extend_from_slice(part);
            let n = part.len();
            chunk.advance(n);
        }
    }
    let res = app.oneshot(req.map(|()| Body::from(body.freeze()))).await?;

    // Send the head, then stream the body frames (and trailers, if any).
    let (parts, mut body) = res.into_parts();
    stream.send_response(axum::http::Response::from_parts(parts, ())).await?;
    while let Some(frame) = body.frame().await {
        match frame?.into_data() {
            Ok(data) => stream.send_data(data).await?,
            Err(frame) => {
                if let Ok(trailers) = frame.into_trailers() {
                    stream.send_trailers(trailers).await?;
                }
            }
        }
    }
    stream.finish().await?;
    Ok(())
}
