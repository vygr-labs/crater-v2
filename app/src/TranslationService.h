#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

#include <memory>

class QCoreApplication;
class QQmlEngine;

namespace crater {

class SettingsService;

// TranslationService — the runtime half of Crater's UI localization.
//
// The whole console is authored with qsTr(); `lupdate` harvests those strings
// into per-language crater_<code>.qm catalogs (bundled at :/i18n/ and, for
// drop-in languages, scanned from <AppDataLocation>/translations/). This
// service installs the right catalog for the operator's chosen language and —
// crucially — swaps it LIVE, with no restart, by re-installing the QTranslator
// and calling QQmlEngine::retranslate() so every qsTr binding re-evaluates.
//
// Why the app layer (not crater-core): live retranslation needs the
// QQmlEngine, and crater-core stays Quick-free per ARCHITECTURE.md §1. The
// persisted choice itself lives in SettingsService.language — this service is
// reactive: it watches SettingsService::languageChanged and applies. QML flips
// the language by calling setLanguage() (a thin pass-through to the setting) or
// by writing SettingsService.language directly; either path lands here.
//
// Lifecycle: construct AFTER the QQmlEngine but BEFORE engine.loadFromModule()
// and call applyPersistedLanguage() so the very first paint is already in the
// operator's language (no retranslate needed pre-load). Register as a QML
// singleton so the Appearance settings picker can drive it.
class TranslationService : public QObject
{
    Q_OBJECT

    // The active UI language code — "en" for the built-in English source, or a
    // Qt locale code (e.g. "es", "pt_BR", "zh_CN"). Mirrors SettingsService.
    Q_PROPERTY(QString currentLanguage READ currentLanguage NOTIFY currentLanguageChanged)

    // Every language the picker offers: English, the bundled translated set,
    // plus any crater_<code>.qm dropped into the user translations directory.
    // Each entry is a map: {
    //   code:        QString  — the value stored in Settings/language
    //   englishName: QString  — e.g. "Spanish"
    //   nativeName:  QString  — e.g. "Español"
    //   label:       QString  — "Español (Spanish)" — the picker's display text
    //   translated:  bool     — true if a .qm catalog is present (else English UI)
    //   rtl:         bool     — right-to-left script
    // }
    Q_PROPERTY(QVariantList availableLanguages READ availableLanguages CONSTANT)

public:
    TranslationService(QCoreApplication* app,
                       QQmlEngine* engine,
                       SettingsService* settings,
                       QObject* parent = nullptr);
    ~TranslationService() override;

    QString currentLanguage() const;
    QVariantList availableLanguages() const;

    // Install the persisted language's catalog once, at startup, before QML is
    // loaded. Does NOT retranslate (nothing is painted yet).
    void applyPersistedLanguage();

    // Change the UI language. Thin pass-through to SettingsService.language —
    // the reactive path (settings changed -> swap catalog -> retranslate) does
    // the actual work, so writing the setting directly behaves identically.
    Q_INVOKABLE void setLanguage(const QString& code);

signals:
    void currentLanguageChanged();

private:
    // Swap the installed QTranslator(s) to `code`'s catalog. Returns true if a
    // catalog was installed; false means English source (code "en"/empty or a
    // missing .qm — the UI stays/falls back to English either way).
    bool loadCatalog(const QString& code);

    // Best available catalog for the OS UI language, or "" if we ship none for
    // it. Used only on first run (before the operator has picked a language).
    QString detectSystemLanguage() const;

    void onLanguageSettingChanged();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
