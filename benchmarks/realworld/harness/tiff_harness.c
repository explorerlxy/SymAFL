#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <tiffio.h>

#include "stdin_util.h"

#define MAX_INPUT_SIZE (32u * 1024u * 1024u)
#define MAX_SCANLINE_SIZE (32u * 1024u * 1024u)
#define MAX_ROWS 262144u

typedef struct {
  const uint8_t *data;
  size_t size;
  size_t pos;
} mem_image_t;

static tmsize_t mem_read(thandle_t handle, void *buffer, tmsize_t amount) {
  mem_image_t *mem = (mem_image_t *)handle;
  size_t remaining = mem->size - mem->pos;
  size_t copy = (size_t)amount;
  if (copy > remaining) {
    copy = remaining;
  }
  memcpy(buffer, mem->data + mem->pos, copy);
  mem->pos += copy;
  return (tmsize_t)copy;
}

static tmsize_t mem_write(thandle_t handle, void *buffer, tmsize_t amount) {
  (void)handle;
  (void)buffer;
  (void)amount;
  return 0;
}

static uint64 mem_seek(thandle_t handle, uint64 offset, int whence) {
  mem_image_t *mem = (mem_image_t *)handle;
  uint64 next = 0;
  if (whence == SEEK_SET) {
    next = offset;
  } else if (whence == SEEK_CUR) {
    next = (uint64)mem->pos + offset;
  } else if (whence == SEEK_END) {
    next = (uint64)mem->size + offset;
  } else {
    return (uint64)-1;
  }
  if (next > (uint64)mem->size) {
    return (uint64)-1;
  }
  mem->pos = (size_t)next;
  return next;
}

static int mem_close(thandle_t handle) {
  (void)handle;
  return 0;
}

static uint64 mem_size(thandle_t handle) {
  return (uint64)((mem_image_t *)handle)->size;
}

int main(void) {
  size_t input_size = 0;
  uint8_t *input = symafl_read_stdin(&input_size, MAX_INPUT_SIZE);
  if (!input || input_size == 0) {
    free(input);
    return input ? 1 : 2;
  }

  mem_image_t mem = {input, input_size, 0};
  TIFF *tiff = TIFFClientOpen("stdin.tiff", "rb", (thandle_t)&mem,
                              mem_read, mem_write, mem_seek, mem_close,
                              mem_size, NULL, NULL);
  if (!tiff) {
    free(input);
    return 1;
  }

  int rc = 1;
  do {
    uint32 width = 0, height = 0;
    TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
    TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
    tmsize_t scanline = TIFFScanlineSize(tiff);
    if (width && height && height <= MAX_ROWS && scanline > 0 &&
        (size_t)scanline <= MAX_SCANLINE_SIZE) {
      uint8 *row = (uint8 *)_TIFFmalloc((tmsize_t)scanline);
      if (!row) {
        break;
      }
      uint32 row_index = 0;
      for (; row_index < height; ++row_index) {
        if (TIFFReadScanline(tiff, row, row_index, 0) != 1) {
          break;
        }
      }
      _TIFFfree(row);
      if (row_index == height) {
        rc = 0;
      }
    }
  } while (TIFFReadDirectory(tiff));

  TIFFClose(tiff);
  free(input);
  return rc;
}
