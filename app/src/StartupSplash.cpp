#include "StartupSplash.h"

#include <QApplication>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QPainter>
#include <QPainterPath>
#include <QPropertyAnimation>
#include <QScreen>

#include <cmath>

namespace crater {

namespace {
// The console's dark surface and text tiers (Theme.qml, dark), and the
// brand cyan of the mark.
const QColor kSurfaceTop(0x1f, 0x1f, 0x23);
const QColor kSurface(0x16, 0x16, 0x19);
const QColor kBorder(0x27, 0x27, 0x2a);
const QColor kText(0xe4, 0xe4, 0xe7);
const QColor kTextSecondary(0xa1, 0xa1, 0xaa);
const QColor kTextTertiary(0x71, 0x71, 0x7a);
const QColor kTrack(0x27, 0x27, 0x2a);
const QColor kBrand(0x3a, 0xc8, 0xd4);
}  // namespace

// The card sits inside a transparent margin that holds its shadow.
constexpr int kShadow = 28;
constexpr int kCardW  = 400;
constexpr int kOpeningH  = 260;
constexpr int kFirstRunH = 320;

StartupSplash::StartupSplash()
    // On top, so the console's window can't cover it while it is shown but
    // not yet drawn.
    : QWidget(nullptr, Qt::SplashScreen | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint)
{
    // Closing the splash (Alt+F4) must not count as the last window closing,
    // or the app would quit before its main window exists.
    setAttribute(Qt::WA_QuitOnClose, false);
    setAttribute(Qt::WA_TranslucentBackground);
    setWindowTitle(QStringLiteral("Crater"));
    resize(kCardW + 2 * kShadow, kOpeningH + 2 * kShadow);
    centerOnScreen();
    m_tick.setInterval(33);
    connect(&m_tick, &QTimer::timeout, this, qOverload<>(&QWidget::update));
    m_clock.start();
}

void StartupSplash::centerOnScreen()
{
    if (QScreen* screen = QGuiApplication::primaryScreen())
        move(screen->availableGeometry().center() - rect().center());
}

void StartupSplash::setFirstRun()
{
    m_firstRun = true;
    m_line = tr("Getting things ready");
    resize(kCardW + 2 * kShadow, kFirstRunH + 2 * kShadow);
    centerOnScreen();
    update();
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

void StartupSplash::fadeOut()
{
    if (!isVisible() || m_fading) return;
    m_fading = true;
    m_tick.stop();
    auto* fade = new QPropertyAnimation(this, "windowOpacity", this);
    fade->setDuration(150);
    fade->setStartValue(1.0);
    fade->setEndValue(0.0);
    fade->setEasingCurve(QEasingCurve::OutCubic);
    connect(fade, &QPropertyAnimation::finished, this, &QWidget::close);
    fade->start(QAbstractAnimation::DeleteWhenStopped);
}

void StartupSplash::paintEvent(QPaintEvent*)
{
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);
    p.setRenderHint(QPainter::SmoothPixmapTransform);

    const QRectF card = QRectF(rect()).adjusted(kShadow, kShadow, -kShadow, -kShadow);
    constexpr qreal radius = 6;

    // Soft shadow: rings fading out from the card, a little heavier below.
    for (int i = kShadow; i >= 1; i -= 2) {
        QPainterPath ring;
        ring.addRoundedRect(card.adjusted(-i, -i * 0.6, i, i * 1.1), radius + i, radius + i);
        p.fillPath(ring, QColor(0, 0, 0, int(1 + (kShadow - i) * 0.22)));
    }

    QPainterPath shape;
    shape.addRoundedRect(card, radius, radius);
    QLinearGradient bg(card.topLeft(), card.bottomLeft());
    bg.setColorAt(0.0, kSurfaceTop);
    bg.setColorAt(1.0, kSurface);
    p.fillPath(shape, bg);

    // A faint brand glow behind the mark.
    const QPointF markCenter(card.center().x(), card.top() + 84);
    p.save();
    p.setClipPath(shape);
    QRadialGradient glow(markCenter, 150);
    QColor g = kBrand; g.setAlpha(34);
    QColor clear = kBrand; clear.setAlpha(0);
    glow.setColorAt(0.0, g);
    glow.setColorAt(1.0, clear);
    p.fillRect(card, glow);
    p.restore();

    p.setPen(QPen(kBorder, 1));
    p.drawPath(shape);

    // The mark, drawn from the app icon main() set.
    constexpr int markSize = 76;
    const QPixmap mark = QApplication::windowIcon().pixmap(QSize(markSize, markSize), devicePixelRatioF());
    p.drawPixmap(QRectF(markCenter.x() - markSize / 2.0, markCenter.y() - markSize / 2.0,
                        markSize, markSize), mark, QRectF(mark.rect()));

    QFont title = font();
    title.setPixelSize(26);
    title.setWeight(QFont::DemiBold);
    p.setFont(title);
    p.setPen(kText);
    const qreal titleTop = markCenter.y() + markSize / 2.0 + 18;
    p.drawText(QRectF(card.left(), titleTop, card.width(), 34), Qt::AlignHCenter | Qt::AlignVCenter,
               QStringLiteral("Crater"));

    QFont body = font();
    body.setPixelSize(13);
    p.setFont(body);
    p.setPen(kTextSecondary);
    p.drawText(QRectF(card.left() + 24, titleTop + 36, card.width() - 48, 20),
               Qt::AlignHCenter | Qt::AlignVCenter,
               m_firstRun ? tr("Setting up. This only happens the first time.") : tr("Opening"));

    QFont small = font();
    small.setPixelSize(11);
    p.setFont(small);
    p.setPen(kTextTertiary);
    const QString version = tr("Version %1").arg(QCoreApplication::applicationVersion());

    // An everyday launch has no progress to show. The main thread is busy
    // building the console the whole time, so a moving bar would only freeze.
    if (!m_firstRun) {
        p.drawText(QRectF(card.left(), card.bottom() - 34, card.width(), 18),
                   Qt::AlignHCenter | Qt::AlignVCenter, version);
        return;
    }

    constexpr int pad = 32;
    const QRectF track(card.left() + pad, card.bottom() - 62, card.width() - 2 * pad, 4);
    QPainterPath trackPath;
    trackPath.addRoundedRect(track, 2, 2);
    p.fillPath(trackPath, kTrack);
    if (m_percent > 0) {
        QRectF fill = track;
        fill.setWidth(track.width() * m_percent / 100.0);
        QPainterPath fillPath;
        fillPath.addRoundedRect(fill, 2, 2);
        p.fillPath(fillPath, kBrand);
    }
    if (m_tick.isActive()) {
        // a soft highlight travelling along the bar, about once every 1.6s
        const double phase = std::fmod(m_clock.elapsed() / 1600.0, 1.0);
        const double w = track.width() * 0.25;
        const double x = track.left() - w + (track.width() + w) * phase;
        QLinearGradient sweep(x, 0, x + w, 0);
        QColor c0 = kBrand.lighter(160); c0.setAlpha(0);
        QColor c1 = kBrand.lighter(160); c1.setAlpha(170);
        sweep.setColorAt(0.0, c0); sweep.setColorAt(0.5, c1); sweep.setColorAt(1.0, c0);
        p.save();
        p.setClipPath(trackPath);
        p.fillRect(QRectF(x, track.top(), w, track.height()), sweep);
        p.restore();
    }

    p.setFont(body);
    p.setPen(kTextTertiary);
    const QRectF status(track.left(), track.bottom() + 10, track.width(), 20);
    p.drawText(status, Qt::AlignLeft | Qt::AlignVCenter, m_line);
    p.drawText(status, Qt::AlignRight | Qt::AlignVCenter, QStringLiteral("%1%").arg(m_percent));
}

}  // namespace crater
