#include "StartupSplash.h"

#include <QApplication>
#include <QGuiApplication>
#include <QPainter>
#include <QPainterPath>
#include <QScreen>

#include <cmath>

namespace crater {

namespace {
// The console's dark surface and text tiers (Theme.qml, dark), and the
// brand cyan of the mark.
const QColor kSurface(0x18, 0x18, 0x1b);
const QColor kBorder(0x27, 0x27, 0x2a);
const QColor kText(0xe4, 0xe4, 0xe7);
const QColor kTextSecondary(0xa1, 0xa1, 0xaa);
const QColor kTextTertiary(0x71, 0x71, 0x7a);
const QColor kTrack(0x27, 0x27, 0x2a);
const QColor kBrand(0x3a, 0xc8, 0xd4);
}  // namespace

StartupSplash::StartupSplash()
    : QWidget(nullptr, Qt::SplashScreen | Qt::FramelessWindowHint)
{
    // Closing the splash (Alt+F4) must not count as the last window closing,
    // or the app would quit before its main window exists.
    setAttribute(Qt::WA_QuitOnClose, false);
    setAttribute(Qt::WA_TranslucentBackground);
    setWindowTitle(QStringLiteral("Crater"));
    resize(460, 220);
    if (QScreen* screen = QGuiApplication::primaryScreen())
        move(screen->availableGeometry().center() - rect().center());
    m_line = tr("Getting things ready");
    m_tick.setInterval(33);
    connect(&m_tick, &QTimer::timeout, this, qOverload<>(&QWidget::update));
    m_clock.start();
}

void StartupSplash::setProgress(int percent, const QString& stage)
{
    Q_UNUSED(stage);
    m_percent = qBound(0, percent, 100);
    m_line = m_percent < 88 ? tr("Preparing your Bibles") : tr("Building the search index");
    if (m_percent >= 88 && m_percent < 100) m_tick.start(); else m_tick.stop();
    update();
}

void StartupSplash::setOpening()
{
    m_percent = 100;
    m_tick.stop();
    m_line = tr("Opening Crater");
    update();
}

void StartupSplash::paintEvent(QPaintEvent*)
{
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);

    const QRectF card = QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5);
    QPainterPath shape;
    // Near-square, like the rest of the UI.
    shape.addRoundedRect(card, 2, 2);
    p.fillPath(shape, kSurface);
    p.setPen(QPen(kBorder, 1));
    p.drawPath(shape);

    const int pad = 32;
    const QPixmap mark = QApplication::windowIcon().pixmap(48, 48);
    p.drawPixmap(pad, pad, mark);

    QFont title = font();
    title.setPixelSize(20);
    title.setWeight(QFont::DemiBold);
    p.setFont(title);
    p.setPen(kText);
    const int textX = pad + 48 + 16;
    p.drawText(QRect(textX, pad - 2, width() - textX - pad, 28), Qt::AlignLeft | Qt::AlignVCenter,
               tr("Setting up Crater"));

    QFont body = font();
    body.setPixelSize(13);
    p.setFont(body);
    p.setPen(kTextSecondary);
    p.drawText(QRect(textX, pad + 26, width() - textX - pad, 22), Qt::AlignLeft | Qt::AlignVCenter,
               tr("This only happens the first time Crater opens."));

    // Progress
    const QRectF track(pad, height() - pad - 34, width() - 2 * pad, 6);
    QPainterPath trackPath;
    trackPath.addRect(track);
    p.fillPath(trackPath, kTrack);
    if (m_percent > 0) {
        QRectF fill = track;
        fill.setWidth(track.width() * m_percent / 100.0);
        QPainterPath fillPath;
        fillPath.addRect(fill);
        p.fillPath(fillPath, kBrand);
    }
    if (m_tick.isActive()) {
        // a soft highlight travelling along the bar, about once every 1.6s
        const double phase = std::fmod(m_clock.elapsed() / 1600.0, 1.0);
        const double w = track.width() * 0.25;
        const double x = track.left() - w + (track.width() + w) * phase;
        QLinearGradient sweep(x, 0, x + w, 0);
        QColor clear = kBrand.lighter(160); clear.setAlpha(0);
        QColor glow = kBrand.lighter(160); glow.setAlpha(170);
        sweep.setColorAt(0.0, clear); sweep.setColorAt(0.5, glow); sweep.setColorAt(1.0, clear);
        p.save();
        p.setClipPath(trackPath);
        p.fillRect(QRectF(x, track.top(), w, track.height()), sweep);
        p.restore();
    }

    p.setFont(body);
    p.setPen(kTextTertiary);
    const QRect status(pad, height() - pad - 22, width() - 2 * pad, 22);
    p.drawText(status, Qt::AlignLeft | Qt::AlignVCenter, m_line);
    p.drawText(status, Qt::AlignRight | Qt::AlignVCenter, QStringLiteral("%1%").arg(m_percent));
}

}  // namespace crater
