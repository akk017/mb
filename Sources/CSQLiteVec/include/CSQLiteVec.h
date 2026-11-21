#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H
#include <sqlite3.h>

/// Registers sqlite-vec (vec0 virtual table + vec_* functions) on a connection.
/// sqlite-vec is compiled statically with SQLITE_CORE, so it links against the
/// same libsqlite3 that GRDB uses — no loadable-extension support needed.
int mb_sqlite_vec_register(sqlite3 *db);

#endif
