#include "TranslationService.h"

#include "crater/SettingsService.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QLibraryInfo>
#include <QLocale>
#include <QQmlEngine>
#include <QSet>
#include <QStandardPaths>
#include <QStringList>
#include <QTranslator>
#include <QVariantMap>

namespace crater {

namespace {

// The catalogs Crater ships. `code` is the crater_<code>.qm suffix AND the
// value stored in Settings/language. Keep in lockstep with the bundled .qm set
// in app/CMakeLists.txt and tools/i18n/languages.json. English is the source
// language — it has no .qm and always renders from the qsTr() literals.
struct KnownLang {
    const char*     code;
    const char*     english;  // ASCII only — safe as a narrow literal
    const char16_t* native;   // UTF-16 (u"…") so the non-ASCII names don't
                              // depend on the MSVC /execution-charset — same
                              // safety as QStringLiteral, which the codebase
                              // already relies on for non-ASCII text.
    bool            rtl;
};

constexpr KnownLang kKnownLangs[] = {
    { "en",    "English",                u"English",            false },
    { "es",    "Spanish",                u"Español",            false },
    { "pt_BR", "Portuguese (Brazil)",    u"Português (Brasil)", false },
    { "fr",    "French",                 u"Français",           false },
    { "de",    "German",                 u"Deutsch",            false },
    { "it",    "Italian",                u"Italiano",           false },
    { "nl",    "Dutch",                  u"Nederlands",         false },
    { "ru",    "Russian",                u"Русский",            false },
    { "uk",    "Ukrainian",              u"Українська",         false },
    { "pl",    "Polish",                 u"Polski",             false },
    { "ro",    "Romanian",               u"Română",             false },
    { "zh_CN", "Chinese (Simplified)",   u"简体中文",           false },
    { "zh_TW", "Chinese (Traditional)",  u"繁體中文",           false },
    { "ko",    "Korean",                 u"한국어",             false },
    { "ja",    "Japanese",               u"日本語",             false },
    { "id",    "Indonesian",             u"Bahasa Indonesia",   false },
    { "fil",   "Filipino",               u"Filipino",           false },
    { "sw",    "Swahili",                u"Kiswahili",          false },
    { "hi",    "Hindi",                  u"हिन्दी",              false },
    { "vi",    "Vietnamese",             u"Tiếng Việt",         false },
    { "ar",    "Arabic",                 u"العربية",            true  },
};

QString userTranslationsDir()
{
    // Drop-in catalogs: any crater_<code>.qm placed here is picked up at the
    // next launch with no rebuild — this is how "support almost all languages"
    // stays open-ended past the bundled set.
    return QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation))
        .filePath(QStringLiteral("translations"));
}

bool catalogExists(const QString& code)
{
    if (code.isEmpty() || code == QLatin1String("en"))
        return true;  // source language — always "available"
    if (QFileInfo::exists(QStringLiteral(":/i18n/crater_%1.qm").arg(code)))
        return true;
    return QFileInfo::exists(
        QDir(userTranslationsDir()).filePath(QStringLiteral("crater_%1.qm").arg(code)));
}

QVariantMap makeEntry(const QString& code, const QString& english,
                      const QString& native, bool rtl)
{
    QVariantMap m;
    m.insert(QStringLiteral("code"), code);
    m.insert(QStringLiteral("englishName"), english);
    m.insert(QStringLiteral("nativeName"), native);
    // English gets a bare label; everyone else shows "Native (English)" so the
    // row is findable by typing either the native name or the English name.
    m.insert(QStringLiteral("label"),
             code == QLatin1String("en")
                 ? english
                 : QStringLiteral("%1 (%2)").arg(native, english));
    m.insert(QStringLiteral("translated"), catalogExists(code));
    m.insert(QStringLiteral("rtl"), rtl);
    return m;
}

}  // namespace

struct TranslationService::Impl {
    QCoreApplication* app = nullptr;
    QQmlEngine*       engine = nullptr;
    SettingsService*  settings = nullptr;
    QTranslator*      appTr = nullptr;   // crater_<code>.qm
    QTranslator*      qtTr = nullptr;    // qtbase_<lang>.qm (Qt's own strings)
    QString           appliedCode;       // what's currently installed
};

TranslationService::TranslationService(QCoreApplication* app,
                                       QQmlEngine* engine,
                                       SettingsService* settings,
                                       QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    m_impl->app = app;
    m_impl->engine = engine;
    m_impl->settings = settings;

    // React to the persisted setting changing — whether the picker calls
    // setLanguage() or something writes SettingsService.language directly,
    // both land here and trigger the live swap.
    if (settings) {
        QObject::connect(settings, &SettingsService::languageChanged,
                         this, &TranslationService::onLanguageSettingChanged);
    }
}

TranslationService::~TranslationService() = default;

QString TranslationService::currentLanguage() const
{
    return m_impl->settings ? m_impl->settings->language() : QStringLiteral("en");
}

QVariantList TranslationService::availableLanguages() const
{
    QVariantList out;
    QSet<QString> seen;
    for (const KnownLang& l : kKnownLangs) {
        const QString code = QString::fromLatin1(l.code);
        out.append(makeEntry(code,
                             QString::fromUtf8(l.english),
                             QString::fromUtf16(l.native),
                             l.rtl));
        seen.insert(code);
    }

    // Fold in any drop-in crater_<code>.qm the operator has added, deriving a
    // display name from QLocale. Sorted so the extra block is stable.
    QDir dir(userTranslationsDir());
    if (dir.exists()) {
        QStringList extras = dir.entryList({QStringLiteral("crater_*.qm")}, QDir::Files, QDir::Name);
        for (const QString& file : extras) {
            // crater_<code>.qm  ->  <code>
            QString code = file.mid(7);            // strip "crater_"
            code.chop(3);                          // strip ".qm"
            if (code.isEmpty() || seen.contains(code))
                continue;
            seen.insert(code);
            const QLocale loc(code);
            QString english = QLocale::languageToString(loc.language());
            QString native = loc.nativeLanguageName();
            if (native.isEmpty()) native = code;
            if (english.isEmpty() || english == QLatin1String("C")) english = code;
            out.append(makeEntry(code, english, native,
                                 loc.textDirection() == Qt::RightToLeft));
        }
    }
    return out;
}

