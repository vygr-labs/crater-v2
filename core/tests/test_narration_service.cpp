// Narration phase 2 — the trust gate and NarrationService's routing.
//
// docs/narration.md §5 is the section that makes this feature safe to ship,
// and this file is what holds it to that. Two layers:
//
//   1. TrustGate on its own — all nine cells of the tier x mode matrix,
//      plus what happens to values nobody anticipated.
//   2. NarrationService end to end via injectTranscript() — real citation
//      detection, real de-duplication, real already-live suppression, real
//      queue and log, with no microphone and no speech model involved.
//
// injectTranscript is not a test seam bolted on for this file. It is a
// shipped feature (Settings > Narration lets an operator type a phrase and
// see what Crater would do with it), which means these tests drive exactly
// the code path an operator can drive.

#include <QtTest>

#include <QCoreApplication>
#include <QSettings>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QVariantMap>

#include "crater/NarrationService.h"
#include "crater/ProjectionService.h"
#include "crater/SettingsService.h"
#include "crater/value/HeardReference.h"
#include "narration/TrustGate.h"

using namespace crater;
using narration::trust::actionFor;

namespace {

QVariantMap entryFor(const QVariantList& list, const QString& reference)
{
    for (const QVariant& v : list) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("reference")).toString() == reference) return m;
    }
    return {};
}

// A scripture item shaped the way ScriptureItems.qml builds them, which is
// what ProjectionService::currentItem holds once something is live.
QVariantMap liveScripture(const QString& book, int chapter, int from, int to)
{
    QVariantMap ref;
    ref.insert(QStringLiteral("book"),       book);
    ref.insert(QStringLiteral("chapter"),    chapter);
    ref.insert(QStringLiteral("verseStart"), from);
    ref.insert(QStringLiteral("verseEnd"),   to);

    QVariantMap item;
    item.insert(QStringLiteral("kind"),         QStringLiteral("scripture"));
    item.insert(QStringLiteral("scriptureRef"), ref);
    return item;
}

}  // namespace

