#ifndef SYMAFL_STDIN_UTIL_H
#define SYMAFL_STDIN_UTIL_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint8_t *symafl_read_stdin(size_t *size_out, size_t max_size) {
  uint8_t *buf = (uint8_t *)malloc(max_size + 1);
  size_t size = 0;
  if (!buf) {
    *size_out = 0;
    return NULL;
  }

  while (size < max_size) {
    size_t n = fread(buf + size, 1, max_size - size, stdin);
    size += n;
    if (n == 0) {
      break;
    }
  }

  buf[size] = 0;
  *size_out = size;
  return buf;
}

#endif
