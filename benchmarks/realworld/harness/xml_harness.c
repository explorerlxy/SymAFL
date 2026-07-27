#include <stdint.h>
#include <stdlib.h>

#include <libxml/parser.h>
#include <libxml/tree.h>

#include "stdin_util.h"

#define MAX_INPUT_SIZE (32u * 1024u * 1024u)

int main(void) {
  size_t input_size = 0;
  uint8_t *input = symafl_read_stdin(&input_size, MAX_INPUT_SIZE);
  if (!input || input_size == 0) {
    free(input);
    return input ? 1 : 2;
  }

  xmlInitParser();
  xmlDoc *doc = xmlReadMemory((const char *)input, (int)input_size,
                              "stdin.xml", NULL,
                              XML_PARSE_NONET | XML_PARSE_NOERROR |
                                  XML_PARSE_NOWARNING);
  if (doc) {
    xmlFreeDoc(doc);
  }
  xmlCleanupParser();
  free(input);
  return doc ? 0 : 1;
}
