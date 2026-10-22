/* src/capi/upb_shim.c - see upb_shim.h. MIT, part of Anole. */
#include "upb_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ruby-upb.h"

/* Protobuf input nests at most this deep (upb's own default), JSON too. */
#define MAX_DEPTH 100

struct anole_upb_pool {
  upb_DefPool *defs;
  /* The parsed FileDescriptorProtos the defs were built from. */
  upb_Arena *files;
};

anole_upb_pool *anole_upb_pool_new(void) {
  anole_upb_pool *p = calloc(1, sizeof *p);
  if (!p) return NULL;
  p->defs = upb_DefPool_New();
  p->files = upb_Arena_New();
  if (!p->defs || !p->files) {
    anole_upb_pool_free(p);
    return NULL;
  }
  return p;
}

void anole_upb_pool_free(anole_upb_pool *p) {
  if (!p) return;
  if (p->defs) upb_DefPool_Free(p->defs);
  if (p->files) upb_Arena_Free(p->files);
  free(p);
}

static void set_err(char *err, size_t cap, const char *what, const char *detail) {
  if (cap == 0) return;
  if (detail && detail[0])
    snprintf(err, cap, "%s: %s", what, detail);
  else
    snprintf(err, cap, "%s", what);
}

int anole_upb_pool_add_file(anole_upb_pool *p, const char *bytes, size_t len, char *err, size_t errcap) {
  google_protobuf_FileDescriptorProto *file = google_protobuf_FileDescriptorProto_parse(bytes, len, p->files);
  if (!file) {
    set_err(err, errcap, "not a FileDescriptorProto", NULL);
    return -1;
  }
  upb_Status status;
  upb_Status_Clear(&status);
  if (!upb_DefPool_AddFile(p->defs, file, &status)) {
    set_err(err, errcap, "descriptor refused", upb_Status_ErrorMessage(&status));
    return -1;
  }
  return 0;
}

const void *anole_upb_message(const anole_upb_pool *p, const char *name, size_t len) {
  return upb_DefPool_FindMessageByNameWithSize(p->defs, name, len);
}

const char *anole_upb_message_name(const void *m) { return upb_MessageDef_FullName((const upb_MessageDef *)m); }

static int copy_out(const char *data, size_t len, char **out, size_t *out_len) {
  *out = NULL;
  *out_len = len;
  if (len == 0) return 0;
  *out = malloc(len);
  if (!*out) return -2;
  memcpy(*out, data, len);
  return 0;
}

int anole_upb_json_to_binary(const anole_upb_pool *p, const void *message, const char *json, size_t len,
                             int ignore_unknown, char **out, size_t *out_len, char *err, size_t errcap) {
  const upb_MessageDef *m = message;
  upb_Arena *arena = upb_Arena_New();
  if (!arena) return -2;
  int rc = -1;
  upb_Status status;
  upb_Status_Clear(&status);
  const upb_MiniTable *mt = upb_MessageDef_MiniTable(m);
  upb_Message *msg = upb_Message_New(mt, arena);
  if (!msg) {
    rc = -2;
    goto done;
  }
  int options = ignore_unknown ? upb_JsonDecode_IgnoreUnknown : 0;
  if (upb_JsonDecodeDetectingNonconformance(json, len, msg, m, p->defs, options, arena, &status) ==
      kUpb_JsonDecodeResult_Error) {
    set_err(err, errcap, "the JSON is not this message", upb_Status_ErrorMessage(&status));
    goto done;
  }
  char *bin = NULL;
  size_t bin_len = 0;
  upb_EncodeStatus es = upb_Encode(msg, mt, upb_EncodeOptions_MaxDepth(MAX_DEPTH), arena, &bin, &bin_len);
  if (es != kUpb_EncodeStatus_Ok) {
    rc = es == kUpb_EncodeStatus_OutOfMemory ? -2 : -1;
    set_err(err, errcap, "the message does not encode", NULL);
    goto done;
  }
  rc = copy_out(bin, bin_len, out, out_len);
done:
  upb_Arena_Free(arena);
  return rc;
}

