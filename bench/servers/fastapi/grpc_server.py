"""grpc.testing.TestService/UnaryCall on grpc.aio (MODE=grpc).

WORKERS > 1 runs one process per worker, each with its own grpc.aio server
bound to the same port through SO_REUSEPORT, as in grpcio's multiprocessing
example (examples/python/multiprocessing).
"""

import asyncio
import multiprocessing
import os

import grpc

# Generated in the Docker build from tests/grpc/proto (see Dockerfile).
from interop.grpc.testing import messages_pb2, test_pb2_grpc

PORT = os.environ.get("GRPC_PORT", "50051")
WORKERS = int(os.environ.get("WORKERS", "1"))


class TestService(test_pb2_grpc.TestServiceServicer):
    async def UnaryCall(self, request, context):
        return messages_pb2.SimpleResponse(
            payload=messages_pb2.Payload(
                type=request.response_type, body=bytes(request.response_size)
            )
        )


async def serve():
    server = grpc.aio.server(options=[("grpc.so_reuseport", 1)])
    test_pb2_grpc.add_TestServiceServicer_to_server(TestService(), server)
    server.add_insecure_port(f"0.0.0.0:{PORT}")
    await server.start()
    await server.wait_for_termination()


def run():
    asyncio.run(serve())


if __name__ == "__main__":
    if WORKERS <= 1:
        run()
    else:
        workers = [multiprocessing.Process(target=run) for _ in range(WORKERS)]
        for w in workers:
            w.start()
        for w in workers:
            w.join()
