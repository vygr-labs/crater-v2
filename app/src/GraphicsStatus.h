// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

#pragma once

#include <QObject>
#include <QString>

namespace crater {

// What the console draws with, for Settings > Diagnostics and the one-time
// notice after a GPU driver crash moved this PC to OpenGL (issue #155).
//
// A thin view over the startup guard (StartupGuard.h), which made the choice
// before Qt started. The choice holds for this whole launch: a reset only
// forgets what is stored, and the next launch starts on the default.
class GraphicsStatus : public QObject
{
    Q_OBJECT
    // "direct3d" (the default on Windows, the graphics card elsewhere),
    // "opengl", "warp" or "software". What this launch uses.
    Q_PROPERTY(QString mode         READ mode         CONSTANT)
    // Set through QSG_RHI_BACKEND or QT_QUICK_BACKEND. Crater leaves it be.
    Q_PROPERTY(bool    chosenByHand READ chosenByHand CONSTANT)
    // Where the driver crash that chose OpenGL was, "igd10iumd64.dll+0x228d55".
    Q_PROPERTY(QString driverCrash  READ driverCrash  CONSTANT)
    // Reset to the default this session; applies on the next launch.
    Q_PROPERTY(bool    resetPending READ resetPending NOTIFY changed)
    // This launch switched to OpenGL and the operator hasn't closed the
    // notice yet.
    Q_PROPERTY(bool    noticeVisible READ noticeVisible NOTIFY changed)

public:
    explicit GraphicsStatus(QObject* parent = nullptr);

    QString mode() const;
    bool    chosenByHand() const;
    QString driverCrash() const;
    bool    resetPending() const { return m_resetPending; }
    bool    noticeVisible() const { return m_noticeVisible; }

    Q_INVOKABLE void resetToDefault();
    Q_INVOKABLE void dismissNotice();

signals:
    void changed();

private:
    bool m_resetPending = false;
    bool m_noticeVisible = false;
};

}  // namespace crater
