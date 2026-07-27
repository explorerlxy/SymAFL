#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include <zstd.h>

#include "stdin_util.h"

#define MAX_INPUT_SIZE (32u * 1024u * 1024u)
#define MAX_OUTPUT_SIZE (128u * 1024u * 1024u)

int main(void) {
  size_t input_size = 0;
  uint8_t *input = symafl_read_stdin(&input_size, MAX_INPUT_SIZE);
  if (!input || input_size == 0) {
    free(input);
    return input ? 1 : 2;
  }

  unsigned long long content_size = ZSTD_getFrameContentSize(input, input_size);
  if (content_size == ZSTD_CONTENTSIZE_ERROR ||
      content_size == ZSTD_CONTENTSIZE_UNKNOWN ||
      content_size > MAX_OUTPUT_SIZE) {
    free(input);
    return 1;
  }

  uint8_t *output = (uint8_t *)malloc((size_t)content_size + 1);
  if (!output) {
    free(input);
    return 2;
  }

  size_t produced = ZSTD_decompress(output, (size_t)content_size, input,
                                    input_size);
  int rc = ZSTD_isError(produced) ? 1 : 0;
  free(output);
  free(input);
  return rc;
}
