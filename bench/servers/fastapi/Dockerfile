# FastAPI bench server (bench/SPEC.md). Build from the repository root:
#   docker build -f bench/servers/fastapi/Dockerfile -t anole-bench/fastapi .
FROM python:3.13.16-slim-trixie AS proto
RUN pip install --no-cache-dir --root-user-action=ignore grpcio-tools==1.84.0 protobuf==7.36.2
COPY tests/grpc/proto/grpc/testing/ /proto/interop/grpc/testing/
# Generated modules named grpc.testing.* would be shadowed by grpcio's own `grpc`
# package, so the protos go under interop/ (the proto package stays grpc.testing).
RUN sed -i 's|import "grpc/testing/|import "interop/grpc/testing/|' /proto/interop/grpc/testing/*.proto \
 && mkdir /gen && python -m grpc_tools.protoc -I /proto --python_out=/gen --grpc_python_out=/gen \
    /proto/interop/grpc/testing/empty.proto /proto/interop/grpc/testing/messages.proto \
    /proto/interop/grpc/testing/test.proto

FROM python:3.13.16-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY bench/servers/fastapi/requirements.txt .
RUN pip install --no-cache-dir --root-user-action=ignore -r requirements.txt
COPY --from=proto /gen/ /app/
COPY bench/servers/fastapi/app.py bench/servers/fastapi/grpc_server.py bench/servers/fastapi/hypercorn.toml \
     bench/servers/fastapi/h3_workers.py bench/servers/fastapi/entrypoint.sh ./
ENTRYPOINT ["/app/entrypoint.sh"]
