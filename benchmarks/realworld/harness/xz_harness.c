#include <stdint.h>
#include <stdlib.h>

#include <lzma.h>

#include "stdin_util.h"

#define MAX_INPUT_SIZE (32u * 1024u * 1024u)
#define MAX_OUTPUT_TOTAL (128u * 1024u * 1024u)
#define OUT_CHUNK (128u * 1024u)

int main(void) {
  size_t input_size = 0;
  uint8_t *input = symafl_read_stdin(&input_size, MAX_INPUT_SIZE);
  if (!input || input_size == 0) {
    free(input);
    return input ? 1 : 2;
  }

  uint8_t *output = (uint8_t *)malloc(OUT_CHUNK);
  lzma_stream stream = LZMA_STREAM_INIT;
  lzma_ret init_ret = lzma_stream_decoder(&stream, UINT64_MAX, 0);
  if (!output || init_ret != LZMA_OK) {
    free(output);
    free(input);
    lzma_end(&stream);
    return 2;
  }

  stream.next_in = input;
  stream.avail_in = input_size;
  size_t produced_total = 0;
  int rc = 0;

  while (stream.avail_in > 0) {
    stream.next_out = output;
    stream.avail_out = OUT_CHUNK;
    lzma_ret ret = lzma_code(&stream, LZMA_RUN);
    produced_total += OUT_CHUNK - stream.avail_out;
    if (ret == LZMA_STREAM_END) {
      break;
    }
    if (ret != LZMA_OK) {
      rc = 1;
      break;
    }
    if (produced_total > MAX_OUTPUT_TOTAL) {
      rc = 1;
      break;
    }
  }

  lzma_end(&stream);
  free(output);
  free(input);
  return rc;
}