class TestNarrationService : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase()
    {
        // Redirects QStandardPaths, which is what DbPaths resolves through.
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QStandardPaths::setTestModeEnabled(true);

        // What those two lines do NOT do is move SettingsService's storage,
        // and an earlier version of this comment claimed they did.
        //
        // SettingsService holds QSettings{"Voyager Labs", "Crater"} — the
        // (organization, application) constructor, which is always
        // NativeFormat. setDefaultFormat() only governs the QSettings(QObject*)
        // and QSettings(Scope, ...) forms, so it never applied here, and on
        // Windows NativeFormat is the registry, which test mode does not
        // redirect either. Every setter below therefore writes to the
        // operator's live preferences.
        //
        // That is not hypothetical: this suite left "Z:/no/such/model.bin" in
        // a real install's narrationModelPath, which silently disables the
        // whole feature until someone re-picks the model. Save the narration
        // keys here and put them back in cleanupTestCase.
        //
        // Storage is still shared by every test in the process, and
        // SettingsService really does persist. Any test whose expectation
        // depends on the narration mode sets it explicitly rather than
        // trusting the default — otherwise it passes or fails according to
        // what the test before it happened to leave behind.
        SettingsService s;
        m_savedModelPath = s.narrationModelPath();
        m_savedMode      = s.narrationMode();
        m_savedGraceMs   = s.narrationGraceMs();
        m_savedDeviceId  = s.narrationInputDeviceId();
    }

    void cleanupTestCase()
    {
        SettingsService s;
        s.setNarrationModelPath(m_savedModelPath);
        s.setNarrationMode(m_savedMode);
        s.setNarrationGraceMs(m_savedGraceMs);
        s.setNarrationInputDeviceId(m_savedDeviceId);
    }

    // ── Microphone selection ────────────────────────────────────────────

    void the_default_input_device_is_the_system_one()
    {
        SettingsService settings;
        settings.setNarrationInputDeviceId(QString());
        NarrationService svc(nullptr, nullptr, &settings);

        // Empty means "follow the system", which is a real state and not the
        // same as naming whichever device is default today.
        QVERIFY(svc.inputDeviceId().isEmpty());
    }

    void choosing_a_device_persists_it()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy spy(&svc, &NarrationService::inputDeviceChanged);
        svc.setInputDevice(QStringLiteral("some-device-id"));

        QCOMPARE(svc.inputDeviceId(), QStringLiteral("some-device-id"));
        QCOMPARE(settings.narrationInputDeviceId(), QStringLiteral("some-device-id"));
        QCOMPARE(spy.count(), 1);

        // Idempotent: re-selecting the same device is not a change, and must
        // not churn a binding or (worse) reopen a live microphone.
        svc.setInputDevice(QStringLiteral("some-device-id"));
        QCOMPARE(spy.count(), 1);
    }

    // The rule that matters on a Sunday. A device id saved last month may name
    // a microphone that is not plugged in today, and the answer to that is the
    // default input, not silence.
    void an_unknown_device_falls_back_to_the_default()
    {
        SettingsService settings;
        settings.setNarrationInputDeviceId(QStringLiteral("id-of-a-device-that-is-not-here"));
        NarrationService svc(nullptr, nullptr, &settings);

        // The id is remembered — unplugging a microphone must not silently
        // discard the operator's choice, because plugging it back in should
        // restore it without them re-picking.
        QCOMPARE(svc.inputDeviceId(), QStringLiteral("id-of-a-device-that-is-not-here"));

        // But the resolved device is whatever is actually available. On a
        // machine with no inputs at all this is empty, which is honest;
        // anywhere else it is the system default's name.
        const QVariantList devices = svc.inputDevices();
        if (devices.isEmpty()) {
            QVERIFY(svc.inputDeviceName().isEmpty());
        } else {
            QVERIFY2(!svc.inputDeviceName().isEmpty(),
                     "a missing saved device must resolve to the default, not to nothing");
        }

        // And nothing claims to be the selected device, so the settings page
        // can tell "pinned to this one" from "falling back".
        for (const QVariant& v : devices)
            QVERIFY(!v.toMap().value(QStringLiteral("isSelected")).toBool());
    }

    void a_present_device_is_marked_selected()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);

        const QVariantList before = svc.inputDevices();
        if (before.isEmpty())
            QSKIP("no audio inputs on this machine");

        const QString id = before.first().toMap().value(QStringLiteral("id")).toString();
        svc.setInputDevice(id);

        int selected = 0;
        for (const QVariant& v : svc.inputDevices()) {
            const QVariantMap m = v.toMap();
            if (m.value(QStringLiteral("isSelected")).toBool()) {
                ++selected;
                QCOMPARE(m.value(QStringLiteral("id")).toString(), id);
            }
        }
        QCOMPARE(selected, 1);
        QCOMPARE(svc.inputDeviceName(),
                 before.first().toMap().value(QStringLiteral("name")).toString());
    }

    // Selecting a device is a preference change, not an arming action. §8's
    // rule is that the microphone opens on arm() and on nothing else, and a
    // picker that opened it to "preview" the choice would be exactly the kind
    // of helpful idea that breaks the guarantee.
    void choosing_a_device_never_opens_the_microphone()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);

        const QVariantList devices = svc.inputDevices();
        if (devices.isEmpty())
            QSKIP("no audio inputs on this machine");

        svc.setInputDevice(devices.first().toMap().value(QStringLiteral("id")).toString());
        QVERIFY(!svc.listening());
        QCOMPARE(svc.inputLevel(), 0.0);
        QVERIFY(!svc.hearingSpeech());
    }

    // ── The trust gate, cell by cell ────────────────────────────────────

    void gate_suggest_queues_everything()
    {
        QCOMPARE(actionFor("certain",  "suggest"), QStringLiteral("queued"));
        QCOMPARE(actionFor("high",     "suggest"), QStringLiteral("queued"));
        QCOMPARE(actionFor("possible", "suggest"), QStringLiteral("queued"));
    }

    void gate_stage_previews_all_but_guesses()
    {
        QCOMPARE(actionFor("certain",  "stage"), QStringLiteral("staged"));
        QCOMPARE(actionFor("high",     "stage"), QStringLiteral("staged"));
        QCOMPARE(actionFor("possible", "stage"), QStringLiteral("queued"));
    }

    void gate_auto_projects_only_spoken_addresses()
    {
        QCOMPARE(actionFor("certain",  "auto"), QStringLiteral("live"));
        // Inferred from context: unambiguous, but still inferred. Not enough
        // to drive the audience screen unattended.
        QCOMPARE(actionFor("high",     "auto"), QStringLiteral("staged"));
        QCOMPARE(actionFor("possible", "auto"), QStringLiteral("queued"));
    }

    // The property everything else rests on, asserted on its own so a future
    // edit to the matrix cannot quietly weaken it.
    void gate_a_guess_never_reaches_the_projector()
    {
        const QStringList modes{ "suggest", "stage", "auto" };
        for (const QString& mode : modes)
            QVERIFY2(actionFor("possible", mode) != QStringLiteral("live"),
                     qPrintable(QStringLiteral("possible tier fired in %1 mode").arg(mode)));
    }

    // Live suggestions are produced by re-transcribing a sentence that is not
    // finished, so the gate has to know the difference between "the preacher
    // said this" and "the preacher is partway through saying something".
    //
    // The case that matters: "turn to John three" identifies John 3:1 with
    // complete confidence, and is wrong the moment the next word is "sixteen".
    // Auto mode's entire purpose is to project without waiting for a human, so
    // a partial must never be allowed to reach it.
    void gate_a_partial_hypothesis_never_reaches_the_projector()
    {
        const QStringList tiers{ "certain", "high", "possible" };
        const QStringList modes{ "suggest", "stage", "auto" };
        for (const QString& tier : tiers) {
            for (const QString& mode : modes) {
                QVERIFY2(actionFor(tier, mode, /*fromPartial=*/true) != QStringLiteral("live"),
                         qPrintable(QStringLiteral("partial %1/%2 reached the projector")
                                        .arg(tier, mode)));
            }
        }

        // Exactly one cell moves, and only downward: the one that would
        // otherwise have gone live.
        QCOMPARE(actionFor("certain", "auto", true), QStringLiteral("staged"));

        // Everything else is untouched, so a partial still populates the queue
        // and still stages. Suppressing it entirely would trade the latency
        // problem for a silence problem.
        for (const QString& tier : tiers) {
            for (const QString& mode : modes) {
                if (tier == QStringLiteral("certain") && mode == QStringLiteral("auto"))
                    continue;
                QCOMPARE(actionFor(tier, mode, true), actionFor(tier, mode, false));
            }
        }
    }

    void gate_unknown_values_fail_closed()
    {
        // A detection path added later that forgets to set a tier must be
        // treated as a guess, not as certainty.
        QCOMPARE(actionFor("",         "auto"), QStringLiteral("queued"));
        QCOMPARE(actionFor("verbatim", "auto"), QStringLiteral("queued"));
        // And a garbled mode must not fall through to something permissive.
        QCOMPARE(actionFor("certain", ""),       QStringLiteral("queued"));
        QCOMPARE(actionFor("certain", "Auto "),  QStringLiteral("queued"));
        QCOMPARE(actionFor("certain", "AUTO"),   QStringLiteral("queued"));
    }

    // ── Mode persistence ────────────────────────────────────────────────

    void mode_rejects_unknown_values()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("auto"));
        QCOMPARE(settings.narrationMode(), QStringLiteral("auto"));

        // A bad write leaves the previous mode standing rather than resetting
        // to a default: silently dropping out of Auto would be surprising,
        // and silently entering it would be dangerous.
        settings.setNarrationMode(QStringLiteral("Auto "));
        QCOMPARE(settings.narrationMode(), QStringLiteral("auto"));
        settings.setNarrationMode(QStringLiteral("yolo"));
        QCOMPARE(settings.narrationMode(), QStringLiteral("auto"));

        settings.setNarrationMode(QStringLiteral("stage"));
        QCOMPARE(settings.narrationMode(), QStringLiteral("stage"));
    }

    void grace_period_is_clamped_to_a_usable_range()
    {
        SettingsService settings;
        settings.setNarrationGraceMs(50);
        QVERIFY2(settings.narrationGraceMs() >= 500,
                 "a grace period too short to read defeats its own purpose");
        settings.setNarrationGraceMs(999999);
        QVERIFY(settings.narrationGraceMs() <= 10000);
        settings.setNarrationGraceMs(1500);
        QCOMPARE(settings.narrationGraceMs(), 1500);
    }

    // ── Routing through the service ─────────────────────────────────────

    void stage_mode_emits_staged_for_a_spoken_address()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy staged(&svc, &NarrationService::referenceStaged);
        QSignalSpy queued(&svc, &NarrationService::referenceDetected);
        QSignalSpy live(&svc,   &NarrationService::referenceAutoLive);

        svc.injectTranscript(QStringLiteral("turn with me to john chapter three verse sixteen"));

        QCOMPARE(staged.count(), 1);
        QCOMPARE(queued.count(), 0);
        QCOMPARE(live.count(),   0);

        const auto ref = staged.at(0).at(0).value<HeardReference>();
        QCOMPARE(ref.book,       QStringLiteral("John"));
        QCOMPARE(ref.chapter,    3);
        QCOMPARE(ref.verseStart, 16);
        QCOMPARE(ref.tier,       QStringLiteral("certain"));
        QCOMPARE(ref.kind,       QStringLiteral("citation"));
    }

    void suggest_mode_moves_nothing()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("suggest"));
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy staged(&svc, &NarrationService::referenceStaged);
        QSignalSpy queued(&svc, &NarrationService::referenceDetected);

        svc.injectTranscript(QStringLiteral("turn with me to john chapter three verse sixteen"));

        QCOMPARE(staged.count(), 0);
        QCOMPARE(queued.count(), 1);
        QCOMPARE(svc.heardCount(), 1);
    }

    void auto_mode_projects_a_full_address()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("auto"));
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy live(&svc, &NarrationService::referenceAutoLive);
        svc.injectTranscript(QStringLiteral("turn with me to romans chapter eight verse twenty eight"));

        QCOMPARE(live.count(), 1);
        const auto ref = live.at(0).at(0).value<HeardReference>();
        QCOMPARE(ref.book,       QStringLiteral("Romans"));
        QCOMPARE(ref.chapter,    8);
        QCOMPARE(ref.verseStart, 28);
    }

    // A bare "verse nine" is resolved from context, which is inference. Auto
    // mode must stage it rather than project it, even though the operator has
    // opted into Auto.
    void auto_mode_will_not_project_a_context_recovered_verse()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("auto"));
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy live(&svc,   &NarrationService::referenceAutoLive);
        QSignalSpy staged(&svc, &NarrationService::referenceStaged);

        svc.injectTranscript(QStringLiteral("turn with me to james chapter one verse two"));
        QCOMPARE(live.count(), 1);          // the spoken address goes live

        svc.injectTranscript(QStringLiteral("now look at verse nine"));
        QCOMPARE(live.count(),   1);        // still one; the bare verse did not
        QCOMPARE(staged.count(), 1);

        const auto ref = staged.at(0).at(0).value<HeardReference>();
        QCOMPARE(ref.book,       QStringLiteral("James"));
        QCOMPARE(ref.chapter,    1);
        QCOMPARE(ref.verseStart, 9);
        QCOMPARE(ref.tier,       QStringLiteral("high"));
    }

    // ── Suppression ─────────────────────────────────────────────────────

    void the_same_reference_twice_fires_once()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy staged(&svc, &NarrationService::referenceStaged);

        svc.injectTranscript(QStringLiteral("turn to john chapter three verse sixteen"));
        svc.injectTranscript(QStringLiteral("john chapter three verse sixteen again"));

        QCOMPARE(staged.count(), 1);
        QCOMPARE(svc.heardCount(), 1);

        // Suppressed, but not invisible: an operator asking why it did not
        // fire the second time gets an answer.
        const QVariantList log = svc.sessionLog();
        QCOMPARE(log.size(), 2);
        QCOMPARE(log.at(1).toMap().value(QStringLiteral("action")).toString(),
                 QStringLiteral("duplicate"));
    }

    void a_verse_already_on_screen_is_not_re_sent()
    {
        SettingsService   settings;
        ProjectionService projection;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, &projection, &settings);

        QSignalSpy staged(&svc, &NarrationService::referenceStaged);

        // A passage, not a single verse: the preacher saying "verse sixteen"
        // while John 3:14-17 is on the screen is already being answered.
        projection.goLive(liveScripture(QStringLiteral("John"), 3, 14, 17), 0);

        svc.injectTranscript(QStringLiteral("turn to john chapter three verse sixteen"));
        QCOMPARE(staged.count(), 0);
        QCOMPARE(svc.sessionLog().size(), 1);
        QCOMPARE(svc.sessionLog().at(0).toMap().value(QStringLiteral("action")).toString(),
                 QStringLiteral("already-live"));

        // Outside the live range, so it is new information.
        svc.injectTranscript(QStringLiteral("and john chapter three verse thirty six"));
        QCOMPARE(staged.count(), 1);
    }

    void a_cleared_output_makes_the_verse_sendable_again()
    {
        SettingsService   settings;
        ProjectionService projection;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, &projection, &settings);

        QSignalSpy staged(&svc, &NarrationService::referenceStaged);

        projection.goLive(liveScripture(QStringLiteral("Psalms"), 23, 1, 1), 0);
        projection.clear();

        // Nothing is in front of the congregation, so re-sending is meaningful.
        svc.injectTranscript(QStringLiteral("turn to psalm twenty three verse one"));
        QCOMPARE(staged.count(), 1);
    }

    // ── Queue and log ───────────────────────────────────────────────────

    void the_queue_records_what_the_gate_did()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        svc.injectTranscript(QStringLiteral("turn to genesis chapter one verse one"));
        const QVariantMap e = entryFor(svc.heard(), QStringLiteral("Genesis 1:1"));
        QVERIFY(!e.isEmpty());
        QCOMPARE(e.value(QStringLiteral("action")).toString(), QStringLiteral("staged"));
        QCOMPARE(e.value(QStringLiteral("tier")).toString(),   QStringLiteral("certain"));
        QVERIFY(e.value(QStringLiteral("id")).toInt() > 0);
        QVERIFY(!e.value(QStringLiteral("heardText")).toString().isEmpty());
    }

    void the_queue_is_newest_first()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        svc.injectTranscript(QStringLiteral("turn to genesis chapter one verse one"));
        svc.injectTranscript(QStringLiteral("turn to exodus chapter two verse three"));

        QCOMPARE(svc.heardCount(), 2);
        QCOMPARE(svc.heard().at(0).toMap().value(QStringLiteral("reference")).toString(),
                 QStringLiteral("Exodus 2:3"));
    }

    void dismiss_removes_one_entry_by_id()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        svc.injectTranscript(QStringLiteral("turn to genesis chapter one verse one"));
        svc.injectTranscript(QStringLiteral("turn to exodus chapter two verse three"));
        QCOMPARE(svc.heardCount(), 2);

        const int id = entryFor(svc.heard(), QStringLiteral("Genesis 1:1"))
                           .value(QStringLiteral("id")).toInt();
        svc.dismiss(id);

        QCOMPARE(svc.heardCount(), 1);
        QVERIFY(entryFor(svc.heard(), QStringLiteral("Genesis 1:1")).isEmpty());

        // Dismissing something that is already gone is not an error.
        svc.dismiss(id);
        QCOMPARE(svc.heardCount(), 1);

        svc.dismissAll();
        QCOMPARE(svc.heardCount(), 0);
        // The log is the audit trail and survives the queue being cleared.
        QCOMPARE(svc.sessionLog().size(), 2);
    }

    void one_utterance_can_carry_several_references()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        svc.injectTranscript(QStringLiteral(
            "turn to john chapter three verse sixteen and romans chapter five verse eight"));

        QCOMPARE(svc.heardCount(), 2);
        QVERIFY(!entryFor(svc.heard(), QStringLiteral("John 3:16")).isEmpty());
        QVERIFY(!entryFor(svc.heard(), QStringLiteral("Romans 5:8")).isEmpty());
    }

    void ordinary_speech_does_not_fire()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);

        // Book names are also names. None of these is a scripture cue.
        svc.injectTranscript(QStringLiteral("mark said he would be here at seven"));
        svc.injectTranscript(QStringLiteral("john was there last week"));
        svc.injectTranscript(QStringLiteral("james from the worship team is leading"));

        QCOMPARE(svc.heardCount(), 0);
        QCOMPARE(svc.sessionLog().size(), 0);
    }

    void empty_input_is_ignored()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);

        svc.injectTranscript(QString());
        svc.injectTranscript(QStringLiteral("   "));
        QCOMPARE(svc.heardCount(), 0);
    }

    // ── Session scoping (docs/narration.md §8) ──────────────────────────

    void disarm_discards_the_session()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("stage"));
        NarrationService svc(nullptr, nullptr, &settings);

        svc.injectTranscript(QStringLiteral("turn to john chapter three verse sixteen"));
        svc.injectTranscript(QStringLiteral("look at verse seventeen"));
        QVERIFY(svc.heardCount() > 0);
        const int logged = int(svc.sessionLog().size());
        QVERIFY(logged > 0);

        svc.disarm();

        QCOMPARE(svc.heardCount(), 0);
        QCOMPARE(svc.inputLevel(), 0.0);
        QVERIFY(!svc.listening());

        // The log is the exception, and deliberately so: a church reviewing
        // what happened last Sunday cannot do it with a log that died when
        // the operator closed the microphone. References and trigger spans
        // only — the transcript was never kept.
        QCOMPARE(svc.sessionLog().size(), logged);

        // Reference context went with it: a bare verse no longer resolves,
        // because the chapter it belonged to is not a safe assumption after
        // the operator closed the microphone.
        QSignalSpy staged(&svc, &NarrationService::referenceStaged);
        svc.injectTranscript(QStringLiteral("look at verse nine"));
        QCOMPARE(staged.count(), 0);
        QCOMPARE(svc.heardCount(), 0);

        svc.clearLog();
        QCOMPARE(svc.sessionLog().size(), 0);
    }

    // ── Log amendment (the Auto-mode cancel window) ─────────────────────

    void the_log_can_be_corrected_after_the_fact()
    {
        SettingsService settings;
        settings.setNarrationMode(QStringLiteral("auto"));
        NarrationService svc(nullptr, nullptr, &settings);

        QSignalSpy live(&svc, &NarrationService::referenceAutoLive);
        svc.injectTranscript(QStringLiteral("turn to john chapter three verse sixteen"));
        QCOMPARE(live.count(), 1);

        // The signal carries the same handle the queue and log do — without
        // it the console could not tell the log which decision it reversed.
        const auto ref = live.at(0).at(0).value<HeardReference>();
        QVERIFY(ref.id > 0);
        QCOMPARE(entryFor(svc.heard(), QStringLiteral("John 3:16"))
                     .value(QStringLiteral("id")).toInt(), ref.id);
        QCOMPARE(entryFor(svc.sessionLog(), QStringLiteral("John 3:16"))
                     .value(QStringLiteral("action")).toString(), QStringLiteral("live"));

        // The operator hit Cancel inside the grace window. A log still
        // claiming the verse went live would be worse than no log.
        svc.amendLog(ref.id, QStringLiteral("cancelled"));
        QCOMPARE(entryFor(svc.sessionLog(), QStringLiteral("John 3:16"))
                     .value(QStringLiteral("action")).toString(), QStringLiteral("cancelled"));
    }

    void the_log_rejects_outcomes_the_console_cannot_produce()
    {
        SettingsService settings;
        // Set explicitly rather than relying on the default. SettingsService
        // genuinely persists, so a mode left behind by an earlier test in
        // this process is still there when the next one constructs its own
        // instance — which is exactly the behaviour operators depend on and
        // exactly the trap a test suite falls into.
        settings.setNarrationMode(QStringLiteral("stage"));

        NarrationService svc(nullptr, nullptr, &settings);
        svc.injectTranscript(QStringLiteral("turn to john chapter three verse sixteen"));

        const int id = entryFor(svc.heard(), QStringLiteral("John 3:16"))
                           .value(QStringLiteral("id")).toInt();
        QVERIFY(id > 0);

        // The log is an audit trail. Letting the UI write arbitrary strings
        // into it would make it answerable only by trusting the UI.
        svc.amendLog(id, QStringLiteral("definitely-fine"));
        QCOMPARE(entryFor(svc.sessionLog(), QStringLiteral("John 3:16"))
                     .value(QStringLiteral("action")).toString(), QStringLiteral("staged"));

        // An unknown id is a no-op, not a crash.
        svc.amendLog(99999, QStringLiteral("cancelled"));
        QCOMPARE(entryFor(svc.sessionLog(), QStringLiteral("John 3:16"))
                     .value(QStringLiteral("action")).toString(), QStringLiteral("staged"));
    }

    // ── Arming refusals ─────────────────────────────────────────────────

    void arming_refuses_and_explains_itself()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);

        QVERIFY(!svc.listening());

        if (!svc.available()) {
            // Default build: whisper is compiled out. The refusal has to name
            // the reason, because "nothing happened" is indistinguishable from
            // a microphone that is on but hearing nothing.
            QVERIFY(!svc.arm());
            QCOMPARE(svc.engineState(), QStringLiteral("unavailable"));
            QVERIFY(!svc.statusMessage().isEmpty());
        } else {
            // Speech build with no model configured.
            settings.setNarrationModelPath(QString());
            QVERIFY(!svc.modelReady());
            QVERIFY(!svc.arm());
            QCOMPARE(svc.engineState(), QStringLiteral("error"));
            QVERIFY(!svc.statusMessage().isEmpty());
        }

        // A refused arm must never leave the microphone open.
        QVERIFY(!svc.listening());
    }

    void a_missing_model_path_is_never_ready()
    {
        SettingsService settings;
        settings.setNarrationModelPath(QStringLiteral("Z:/no/such/model.bin"));
        NarrationService svc(nullptr, nullptr, &settings);
        QVERIFY(!svc.modelReady());
    }

    // Construction must not open the microphone. §8's arming rule is only
    // meaningful if it holds for the object's whole lifetime, starting here.
    void constructing_the_service_does_not_open_the_microphone()
    {
        SettingsService settings;
        NarrationService svc(nullptr, nullptr, &settings);
        QVERIFY(!svc.listening());
        QCOMPARE(svc.inputLevel(), 0.0);
        QVERIFY(!svc.hearingSpeech());
    }

private:
    // The operator's real narration preferences, borrowed for the duration of
    // the run and returned in cleanupTestCase. See initTestCase.
    QString m_savedModelPath;
    QString m_savedMode;
    int     m_savedGraceMs = 1500;
    QString m_savedDeviceId;
};

QTEST_MAIN(TestNarrationService)
#include "test_narration_service.moc"
