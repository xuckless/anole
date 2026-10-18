// Fastify image, MODE=grpc: grpc.testing.TestService/UnaryCall through @grpc/grpc-js.
import * as grpc from '@grpc/grpc-js';
import * as protoLoader from '@grpc/proto-loader';

const PROTO_ROOT = new URL('./proto/', import.meta.url).pathname;

export async function startGrpc(port) {
  const definition = await protoLoader.load('grpc/testing/test.proto', {
    includeDirs: [PROTO_ROOT],
    keepCase: true,
    longs: String,
    enums: String,
    defaults: true,
    oneofs: true,
  });
  const { grpc: { testing } } = grpc.loadPackageDefinition(definition);

  const server = new grpc.Server();
  server.addService(testing.TestService.service, {
    // Interop semantics: a payload of response_size zero bytes.
    unaryCall(call, callback) {
      callback(null, { payload: { type: 'COMPRESSABLE', body: Buffer.alloc(call.request.response_size) } });
    },
  });
  await new Promise((resolve, reject) =>
    server.bindAsync(`0.0.0.0:${port}`, grpc.ServerCredentials.createInsecure(), (err) => (err ? reject(err) : resolve())),
  );
}
