// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

#pragma once

// Aggregate header — pull in the full db layer with one include.
//
// Services that touch storage should:
//   #include "db/Db.h"
//   using namespace crater::db;

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Migrator.h"
#include "db/Statement.h"
#include "db/Transaction.h"
