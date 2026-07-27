#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <openjpeg.h>

#include "stdin_util.h"

#define MAX_INPUT_SIZE (32u * 1024u * 1024u)

typedef struct {
  const uint8_t *data;
  size_t size;
  size_t pos;
} memory_source_t;

static OPJ_SIZE_T memory_read(void *buffer, OPJ_SIZE_T amount, void *opaque) {
  memory_source_t *source = (memory_source_t *)opaque;
  size_t remaining = source->size - source->pos;
  if (remaining == 0) {
    return (OPJ_SIZE_T)-1;
  }
  size_t copy = (size_t)amount;
  if (copy > remaining) {
    copy = remaining;
  }
  memcpy(buffer, source->data + source->pos, copy);
  source->pos += copy;
  return (OPJ_SIZE_T)copy;
}

static OPJ_OFF_T memory_skip(OPJ_OFF_T amount, void *opaque) {
  memory_source_t *source = (memory_source_t *)opaque;
  if (amount < 0) {
    OPJ_OFF_T backward = -amount;
    if ((OPJ_OFF_T)source->pos < backward) {
      return -1;
    }
    source->pos -= (size_t)backward;
    return amount;
  }
  if ((OPJ_OFF_T)(source->size - source->pos) < amount) {
    return -1;
  }
  source->pos += (size_t)amount;
  return amount;
}

static OPJ_BOOL memory_seek(OPJ_OFF_T position, void *opaque) {
  memory_source_t *source = (memory_source_t *)opaque;
  if (position < 0 || (uint64_t)position > (uint64_t)source->size) {
    return OPJ_FALSE;
  }
  source->pos = (size_t)position;
  return OPJ_TRUE;
}

static OPJ_BOOL looks_like_jp2(const uint8_t *data, size_t size) {
  static const uint8_t jp2_magic[12] = {0x00, 0x00, 0x00, 0x0c,
                                        0x6a, 0x50, 0x20, 0x20,
                                        0x0d, 0x0a, 0x87, 0x0a};
  return size >= sizeof(jp2_magic) &&
         memcmp(data, jp2_magic, sizeof(jp2_magic)) == 0;
}

int main(void) {
  size_t input_size = 0;
  uint8_t *input = symafl_read_stdin(&input_size, MAX_INPUT_SIZE);
  if (!input || input_size == 0) {
    free(input);
    return input ? 1 : 2;
  }

  memory_source_t source = {input, input_size, 0};
  opj_dparameters_t params;
  opj_set_default_decoder_parameters(&params);
  params.decod_format = looks_like_jp2(input, input_size) ? OPJ_CODEC_JP2
                                                          : OPJ_CODEC_J2K;

  opj_codec_t *codec = opj_create_decompress(params.decod_format);
  opj_stream_t *stream = opj_stream_create(OPJ_J2K_STREAM_CHUNK_SIZE, OPJ_TRUE);
  opj_image_t *image = NULL;
  int rc = 1;

  if (stream) {
    opj_stream_set_read_function(stream, memory_read);
    opj_stream_set_skip_function(stream, memory_skip);
    opj_stream_set_seek_function(stream, memory_seek);
    opj_stream_set_user_data(stream, &source, NULL);
    opj_stream_set_user_data_length(stream, (OPJ_UINT64)input_size);
  }

  if (codec && stream && opj_setup_decoder(codec, &params) &&
      opj_read_header(stream, codec, &image) && image &&
      opj_decode(codec, stream, image)) {
    (void)opj_end_decompress(codec, stream);
    rc = 0;
  }

  opj_image_destroy(image);
  opj_stream_destroy(stream);
  opj_destroy_codec(codec);
  free(input);
  return rc;
}
