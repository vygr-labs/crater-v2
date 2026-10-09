#include "narration/DeepgramRecognizer.h"

#include <QEventLoop>
#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkRequest>
#include <QSignalBlocker>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QWebSocket>

#include <algorithm>
#include <cmath>

namespace crater::narration {

namespace {

// Deepgram's English model. Pinned rather than "latest" so a model change on
// their side is a change we make, not one that arrives on a Sunday.
constexpr const char* kModel = "nova-3";

// Silence that ends an utterance. 300 ms is short enough to feel immediate
// and long enough not to split "John three... sixteen" on a breath.
constexpr int kEndpointingMs = 300;

// Backstop when speech_final never arrives, for example under steady room
// noise that keeps the endpointer from seeing silence. Deepgram sends an
// UtteranceEnd after this long without a new word.
constexpr int kUtteranceEndMs = 1000;

// Each connection attempt waits this long before it counts as failed.
constexpr int kConnectTimeoutMs = 8000;

// Deepgram closes a stream after about ten seconds with no data. A KeepAlive
// goes up once the socket has been quiet this long, checked this often.
constexpr int kKeepAliveAfterMs = 5000;
constexpr int kKeepAliveCheckMs = 1000;

// Mid-service drops are retried rather than reported, because a church Wi-Fi
// blip is not a reason for the microphone to stop working. Only this many
// failures in a row turn into an error.
constexpr int kMaxReconnects = 5;

constexpr int kRate = 16000;

QStringList bookNames()
{
    return {
        QStringLiteral("Genesis"), QStringLiteral("Exodus"), QStringLiteral("Leviticus"),
        QStringLiteral("Numbers"), QStringLiteral("Deuteronomy"), QStringLiteral("Joshua"),
        QStringLiteral("Judges"), QStringLiteral("Ruth"), QStringLiteral("Samuel"),
        QStringLiteral("Kings"), QStringLiteral("Chronicles"), QStringLiteral("Ezra"),
        QStringLiteral("Nehemiah"), QStringLiteral("Esther"), QStringLiteral("Job"),
        QStringLiteral("Psalm"), QStringLiteral("Psalms"), QStringLiteral("Proverbs"), QStringLiteral("Ecclesiastes"),
        QStringLiteral("Song of Solomon"), QStringLiteral("Isaiah"), QStringLiteral("Jeremiah"),
        QStringLiteral("Lamentations"), QStringLiteral("Ezekiel"), QStringLiteral("Daniel"),
        QStringLiteral("Hosea"), QStringLiteral("Joel"), QStringLiteral("Amos"),
        QStringLiteral("Obadiah"), QStringLiteral("Jonah"), QStringLiteral("Micah"),
        QStringLiteral("Nahum"), QStringLiteral("Habakkuk"), QStringLiteral("Zephaniah"),
        QStringLiteral("Haggai"), QStringLiteral("Zechariah"), QStringLiteral("Malachi"),
        QStringLiteral("Matthew"), QStringLiteral("Mark"), QStringLiteral("Luke"),
        QStringLiteral("John"), QStringLiteral("Acts"), QStringLiteral("Romans"),
        QStringLiteral("Corinthians"), QStringLiteral("Galatians"), QStringLiteral("Ephesians"),
        QStringLiteral("Philippians"), QStringLiteral("Colossians"),
        QStringLiteral("Thessalonians"), QStringLiteral("Timothy"), QStringLiteral("Titus"),
        QStringLiteral("Philemon"), QStringLiteral("Hebrews"), QStringLiteral("James"),
        QStringLiteral("Peter"), QStringLiteral("Jude"), QStringLiteral("Revelation"),
    };
}

// 16-bit little-endian PCM, which is what the socket is told to expect. Half
// the bandwidth of float32, and the microphone never had more than 16 bits of
// real resolution anyway.
QByteArray toLinear16(const QList<float>& samples)
{
    QByteArray out;
    out.resize(samples.size() * 2);
    auto* dst = reinterpret_cast<qint16*>(out.data());
    for (qsizetype i = 0; i < samples.size(); ++i) {
        const float v = std::clamp(samples[i], -1.0f, 1.0f);
        dst[i] = qint16(std::lround(v * 32767.0f));
    }
    return out;
}

}  // namespace

DeepgramRecognizer::DeepgramRecognizer(QObject* parent)
    : SpeechRecognizer(parent)
    , m_keyterms(bookNames())
{
}

DeepgramRecognizer::~DeepgramRecognizer()
{
    unload();
}

QString DeepgramRecognizer::engineName() const
{
    return QStringLiteral("Deepgram %1 (cloud)").arg(QString::fromLatin1(kModel));
}

bool DeepgramRecognizer::load(const QString& apiKey, QString* error)
{
    unload();

    m_key = apiKey.trimmed();
    if (m_key.isEmpty()) {
        if (error) *error = QStringLiteral("No Deepgram API key. Add one in Settings > Narration.");
        return false;
    }

    m_ws             = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    m_reconnect      = new QTimer(this);
    m_connectTimeout = new QTimer(this);
    m_keepAlive      = new QTimer(this);
    m_reconnect->setSingleShot(true);
    m_connectTimeout->setSingleShot(true);
    m_keepAlive->setInterval(kKeepAliveCheckMs);

    connect(m_ws, &QWebSocket::connected, this, &DeepgramRecognizer::onConnected);
    connect(m_ws, &QWebSocket::disconnected, this, &DeepgramRecognizer::onDisconnected);
    connect(m_ws, &QWebSocket::errorOccurred, this, &DeepgramRecognizer::onSocketError);
    connect(m_ws, &QWebSocket::textMessageReceived, this, &DeepgramRecognizer::handleMessage);
    connect(m_reconnect, &QTimer::timeout, this, &DeepgramRecognizer::startAttempt);
    connect(m_connectTimeout, &QTimer::timeout, this, [this]() {
        m_lastError = QStringLiteral("timed out");
        attemptFailed();
    });
    connect(m_keepAlive, &QTimer::timeout, this, &DeepgramRecognizer::sendKeepAlive);

    m_wantOpen  = true;
    m_failures  = 0;
    m_cancelled = false;
    startAttempt();

    // The one blocking wait, so arm() can report a bad key or a dead network
    // before the microphone opens. Every exit from it goes through a member
    // the handlers can reach: onConnected and attemptFailed quit the loop,
    // and so does unload() if the operator presses Stop meanwhile.
    QEventLoop loop;
    m_waitLoop = &loop;
    if (m_connecting) loop.exec();
    m_waitLoop = nullptr;

    if (m_cancelled) {
        unload();
        if (error) *error = QStringLiteral("Cancelled.");
        return false;
    }
    if (!isLoaded()) {
        if (error) *error = describeFailure();
        unload();
        return false;
    }
    return true;
}

void DeepgramRecognizer::startAttempt()
{
    if (!m_ws || !m_wantOpen) return;

    QUrlQuery q;
    q.addQueryItem(QStringLiteral("model"), QString::fromLatin1(kModel));
    q.addQueryItem(QStringLiteral("language"), QStringLiteral("en"));
    q.addQueryItem(QStringLiteral("encoding"), QStringLiteral("linear16"));
    q.addQueryItem(QStringLiteral("sample_rate"), QString::number(kRate));
    q.addQueryItem(QStringLiteral("channels"), QStringLiteral("1"));
    q.addQueryItem(QStringLiteral("interim_results"), QStringLiteral("true"));
    // Writes "John chapter three verse sixteen" as "John chapter 3 verse 16".
    // The detectors read both, but digits are the shape they were tuned on.
    q.addQueryItem(QStringLiteral("smart_format"), QStringLiteral("true"));
    q.addQueryItem(QStringLiteral("endpointing"), QString::number(kEndpointingMs));
    q.addQueryItem(QStringLiteral("utterance_end_ms"), QString::number(kUtteranceEndMs));
    // Keeps the congregation's audio out of Deepgram's model-improvement
    // programme. The settings page tells the operator nothing is kept, and
    // without this that would be a promise about someone else's servers we
    // had not asked them to keep.
    q.addQueryItem(QStringLiteral("mip_opt_out"), QStringLiteral("true"));
    for (const QString& t : std::as_const(m_keyterms))
        q.addQueryItem(QStringLiteral("keyterm"), t);

    QUrl url(QStringLiteral("wss://api.deepgram.com/v1/listen"));
    url.setQuery(q);

    QNetworkRequest req(url);
    req.setRawHeader("Authorization", "Token " + m_key.toUtf8());

    m_originMs   = -1;
    m_connecting = true;
    m_lastError.clear();
    m_ws->open(req);
    m_connectTimeout->start(kConnectTimeoutMs);
}

void DeepgramRecognizer::onConnected()
{
    if (!m_connecting) return;
    m_connecting = false;
    m_connectTimeout->stop();
    m_sinceSend.start();
    m_keepAlive->start();

    const bool reconnected = m_failures > 0;
    m_failures = 0;
    if (m_waitLoop) m_waitLoop->quit();
    if (reconnected) emit connectionChanged(true, QString());
}

void DeepgramRecognizer::onSocketError()
{
    if (m_ws) m_lastError = m_ws->errorString();
    if (m_connecting) attemptFailed();
}

void DeepgramRecognizer::onDisconnected()
{
    // A failed handshake can arrive as a disconnect with no error first.
    if (m_connecting) {
        attemptFailed();
        return;
    }

    // Whatever was finalized before the drop is still real speech.
    emitUtterance();
    if (m_keepAlive) m_keepAlive->stop();
    if (!m_wantOpen) return;

    emit connectionChanged(false, QStringLiteral("Lost the connection to Deepgram. Reconnecting..."));
    scheduleRetry();
}

// One attempt is over and did not connect. Runs once per attempt however many
// of error, disconnect and timeout report it, because m_connecting is cleared
// on the first.
void DeepgramRecognizer::attemptFailed()
{
    if (!m_connecting) return;
    m_connecting = false;
    if (m_connectTimeout) m_connectTimeout->stop();
    if (m_ws) {
        // Its disconnected() would come back here as a second failure.
        const QSignalBlocker block(m_ws);
        m_ws->abort();
    }

    // The first connection reports to load(), which reports to arm().
    if (m_waitLoop) {
        m_waitLoop->quit();
        return;
    }
    if (!m_wantOpen) return;

    // A rejected key will be rejected again. Retrying only delays the one
    // message that tells the operator what to fix.
    if (m_lastError.contains(QLatin1String("401"))) {
        m_wantOpen = false;
        emit lost(describeFailure());
        return;
    }
    scheduleRetry();
}

void DeepgramRecognizer::scheduleRetry()
{
    if (++m_failures > kMaxReconnects) {
        m_wantOpen = false;
        emit lost(QStringLiteral("Lost the connection to Deepgram and could not reconnect. "
                                 "Check the internet connection, then press Listen again."));
        return;
    }
    // 1, 2, 4, 8, 16 s. Quick enough that a blip costs a sentence, slow
    // enough not to hammer a network that is actually down.
    m_reconnect->start(1000 << (m_failures - 1));
}

QString DeepgramRecognizer::describeFailure() const
{
    // A rejected key comes back as a failed handshake with the HTTP status
    // somewhere in the message, which is not something an operator should
    // have to decode.
    if (m_lastError.contains(QLatin1String("401")))
        return QStringLiteral("Deepgram rejected the API key. Check it in Settings > Narration.");
    return QStringLiteral("Could not reach Deepgram (%1). Check the internet connection.")
        .arg(m_lastError.isEmpty() ? QStringLiteral("no response") : m_lastError);
}

bool DeepgramRecognizer::isLoaded() const
{
    return m_ws && m_ws->state() == QAbstractSocket::ConnectedState;
}

void DeepgramRecognizer::unload()
{
    if (m_waitLoop) {
        // load() is still waiting for the first connection, further up this
        // thread's stack. Deleting the socket here would delete it under that
        // frame; ending the wait lets load() clean up on its own way out.
        m_cancelled = true;
        m_wantOpen  = false;
        m_waitLoop->quit();
        return;
    }

    m_wantOpen   = false;
    m_connecting = false;
    for (QTimer* t : { m_reconnect, m_connectTimeout, m_keepAlive }) {
        if (!t) continue;
        t->stop();
        t->deleteLater();
    }
    m_reconnect = m_connectTimeout = m_keepAlive = nullptr;

    if (m_ws) {
        if (m_ws->state() == QAbstractSocket::ConnectedState) {
            // Asks Deepgram to flush and close. Without it the server waits
            // out its own idle timeout and bills for the wait.
            m_ws->sendTextMessage(QStringLiteral("{\"type\":\"CloseStream\"}"));
            m_ws->flush();
        }
        m_ws->disconnect(this);
        m_ws->close();
        m_ws->deleteLater();
        m_ws = nullptr;
    }
    m_finals.clear();
    m_uttStartSec = -1.0;
}

void DeepgramRecognizer::transcribe(QList<float> mono16k, qint64 startedAtMs)
{
    // Not used: NarrationService routes audio through pushAudio() for a
    // streaming backend. Answering keeps the contract that every call emits.
    Q_UNUSED(mono16k);
    emit transcribed(QString(), startedAtMs);
}

void DeepgramRecognizer::pushAudio(QList<float> mono16k, qint64 atMs)
{
    // Audio while reconnecting is dropped, not queued. Replaying a backlog
    // would surface verses the preacher said seconds ago as if they were new.
    if (!isLoaded() || mono16k.isEmpty()) return;
    if (m_originMs < 0) m_originMs = atMs;
    m_ws->sendBinaryMessage(toLinear16(mono16k));
    m_sinceSend.restart();
}

// The microphone normally feeds the socket continuously, so this only fires
// when capture has stalled without failing. Without it Deepgram would close
// the stream, and a driver hiccup would turn into a reconnect cycle.
void DeepgramRecognizer::sendKeepAlive()
{
    if (!isLoaded() || m_sinceSend.elapsed() < kKeepAliveAfterMs) return;
    m_ws->sendTextMessage(QStringLiteral("{\"type\":\"KeepAlive\"}"));
    m_sinceSend.restart();
}

QString DeepgramRecognizer::joinedFinals(const QString& tail) const
{
    QStringList parts = m_finals;
    if (!tail.isEmpty()) parts << tail;
    return parts.join(QLatin1Char(' ')).simplified();
}

void DeepgramRecognizer::emitUtterance()
{
    if (m_finals.isEmpty()) return;
    const QString text    = joinedFinals();
    const qint64  startMs = std::max<qint64>(0, m_originMs) + qint64(m_uttStartSec * 1000.0);
    m_finals.clear();
    m_uttStartSec = -1.0;
    emit transcribed(text, startMs);
}

void DeepgramRecognizer::handleMessage(const QString& message)
{
    const QJsonObject obj  = QJsonDocument::fromJson(message.toUtf8()).object();
    const QString     type = obj.value(QLatin1String("type")).toString();

    if (type == QLatin1String("UtteranceEnd")) {
        emitUtterance();
        return;
    }
    if (type != QLatin1String("Results")) return;

    const QJsonArray alts = obj.value(QLatin1String("channel")).toObject()
                                .value(QLatin1String("alternatives")).toArray();
    const QString text = alts.isEmpty()
                         ? QString()
                         : alts.first().toObject().value(QLatin1String("transcript")).toString().trimmed();

    const double start       = obj.value(QLatin1String("start")).toDouble();
    const double duration    = obj.value(QLatin1String("duration")).toDouble();
    const bool   isFinal     = obj.value(QLatin1String("is_final")).toBool();
    const bool   speechFinal = obj.value(QLatin1String("speech_final")).toBool();

    if (!text.isEmpty()) {
        if (m_uttStartSec < 0) m_uttStartSec = start;
        emit segmentTiming(isFinal, start + duration);
    }

    const qint64 uttStartMs = std::max<qint64>(0, m_originMs)
                              + qint64(std::max(0.0, m_uttStartSec) * 1000.0);

    if (!isFinal) {
        // The finalized part of the utterance so far plus the live guess, so
        // the console shows the whole sentence growing rather than only its
        // last few words.
        if (!text.isEmpty()) emit partial(joinedFinals(text), uttStartMs);
        return;
    }

    if (!text.isEmpty()) m_finals << text;

    if (speechFinal) {
        emitUtterance();
    } else if (!m_finals.isEmpty()) {
        emit partial(joinedFinals(), uttStartMs);
    }
}

}  // namespace crater::narration
