fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The interop proto lives at the repository root (the Dockerfile copies it to the same place).
    tonic_prost_build::configure()
        .build_client(false)
        .generate_default_stubs(true)
        .compile_protos(
            &["../../../tests/grpc/proto/grpc/testing/test.proto"],
            &["../../../tests/grpc/proto"],
        )?;
    Ok(())
}
