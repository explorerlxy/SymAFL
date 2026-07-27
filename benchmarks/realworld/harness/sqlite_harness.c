#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <sqlite3.h>

#include "stdin_util.h"

#define MAX_INPUT_SIZE (32u * 1024u * 1024u)

static int is_database_image(const uint8_t *input, size_t size) {
  static const char header[] = "SQLite format 3";
  return size >= 16 && memcmp(input, header, sizeof(header)) == 0;
}

int main(void) {
  size_t input_size = 0;
  uint8_t *input = symafl_read_stdin(&input_size, MAX_INPUT_SIZE);
  if (!input || input_size == 0) {
    free(input);
    return input ? 1 : 2;
  }

  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2(":memory:", &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
  if (rc != SQLITE_OK || !db) {
    sqlite3_close(db);
    free(input);
    return 2;
  }

  char *error = NULL;
  if (is_database_image(input, input_size)) {
    rc = sqlite3_deserialize(db, "main", input, (sqlite3_int64)input_size,
                             (sqlite3_int64)input_size,
                             SQLITE_DESERIALIZE_FREEONCLOSE |
                                 SQLITE_DESERIALIZE_READONLY);
    if (rc == SQLITE_OK) {
      input = NULL;
      rc = sqlite3_exec(db, "SELECT count(*) FROM sqlite_schema", NULL, NULL,
                        &error);
    }
  } else {
    rc = sqlite3_exec(db, (const char *)input, NULL, NULL, &error);
  }

  sqlite3_free(error);
  sqlite3_close(db);
  free(input);
  return rc == SQLITE_OK ? 0 : 1;
}
