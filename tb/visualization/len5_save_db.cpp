// len5_save_db.cpp
//
// Exposes SQLite DB + prepared statement handles to SystemVerilog via DPI
// using 64-bit handles for db and stmt.
//
// Notes:
// - No C++ exceptions cross the DPI boundary.
// - Handles are uint64_t values that represent sqlite3* and sqlite3_stmt* pointers.
// - Wrap inserts in a transaction for speed.

#include <sqlite3.h>
#include <filesystem>
#include <cstdint>
#include <iostream>
#include <string.h>
#include "verilated_dpi.h"
#include "svdpi.h"      

// --------------------------------------------------
// Macros
// --------------------------------------------------
#define PC_GEN_SIZE             9
// --------------------------------------------------
// Struct for keeping the values between the calls
// --------------------------------------------------

struct TraceCycle{
    uint64_t cycle = 0;
    uint64_t time = 0;
    uint8_t* pc_gen = nullptr;
};
// --------------------------------------------------
// FUNCTIONS
// --------------------------------------------------

// --------------------------------------------------
// check_rc
//   - check the status of sqlite exec
//   Returns 0 on success, -1 on failure.
// --------------------------------------------------
static int check_rc(int rc)
{
    // SQLITE_OK, SQLITE_DONE and SQLITE_ROW are possible returns
    if (rc == SQLITE_OK || rc == SQLITE_DONE || rc == SQLITE_ROW) return 0;
    return -1;
}

extern "C" {
// --------------------------------------------------
// Functions imported to verilator
// --------------------------------------------------


// --------------------------------------------------
// dpi_init_database
//   - opens/creates DB
//   - creates table
//   - prepares reusable INSERT statement
//   - begins transaction
//   - stores pointers to db and stmt into theirs handles for system verilog to pass
//   Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_init_database(const char* filename,
                      uint64_t* db_handle,
                      uint64_t* stmt_handle)
{
    if (!filename || !db_handle || !stmt_handle) return -1;

    *db_handle = 0;
    *stmt_handle = 0;

    sqlite3* db = nullptr;
    sqlite3_stmt* stmt = nullptr;

    //remove the file if it exists
    if(std::filesystem::exists(filename)) std::remove(filename);

    //create a db
    int rc = sqlite3_open(filename, &db);
    //if it encounters a problem return
    if (check_rc(rc)) {
        if (db) sqlite3_close(db);
        return -1;
    }

    //statement to create the table
    const char* create_sql =
        "CREATE TABLE IF NOT EXISTS trace ("
        "  id       INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  cycle    INTEGER NOT NULL,"
        "  time     INTEGER NOT NULL,"
        "  pc_gen   BLOB NOT NULL"
        ");";

    //create a table
    rc = sqlite3_exec(db, create_sql, nullptr, nullptr, nullptr);
    //on error exit
    if (check_rc(rc)) {
        sqlite3_close(db);
        return -1;
    }

    //create an insert statement for later use and on error exit
    const char* insert_sql =
        "INSERT INTO trace(cycle, time, pc_gen) VALUES(?, ?, ?);";

    rc = sqlite3_prepare_v2(db, insert_sql, -1, &stmt, nullptr);
    if (check_rc(rc)) {
        sqlite3_close(db);
        return -1;
    }

    //acquire a write lock on the database so that noone else can write anything to it
    //in case it fails exit
    rc = sqlite3_exec(db, "BEGIN IMMEDIATE;", nullptr, nullptr, nullptr);
    if (check_rc(rc)) {
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        return -1;
    }

    //convert the pointers to uint64 and store them for system verilog to use
    *db_handle   = reinterpret_cast<uint64_t>(db);
    *stmt_handle = reinterpret_cast<uint64_t>(stmt);
    return 0;
}