int anole_upb_binary_to_json(const anole_upb_pool *p, const void *message, const char *bytes, size_t len,
                             int emit_defaults, char **out, size_t *out_len, char *err, size_t errcap) {
  const upb_MessageDef *m = message;
  upb_Arena *arena = upb_Arena_New();
  if (!arena) return -2;
  int rc = -1;
  const upb_MiniTable *mt = upb_MessageDef_MiniTable(m);
  upb_Message *msg = upb_Message_New(mt, arena);
  if (!msg) {
    rc = -2;
    goto done;
  }
  upb_DecodeStatus ds = upb_Decode(bytes, len, msg, mt, upb_DefPool_ExtensionRegistry(p->defs),
                                   upb_DecodeOptions_MaxDepth(MAX_DEPTH), arena);
  if (ds != kUpb_DecodeStatus_Ok) {
    rc = ds == kUpb_DecodeStatus_OutOfMemory ? -2 : -1;
    set_err(err, errcap, "the bytes are not this message", upb_DecodeStatus_String(ds));
    goto done;
  }
  upb_Status status;
  upb_Status_Clear(&status);
  int options = emit_defaults ? upb_JsonEncode_EmitDefaults : 0;
  char small[512];
  size_t need = upb_JsonEncode(msg, m, p->defs, options, small, sizeof small, &status);
  if (!upb_Status_IsOk(&status)) {
    set_err(err, errcap, "the message does not encode as JSON", upb_Status_ErrorMessage(&status));
    goto done;
  }
  if (need < sizeof small) {
    rc = copy_out(small, need, out, out_len);
    goto done;
  }
  char *big = malloc(need + 1);
  if (!big) {
    rc = -2;
    goto done;
  }
  upb_Status_Clear(&status);
  upb_JsonEncode(msg, m, p->defs, options, big, need + 1, &status);
  if (!upb_Status_IsOk(&status)) {
    free(big);
    set_err(err, errcap, "the message does not encode as JSON", upb_Status_ErrorMessage(&status));
    goto done;
  }
  *out = big;
  *out_len = need;
  rc = 0;
done:
  upb_Arena_Free(arena);
  return rc;
}

void anole_upb_free(void *ptr) { free(ptr); }

static int wkt_kind(const upb_MessageDef *m) {
  switch (upb_MessageDef_WellKnownType(m)) {
    case kUpb_WellKnown_Timestamp:
    case kUpb_WellKnown_Duration:
    case kUpb_WellKnown_FieldMask:
    case kUpb_WellKnown_DoubleValue:
    case kUpb_WellKnown_FloatValue:
    case kUpb_WellKnown_Int64Value:
    case kUpb_WellKnown_UInt64Value:
    case kUpb_WellKnown_Int32Value:
    case kUpb_WellKnown_UInt32Value:
    case kUpb_WellKnown_StringValue:
    case kUpb_WellKnown_BytesValue:
      return ANOLE_UPB_WKT_TEXT;
    case kUpb_WellKnown_BoolValue:
      return ANOLE_UPB_WKT_BOOL;
    default:
      return ANOLE_UPB_MESSAGE;
  }
}

int anole_upb_find_field(const void *message, const char *name, size_t len, anole_upb_field *out) {
  const upb_MessageDef *m = message;
  const upb_FieldDef *f = upb_MessageDef_FindByJsonNameWithSize(m, name, len);
  if (!f) f = upb_MessageDef_FindFieldByNameWithSize(m, name, len);
  if (!f) return -1;
  memset(out, 0, sizeof *out);
  out->name = upb_FieldDef_Name(f);
  if (upb_FieldDef_IsMap(f)) {
    out->kind = ANOLE_UPB_MAP;
    return 0;
  }
  out->repeated = upb_FieldDef_IsRepeated(f);
  switch (upb_FieldDef_CType(f)) {
    case kUpb_CType_Bool:
      out->kind = ANOLE_UPB_BOOL;
      break;
    case kUpb_CType_String:
      out->kind = ANOLE_UPB_STRING;
      break;
    case kUpb_CType_Bytes:
      out->kind = ANOLE_UPB_BYTES;
      break;
    case kUpb_CType_Enum:
      out->kind = ANOLE_UPB_ENUM;
      out->enumdef = upb_FieldDef_EnumSubDef(f);
      break;
    case kUpb_CType_Message:
      out->message = upb_FieldDef_MessageSubDef(f);
      out->kind = wkt_kind(out->message);
      break;
    default:
      out->kind = ANOLE_UPB_NUMBER;
      break;
  }
  return 0;
}

int anole_upb_enum_has(const void *enumdef, const char *name, size_t len) {
  return upb_EnumDef_FindValueByNameWithSize((const upb_EnumDef *)enumdef, name, len) != NULL;
}
