#pragma once

#include <QElapsedTimer>
#include <QString>
#include <QTimer>
#include <QWidget>

namespace crater {

// Shown while Crater prepares itself on a first launch (the one-time Bible
// import), which can take half a minute on a modest PC. Before it existed the
// operator double-clicked the shortcut and saw nothing at all, and the natural
// reaction is to click again.
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
    // Wired to ElectronDataImporter::progress. The importer's stage strings
    // are developer-facing, so the splash shows its own wording per phase.
    void setProgress(int percent, const QString& stage);
    // After the import, while services are built and the window loads.
    void setOpening();

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    int     m_percent = 0;
    QString m_line;
    // The search-index phase reports no progress of its own and can be the
    // longest stretch, so the bar keeps a soft sweep moving to show it's alive.
    QTimer        m_tick;
    QElapsedTimer m_clock;
};

}  // namespace crater