// --------------------------------------------------
// dpi_insert_state
//   - reuses prepared INSERT statement
//   - binds the values to store
//   - step, then reset and clear_bindings for future use
// Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_insert_state(uint64_t db_handle,
                     uint64_t stmt_handle,
                     uint64_t traceC_handle)
{
    //if the handles don't exist return  
    if (db_handle == 0 || stmt_handle == 0) return -1;

    //if the handle for trace doesn't exist
    if (!traceC_handle) return -1;
    TraceCycle* traceC = reinterpret_cast<TraceCycle*>(traceC_handle);

    //convert them to the pointers
    sqlite3* db = reinterpret_cast<sqlite3*>(db_handle);
    sqlite3_stmt* stmt = reinterpret_cast<sqlite3_stmt*>(stmt_handle);

    int rc;

    // Bind parameter 1: cycle
    rc = sqlite3_bind_int(stmt, 1, traceC->cycle);
    if (check_rc(rc)) return -1;

    //%TODO for later tests
    
    
    // Bind parameter 2: time
    rc = sqlite3_bind_int(stmt, 2, traceC->time);
    if (check_rc(rc)) return -1;

    // Bind parameter 2: blob bytes
    // SQLITE_TRANSIENT necessaary for the DB to make the copy of the data immediatly
    rc = sqlite3_bind_blob(stmt, 3, traceC->pc_gen, PC_GEN_SIZE, SQLITE_TRANSIENT);
    if (check_rc(rc)) return -1;

    // Execute insert
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE) {
        check_rc(rc);
        return -1;
    }

    // Prepare for reuse
    rc = sqlite3_reset(stmt);
    if (check_rc(rc)) return -1;

    rc = sqlite3_clear_bindings(stmt);
    if (check_rc(rc)) return -1;

    return 0;
}

// --------------------------------------------------
// dpi_close_database
//   - commits transaction
//   - finalizes statement
//   - closes DB
// Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_close_database(uint64_t db_handle,
                       uint64_t stmt_handle)
{
    if (db_handle == 0) return -1;

    sqlite3* db = reinterpret_cast<sqlite3*>(db_handle);
    sqlite3_stmt* stmt = reinterpret_cast<sqlite3_stmt*>(stmt_handle);

    sqlite3_exec(db, "COMMIT;", nullptr, nullptr, nullptr);
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);

    return 0;
}

// --------------------------------------------------
// dpi_create_struct
//   - allocate memory for the struct
//   - store the pointer into the handle
// Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_create_struct(uint64_t* traceC_handle){
    
    TraceCycle* traceC = new TraceCycle();
    //allocate space for the pc generator
    traceC->pc_gen = new uint8_t[PC_GEN_SIZE];
    //store the pointer in traceC_handle
    *traceC_handle = reinterpret_cast<uint64_t>(traceC);
    return 0;
}

// --------------------------------------------------
// dpi_delete_struct
//   - frees the allocated memory
//   - deletes struct and its fields
// Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_delete_struct(uint64_t traceC_handle){
    
    if (!traceC_handle) return -1;
    TraceCycle* traceC = reinterpret_cast<TraceCycle*>(traceC_handle);
    delete[] traceC->pc_gen;
    delete traceC;
    return 0;
}

// --------------------------------------------------
// dpi_update_trace_cycle
//   - update cycle field in traceC_handle
//   - update time  field in traceC_handle
// Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_update_trace_cycle(uint64_t traceC_handle, uint64_t cycle, uint64_t cur_time){
    
    if (!traceC_handle) return -1;
    TraceCycle* traceC = reinterpret_cast<TraceCycle*>(traceC_handle);
    traceC->cycle = cycle;
    traceC->time = cur_time;
    return 0;
}

// --------------------------------------------------
// dpi_update_trace_pc
//   - update pc_gen field in traceC_handle
// Returns 0 on success, -1 on failure.
// --------------------------------------------------
int dpi_update_trace_pc(uint64_t traceC_handle, svBitVecVal* pc_gen){
    if (!traceC_handle) return -1;
    TraceCycle* traceC = reinterpret_cast<TraceCycle*>(traceC_handle);

    //copy nine bytes
    std::memcpy(traceC->pc_gen, pc_gen, PC_GEN_SIZE);
    return 0;
}

} // extern "C"