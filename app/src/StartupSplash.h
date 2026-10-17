#pragma once

#include <QElapsedTimer>
#include <QString>
#include <QTimer>
#include <QWidget>

namespace crater {

// Shown from the start of every launch until the console paints its first
// frame. Without it the taskbar button appeared seconds before the window,
// and on a slow PC the operator saw nothing and clicked the shortcut again.
// On a first launch it also shows the one-time Bible import, which can take
// half a minute on a modest PC.
//
// A plain QWidget rather than QML: it has to appear before the QML engine,
// the services and the fonts it depends on are up. It draws the app icon set
// by main(), so it follows the brand mark without its own asset.
class StartupSplash : public QWidget
{
    Q_OBJECT

public:
    StartupSplash();

public slots:
    // Switches to the first-launch look: a progress bar for the import.
    void setFirstRun();
    // Wired to ElectronDataImporter::progress. The importer's stage strings
    // are developer-facing, so the splash shows its own wording per phase.
    void setProgress(int percent, const QString& stage);
    // After the import, while services are built and the window loads.
    void setOpening();

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    void centerOnScreen();

    bool    m_firstRun = false;
    int     m_percent = 0;
    QString m_line;
    // The search-index phase reports no progress of its own and can be the
    // longest stretch, so the bar keeps a soft sweep moving to show it's alive.
    QTimer        m_tick;
    QElapsedTimer m_clock;
};

}  // namespace crater
