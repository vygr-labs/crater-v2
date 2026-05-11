#pragma once

namespace crater {

// Runs all DB migrations for bibles.sqlite, songs.sqlite, app.sqlite. Creates
// any missing DB files via Connection's ReadWriteCreate mode. Idempotent —
// safe to call on every app start.
//
// Throws crater::db::Error on failure (caller should log + abort).
//
// This is the public entry point for main.cpp so it doesn't need to include
// the private db/ headers.
void runAllMigrations();

}  // namespace crater