bool TranslationService::loadCatalog(const QString& code)
{
    QCoreApplication* app = m_impl->app;

    // Tear down whatever is installed. removeTranslator disconnects the
    // translator cleanly, so deleting straight after is safe.
    if (m_impl->appTr) {
        if (app) app->removeTranslator(m_impl->appTr);
        delete m_impl->appTr;
        m_impl->appTr = nullptr;
    }
    if (m_impl->qtTr) {
        if (app) app->removeTranslator(m_impl->qtTr);
        delete m_impl->qtTr;
        m_impl->qtTr = nullptr;
    }

    if (code.isEmpty() || code == QLatin1String("en"))
        return false;  // English source — nothing to install

    // App catalog: bundled resource first, then the user drop-in directory.
    auto* tr = new QTranslator(this);
    bool ok = tr->load(QStringLiteral("crater_%1").arg(code), QStringLiteral(":/i18n"));
    if (!ok)
        ok = tr->load(QStringLiteral("crater_%1").arg(code), userTranslationsDir());
    if (ok && app) {
        app->installTranslator(tr);
        m_impl->appTr = tr;
    } else {
        delete tr;
    }

    // Qt's own strings (native file-dialog buttons, etc.) — best effort, so a
    // missing qtbase catalog just leaves those few strings in English.
    auto* qtr = new QTranslator(this);
    const QString qtDir = QLibraryInfo::path(QLibraryInfo::TranslationsPath);
    if (app && qtr->load(QLocale(code), QStringLiteral("qtbase"),
                         QStringLiteral("_"), qtDir)) {
        app->installTranslator(qtr);
        m_impl->qtTr = qtr;
    } else {
        delete qtr;
    }

    return ok;
}

QString TranslationService::detectSystemLanguage() const
{
    // Codes we actually ship a catalog for.
    QSet<QString> avail;
    const QVariantList langs = availableLanguages();
    for (const QVariant& v : langs)
        avail.insert(v.toMap().value(QStringLiteral("code")).toString());

    // uiLanguages() is the operator's ordered preference list, most-preferred
    // first — e.g. {"es-ES","es","en-US","en"} or {"zh-Hans-CN","zh-Hans","zh"}.
    const QStringList prefs = QLocale::system().uiLanguages();
    for (const QString& raw : prefs) {
        QString tag = raw;
        tag.replace(QLatin1Char('-'), QLatin1Char('_'));
        const QString low = tag.toLower();
        const QString lang = tag.section(QLatin1Char('_'), 0, 0);

        // Chinese: route script/region to our two catalogs (Simplified default).
        if (lang == QLatin1String("zh")) {
            const bool trad = low.contains(QLatin1String("hant"))
                           || low.contains(QLatin1String("_tw"))
                           || low.contains(QLatin1String("_hk"))
                           || low.contains(QLatin1String("_mo"));
            if (trad && avail.contains(QStringLiteral("zh_TW"))) return QStringLiteral("zh_TW");
            if (!trad && avail.contains(QStringLiteral("zh_CN"))) return QStringLiteral("zh_CN");
            continue;
        }

        // Exact region match first (e.g. pt_BR), then language-only (e.g. fr).
        if (avail.contains(tag))  return tag;
        if (avail.contains(lang)) return lang;
    }
    return {};  // no catalog for the OS language — caller keeps English
}

void TranslationService::applyPersistedLanguage()
{
    QString code = currentLanguage();

    // First run — the operator hasn't chosen a language yet: adopt the OS UI
    // language if we ship a catalog for it (otherwise the persisted "en" holds).
    const bool firstRun = m_impl->settings && !m_impl->settings->hasExplicitLanguage();
    if (firstRun) {
        const QString detected = detectSystemLanguage();
        if (!detected.isEmpty())
            code = detected;
    }

    loadCatalog(code);
    m_impl->appliedCode = code.isEmpty() ? QStringLiteral("en") : code;
    // No retranslate — QML hasn't loaded yet; the first paint reads the
    // freshly-installed catalog.

    // Remember a first-run detection so later launches are stable. Done AFTER
    // appliedCode is set, so the languageChanged this emits is a no-op here
    // (onLanguageSettingChanged sees norm == appliedCode) instead of kicking a
    // premature retranslate before QML has even loaded.
    if (firstRun && code != QLatin1String("en") && m_impl->settings)
        m_impl->settings->setLanguage(code);
}

void TranslationService::setLanguage(const QString& code)
{
    // Thin pass-through: the persisted setter emits languageChanged, and
    // onLanguageSettingChanged() does the catalog swap + retranslate.
    if (m_impl->settings)
        m_impl->settings->setLanguage(code);
}

void TranslationService::onLanguageSettingChanged()
{
    const QString code = currentLanguage();
    const QString norm = code.isEmpty() ? QStringLiteral("en") : code;
    if (norm == m_impl->appliedCode)
        return;

    loadCatalog(norm);
    m_impl->appliedCode = norm;

    // Re-evaluate every qsTr() binding across the loaded QML — this is the
    // live language switch, no restart required.
    if (m_impl->engine)
        m_impl->engine->retranslate();

    emit currentLanguageChanged();
}

}  // namespace crater
