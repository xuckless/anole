/* src/capi/upb_shim.h - what the C ABI's gRPC server needs of upb
 * (protobuf's C runtime, built by build/upb.zig): a pool of message
 * descriptors from a FileDescriptorSet's files, the proto3 JSON mapping both
 * ways, and field lookups for JSON transcoding. Every function here is safe
 * to call from several threads at once on one pool once the files are in
 * (lookups and conversions only read it). MIT, part of Anole. */
#ifndef ANOLE_UPB_SHIM_H
#define ANOLE_UPB_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct anole_upb_pool anole_upb_pool;

/* NULL when out of memory. */
anole_upb_pool *anole_upb_pool_new(void);
void anole_upb_pool_free(anole_upb_pool *pool);

/* Adds one serialized google.protobuf.FileDescriptorProto. Its imports must
   be in already (a FileDescriptorSet from `protoc --include_imports` lists
   files in that order). 0 on success; else -1 with a message in err. */
int anole_upb_pool_add_file(anole_upb_pool *pool, const char *bytes, size_t len, char *err, size_t errcap);

/* A message type by its full name ("pkg.Msg", no leading dot); NULL when
   unknown. Valid while the pool lives. */
const void *anole_upb_message(const anole_upb_pool *pool, const char *name, size_t len);
/* The full name of a message type, NUL-terminated, valid while the pool lives. */
const char *anole_upb_message_name(const void *message);

/* JSON text (the proto3 mapping: Connect, gRPC-Web JSON, transcoding) to
   the message's protobuf bytes. `ignore_unknown`: fields the type does not
   have are skipped rather than refused. On success 0, and *out (malloc'd,
   freed with anole_upb_free; NULL for an empty message) and *out_len. -1:
   err says why (not JSON, not this message, nested too deep). -2: out of
   memory. */
int anole_upb_json_to_binary(const anole_upb_pool *pool, const void *message, const char *json, size_t len,
                             int ignore_unknown, char **out, size_t *out_len, char *err, size_t errcap);

/* Protobuf bytes to JSON text (lowerCamelCase names, enums by name; with
   `emit_defaults`, fields at their default too). Same returns. */
int anole_upb_binary_to_json(const anole_upb_pool *pool, const void *message, const char *bytes, size_t len,
                             int emit_defaults, char **out, size_t *out_len, char *err, size_t errcap);

void anole_upb_free(void *p);

/* What a field is, for transcoding's path variables and query parameters. */
enum {
  ANOLE_UPB_STRING = 1,
  ANOLE_UPB_BYTES = 2,
  ANOLE_UPB_BOOL = 3,
  ANOLE_UPB_NUMBER = 4,
  ANOLE_UPB_ENUM = 5,
  /* A well-known type whose JSON is a string or a number (Timestamp,
     Duration, FieldMask, the wrappers but BoolValue). */
  ANOLE_UPB_WKT_TEXT = 6,
  ANOLE_UPB_WKT_BOOL = 7,
  ANOLE_UPB_MESSAGE = 8,
  ANOLE_UPB_MAP = 9
};

typedef struct anole_upb_field {
  int kind;           /* ANOLE_UPB_* */
  int repeated;       /* a repeated field (not a map) */
  const char *name;   /* the field's own (proto) name, NUL-terminated */
  const void *message; /* the field's message type, for ANOLE_UPB_MESSAGE */
  const void *enumdef; /* the field's enum, for ANOLE_UPB_ENUM */
} anole_upb_field;

/* The field `name` (its proto name or its JSON name) of `message`: 0 and
   *out, or -1 when the message has none. */
int anole_upb_find_field(const void *message, const char *name, size_t len, anole_upb_field *out);

/* 1 when `name` is a value of the enum. */
int anole_upb_enum_has(const void *enumdef, const char *name, size_t len);

#endif
