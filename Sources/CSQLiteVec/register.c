#include "CSQLiteVec.h"
#include "sqlite-vec.h"

int mb_sqlite_vec_register(sqlite3 *db) {
    return sqlite3_vec_init(db, 0, 0);
}
