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
constexpr int kCardW  = 560;
constexpr int kCardH  = 320;

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
    resize(kCardW + 2 * kShadow, kCardH + 2 * kShadow);
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
    constexpr qreal radius = 8;

    // Soft shadow: rings fading out from the card, a little heavier below.
    for (int i = kShadow; i >= 1; i -= 2) {
        QPainterPath ring;
        ring.addRoundedRect(card.adjusted(-i, -i * 0.6, i, i * 1.1), radius + i, radius + i);
        p.fillPath(ring, QColor(0, 0, 0, int(1 + (kShadow - i) * 0.22)));
    }

    QPainterPath shape;
    shape.addRoundedRect(card, radius, radius);
    p.fillPath(shape, kSurface);

    // The mark's cyan disc, large, rising from the card's bottom edge with
    // rings around it. Clipped to the card like artwork that runs off the page.
    p.save();
    p.setClipPath(shape);
    const QPointF sun(card.right() - 100, card.bottom() + 36);
    constexpr qreal sunR = 118;
    p.setPen(Qt::NoPen);
    p.setBrush(kBrand);
    p.drawEllipse(sun, sunR, sunR);
    p.setBrush(Qt::NoBrush);
    for (int k = 1; k <= 5; ++k) {
        QColor c = kBrand;
        c.setAlpha(120 - k * 18);
        p.setPen(QPen(c, 1.5));
        const qreal r = sunR + 14 + k * 24;
        p.drawEllipse(sun, r, r);
    }
    p.restore();

    p.setPen(QPen(kBorder, 1));
    p.setBrush(Qt::NoBrush);
    p.drawPath(shape);

    constexpr int pad = 36;
    const qreal left = card.left() + pad;

    // The mark, drawn from the app icon main() set.
    constexpr int markSize = 40;
    const QPixmap mark = QApplication::windowIcon().pixmap(QSize(markSize, markSize), devicePixelRatioF());
    p.drawPixmap(QRectF(left, card.top() + pad, markSize, markSize), mark, QRectF(mark.rect()));

    QFont title = font();
    title.setPixelSize(40);
    title.setWeight(QFont::DemiBold);
    p.setFont(title);
    p.setPen(kText);
    const qreal titleTop = card.top() + 128;
    p.drawText(QRectF(left, titleTop, 300, 48), Qt::AlignLeft | Qt::AlignVCenter, QStringLiteral("Crater"));

    QFont body = font();
    body.setPixelSize(13);
    QFont small = font();
    small.setPixelSize(12);

    p.setFont(small);
    p.setPen(kTextTertiary);
    p.drawText(QRectF(left, titleTop + 50, 300, 18), Qt::AlignLeft | Qt::AlignVCenter,
               tr("Version %1").arg(QCoreApplication::applicationVersion()));

    // An everyday launch has no progress to show. The main thread is busy
    // building the console the whole time, so a moving bar would only freeze.
    if (!m_firstRun) {
        p.setFont(body);
        p.setPen(kTextSecondary);
        p.drawText(QRectF(left, card.bottom() - pad - 18, 260, 18),
                   Qt::AlignLeft | Qt::AlignVCenter, tr("Opening"));
        return;
    }

    p.setFont(small);
    p.setPen(kTextTertiary);
    p.drawText(QRectF(left, titleTop + 70, 300, 18), Qt::AlignLeft | Qt::AlignVCenter,
               tr("Setting up. This only happens once."));

    const QRectF track(left, card.bottom() - pad - 3, 170, 3);
    p.setFont(body);
    p.setPen(kTextSecondary);
    const QRectF status(track.left(), track.top() - 28, track.width(), 18);
    p.drawText(status, Qt::AlignLeft | Qt::AlignVCenter, m_line);
    p.setPen(kTextTertiary);
    p.drawText(status, Qt::AlignRight | Qt::AlignVCenter, QStringLiteral("%1%").arg(m_percent));

    QPainterPath trackPath;
    trackPath.addRoundedRect(track, 1.5, 1.5);
    p.fillPath(trackPath, kTrack);
    if (m_percent > 0) {
        QRectF fill = track;
        fill.setWidth(track.width() * m_percent / 100.0);
        QPainterPath fillPath;
        fillPath.addRoundedRect(fill, 1.5, 1.5);
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
}

}  // namespace crater
