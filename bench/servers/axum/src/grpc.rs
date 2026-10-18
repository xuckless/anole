//! gRPC: grpc.testing.TestService/UnaryCall with tonic (code generated in build.rs).
use std::net::SocketAddr;

use tonic::{Request, Response, Status, transport::Server};

use crate::BoxError;

#[allow(dead_code)]
pub mod pb {
    tonic::include_proto!("grpc.testing");
}

use pb::{
    Payload, PayloadType, SimpleRequest, SimpleResponse,
    test_service_server::{TestService, TestServiceServer},
};

struct Interop;

#[tonic::async_trait]
impl TestService for Interop {
    /// Answers with `response_size` zero bytes (the interop semantics).
    async fn unary_call(
        &self,
        request: Request<SimpleRequest>,
    ) -> Result<Response<SimpleResponse>, Status> {
        let size = usize::try_from(request.get_ref().response_size)
            .map_err(|_| Status::invalid_argument("response_size must not be negative"))?;
        Ok(Response::new(SimpleResponse {
            payload: Some(Payload { r#type: PayloadType::Compressable.into(), body: vec![0; size] }),
            ..Default::default()
        }))
    }
}

pub async fn serve(addr: SocketAddr) -> Result<(), BoxError> {
    Server::builder()
        .add_service(TestServiceServer::new(Interop))
        .serve(addr)
        .await?;
    Ok(())
}
