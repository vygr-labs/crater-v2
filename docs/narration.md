# Crater (Qt) — AI Scripture Narration

Crater listens to the preacher and puts the scripture on screen without an
operator touching anything.

This document is the design record for that subsystem, in the same spirit as
[`architecture.md`](architecture.md): it exists so the *why* survives, and so
we don't drift off the load-bearing decisions while building it.

Read `architecture.md` first. Everything here is subordinate to it, with two
explicit amendments called out in §8 and §9.

---

## 1. The problem, stated honestly

The pitch is "eliminate the projectionist." The reality is that a projectionist
does two jobs, and only one of them is hard to automate:

1. **Hear a reference, find it, put it up.** Mechanical. This is what we're
   replacing.
2. **Decide whether it should go up at all.** Judgment. A preacher saying
   "Mark told me last week" is not a scripture cue. A preacher re-reading a
   verse already on screen doesn't need it re-sent.

A system that only solves (1) and pretends it solved (2) puts wrong verses on
the main screen during a sermon. That failure is *worse* than no automation,
because the congregation sees it and the pastor has to work around it live.

So the design's centre of gravity is not recognition accuracy. It's **knowing
how sure we are, and doing something proportionate to that.** §5 is the most
important section in this document.

---

## 2. Two detection paths, not one

The naive framing is "speech to text, then parse the reference." That only
catches half of what preachers actually do.

| What the preacher says | Path | Example |
|---|---|---|
| Names the address | **Citation** | "Turn with me to First Corinthians chapter thirteen" |
| Quotes the words | **Quotation** | "For God so loved the world, that he gave his only begotten Son" |
| Paraphrases the words | **Allusion** | "God loved us so much that he sent his own son to die" |

These are three different computational problems and the system runs all three
concurrently over the same transcript stream.

**Citation** is deterministic parsing. Spoken words to a normalized reference
string, then handed to the existing `BibleService::parseReference`. We do not
write a second book-name resolver — `crater::import::lookupBook` already does
exact, alias, prefix, subsequence, and bounded-edit-distance matching, which
is exactly the tolerance a mangled transcript needs. "Fill of pians" resolving
to Philippians is a problem that codebase already solved.

**Quotation** is lexical retrieval. The transcript window goes at the existing
FTS5 trigram index over `verses.text` via `BibleService::search`. Near-verbatim
quoting is extremely common in preaching, and this path costs us almost
nothing because the index already exists and is already tuned.

The original plan here was "a strong BM25 hit is near-conclusive." Measuring
against a real fourteen-translation library replaced that with something
better. `BibleService::search` is an implicit AND, so a window of distinctive
words asks *which verses contain all of these* — and the answer's **shape** is
the evidence, not its score:

- One verse owning the phrase outright is conclusive.
- Eleven translations of Genesis 1:1 plus one loose paraphrase of 2 Peter 3:5
  is still conclusive. (Strict uniqueness was the first rule written here and
  it discarded the opening line of the Bible over a single stray row.)
- Nine votes for John 13:34 against eight for John 15:12 is not an answer at
  all. Both verses really do contain "love one another, as I have loved you",
  so the phrase identifies neither.

So the gate is **dominance**: the best-scoring verse must hold at least twice
as many rows as everything else combined. That has no threshold to re-tune per
translation, per index rebuild, or per verse length — unlike a BM25 cutoff,
where every re-tuning is a chance to quietly start firing on ordinary speech.

Tier follows **coverage** rather than word count: how much of the matched
verse did the preacher actually say? "The LORD is my shepherd, I shall not
want" keeps only three words past a stopword filter, but those three *are* the
verse. A count-based rule would have thrown away the second most quoted verse
in the Bible.

**Allusion** is semantic retrieval, and it's the only path that needs new
machinery (§7). It's also the path with by far the worst false-positive
profile, which is why §5 never lets it fire on its own.

The important structural point: **all three paths converge on the same output
type** (`HeardReference`), differing only in their `kind` and `confidence`.
Everything downstream — context tracking, trust gating, the operator UI — is
written once against that type.

---

## 3. Pipeline

```
  microphone
      │  QAudioSource → QIODevice, 16 kHz mono s16le
      ▼
  ┌─────────────┐   ring buffer, never written to disk (§8)
  │ AudioTap    │
  └─────────────┘
      │  VAD-segmented utterances (Silero, ~1.8 MB ONNX)
      ▼
  ┌─────────────┐   whisper.cpp, own thread, partials + finals
  │ Recognizer  │   (SpeechRecognizer interface — swappable)
  └─────────────┘
      │  rolling transcript window
      ▼
  ┌───────────────────────────────────────────────┐
  │ CitationDetector    QuotationMatcher   Allusion│   all three, concurrently
  │  (pure text)         (FTS5/BM25)      (vectors)│
  └───────────────────────────────────────────────┘
      │  QList<HeardReference>
      ▼
  ┌─────────────┐   resolves "verse nine" against current book+chapter
  │ RefContext  │   de-dupes repeats, suppresses what's already live
  └─────────────┘
      │
      ▼
  ┌─────────────┐   confidence tier vs operator's mode (§5)
  │ TrustGate   │
  └─────────────┘
      │
      ├─ suggest → heard queue in operator console
      ├─ stage   → AppState.pushLibraryPreview(item, 0)
      └─ auto    → AppState.goLive(...) after grace period
```

### 3.1 Where the code lives

Per `architecture.md` §9 (no window, touches files, unit-testable headless),
all of this is **crater-core**, under `core/src/narration/`. The executable
gets a mic toggle, a heard queue, and a settings page. Nothing else.

| Component | File | Qt/QML surface |
|---|---|---|
| `HeardReference` | `include/crater/value/HeardReference.h` | `Q_GADGET` value type |
| `CitationDetector` | `src/narration/CitationDetector.cpp` | none (pure) |
| `SpokenNumbers` | `src/narration/SpokenNumbers.cpp` | none (pure) |
| `QuotationMatcher` | `src/narration/QuotationMatcher.cpp` | none |
| `AllusionIndex` | `src/narration/AllusionIndex.cpp` | none |
| `SpeechRecognizer` | `src/narration/SpeechRecognizer.h` | abstract interface |
| `WhisperRecognizer` | `src/narration/WhisperRecognizer.cpp` | none |
| `NarrationService` | `include/crater/NarrationService.h` | `QML_ELEMENT` singleton |

One QML-visible singleton, per `architecture.md` §4. The recognizer, the three
detectors, and the audio tap are private implementation detail. `NarrationService`
is the only thing QML can see, and its surface is deliberately small:

```cpp
Q_PROPERTY(bool    listening   READ listening   NOTIFY listeningChanged)
Q_PROPERTY(QString mode        READ mode        WRITE setMode   NOTIFY modeChanged)
Q_PROPERTY(qreal   inputLevel  READ inputLevel  NOTIFY inputLevelChanged)
Q_PROPERTY(QString engineState READ engineState NOTIFY engineStateChanged)
Q_PROPERTY(QVariantList heard  READ heard       NOTIFY heardChanged)

Q_INVOKABLE void arm();      // start listening — explicit operator action only
Q_INVOKABLE void disarm();
Q_INVOKABLE void dismiss(int heardIndex);

signals:
    void referenceDetected(crater::HeardReference ref);   // suggest tier
    void referenceStaged(crater::HeardReference ref);     // stage tier
    void referenceAutoLive(crater::HeardReference ref);   // auto tier
```

Three separate signals rather than one signal plus a tier field, because the
QML handlers are genuinely different actions and `architecture.md` §11 rules
out a global event bus. Every event has one obvious publisher and one obvious
consumer.

---

## 4. Citation detection

The mechanical path, and the one that must be bulletproof.

### 4.1 Spoken number normalization

Whisper emits numbers inconsistently — sometimes digits ("John 3 16"),
sometimes words ("chapter thirteen"), often mixed in one utterance. Both
normalize through the same tokenizer.

The subtle case is adjacency. "Twenty two" is the number 22. "Three sixteen"
is chapter 3 verse 16. Getting this wrong breaks the most common spoken form
of the most commonly quoted verse in the Bible.

Resolution: `SpokenNumbers::parsePhrase` consumes only as many tokens as form
**one** number, using standard English composition rules:

- tens (20,30,…90) followed by a unit (1–9) compose: "twenty two" → 22
- a unit followed by "hundred" multiplies, then absorbs a remainder:
  "one hundred nineteen" → 119
- anything else terminates the phrase

So "three sixteen" parses as two separate phrases (3, then 16), and *that*
adjacency is what the reference grammar reads as chapter:verse. The rule falls
out of number grammar rather than being a special case, which is why it
generalizes to "one nineteen" (Psalm 119 vs Psalm 1:19 — see §11).

Ordinals are handled for book prefixes, where speech is unpredictable:
"first Corinthians", "one Corinthians", and "1 Corinthians" all reach the same
place.

### 4.2 The reference grammar

After a book token resolves, the detector looks ahead for:

```
  chapter N verse M           → N:M
  chapter N                   → N:1        (whole chapter)
  N M                         → N:M        (bare "three sixteen")
  N                           → N:1
  N verse[s] M through P      → N:M-P
  N M and P                   → N:M, N:P   (two refs)
```

And with no book token at all, resolved against `RefContext` (§6):

```
  verse M                     → <ctx book> <ctx chapter>:M
  verses M through P          → range
  the next verse              → ctx verse + 1
```

### 4.3 Cue gating

Book names are also ordinary words. "John was there", "Mark said", "the acts
of the apostles", "james from the worship team". A bare book name never fires
on its own.

A citation fires only when a book token is accompanied by numeric structure,
**or** preceded by an intent cue: "turn to", "turn with me to", "look at",
"open your Bibles to", "found in", "the book of", "it says in", "according to".

Bare "verse N" with no book requires an active `RefContext` less than ~6
minutes old, otherwise it's discarded. Sermons wander, and a verse number
recovered from context ten minutes stale is a coin flip.

---

## 5. Confidence tiers and the trust model

This is the section that makes the feature safe to ship.

Each detection path produces a **structurally different quality of evidence**,
and the tier is a property of the path, not a tuned number:

| Tier | Source | Evidence quality | Default action |
|---|---|---|---|
| **Certain** | Citation with explicit book + chapter + verse | The preacher said the address out loud | eligible for **auto** |
| **High** | Citation from context, or verbatim quotation with strong BM25 over ≥5 distinctive content words | Unambiguous, but inferred | eligible for **stage** |
| **Possible** | Semantic allusion, or weak/ambiguous lexical hit | A guess, however good | **suggest only, never fires** |

Crossed with the three operator modes:

| Mode | Certain | High | Possible |
|---|---|---|---|
| **Suggest** | queue | queue | queue |
| **Stage** (default) | preview | preview | queue |
| **Auto** | **live** after grace | preview | queue |

Note what this table forbids: **a semantic allusion can never reach the
projector on its own, in any mode.** The paraphrase path is the one that makes
the feature feel magical, and it is also the one that would eventually put a
wrong verse in front of a congregation. It earns its place by populating a
queue the operator can act on in one click, not by driving the output.

`Auto` mode inserts a **grace period** (default 1.5 s, configurable) with a
large, unmissable cancel affordance before the verse goes live. This is the
difference between "the machine did something wrong" and "the machine
proposed something wrong and a human had a beat to stop it." Cheap to build,
and it's the thing that lets a church actually run in Auto.

Every detection, fired or not, lands in a session **heard log** with its
transcript span, tier, and what the system did — including the ones it
deliberately suppressed as duplicates or already on screen. A church tuning
its way from Suggest to Auto needs evidence, and "here is everything it heard
last Sunday and what it would have done" is that evidence.

Two consequences that only became obvious while building it:

- The log **survives disarm**. §8 scopes the discard-on-disarm rule to audio
  and transcripts; a log wiped by the same click that ends the service could
  never be reviewed after the service, which is the entire use case. It holds
  references and short trigger spans, never transcripts, and the next `arm()`
  clears it.
- The log is **amendable**. The trust gate records its decision the moment it
  makes it, so an Auto-mode detection is logged as `live` before its grace
  period has run. If the operator cancels, the entry has to be corrected —
  a log claiming a verse went out when a human stopped it is worse than no
  log. `HeardReference` therefore carries a session `id` that the queue, the
  log and the signal all share, and `amendLog()` accepts only `cancelled`,
  `superseded` and `live` so the audit trail cannot be written to freely.
  (`superseded` is its own outcome: the preacher moving on before the window
  expired is not the same event as the operator intervening.)

---

## 6. Context tracking

The single highest-leverage piece of the whole system, and it's cheap.

Preachers state a full reference once and then work inside it for twenty
minutes: "verse nine", "look at verse twelve", "the next verse", "back up to
verse four." Without context these are unresolvable and the feature dies right
where the sermon actually lives.

`RefContext` holds current book, chapter, and last verse, updated on every
resolved reference, expiring after ~6 minutes of no scripture activity. It
also does two suppressions that matter more than they look:

- **De-dupe**: the same reference detected twice inside a short window (the
  preacher repeating himself, or a partial and final transcript both matching)
  fires once.
- **Already-live suppression**: if `ProjectionService::currentItem` is already
  that verse, do nothing. Re-sending an identical verse causes a transition
  flash on the audience screen for no reason.

---

## 7. Recognition and retrieval engines

Both run fully offline. Nothing this subsystem does touches the network.

### 7.1 Speech: whisper.cpp

With the low-end hardware target dropped for this feature (§9), `small.en`
q5_1 is the default (~190 MB) with `base.en` q5_1 (~57 MB) as the light
option. whisper.cpp has optional Vulkan/CUDA backends, which most machines
that would run this now have.

Whisper is not natively streaming, so something has to decide where one
utterance ends. We segment on speech pauses rather than fixed windows:
utterance boundaries are what both detection paths want anyway, and gating on
voice activity means we don't burn inference on silence.

**Phase 1 ships an energy gate, not Silero.** `VoiceGate` is RMS-with-
hysteresis plus a hangover timer — no model, no ONNX Runtime, and
deterministic enough to unit-test against synthetic PCM. Silero (~1.8 MB
ONNX) remains the intended upgrade and drops in behind the same interface.
The distinction that matters in a real sanctuary: energy cannot tell speech
from a slammed door or a bass note through the floor wedge, and Silero can.
Until we have that, `minSpeechMs` and the hangover are doing that work, and
they are the two constants to tune first if segmentation misbehaves on real
room audio.

`SpeechRecognizer` is an abstract interface with exactly one implementation at
first. That is deliberate and not speculative generality: the offline
constraint is a decision this church-software domain revisits, and a cloud or
Vosk backend must be a file, not a refactor.

### 7.2 Allusion: flat vector retrieval

Sentence embeddings over every verse, brute-force cosine against the rolling
transcript window.

- Model: `bge-small-en-v1.5` int8 via ONNX Runtime (~33 M params, 384 dim).
- Index: 31,102 verses × 384 dims. At int8 that's **~12 MB**, and a full scan
  is ~12 M multiply-accumulates — a couple of milliseconds with SIMD.

**No ANN index.** At Bible scale, flat brute force is fast enough, exact, and
has no build step, no recall cliff, and no tuning parameters. Reaching for
HNSW/FAISS here would be adding a dependency and a failure mode to solve a
problem we do not have.

Measured rather than assumed: a full scan of 31,102 × 384 int8 is **2.4 ms**,
and the int8 round trip costs **0.003** of cosine similarity — small enough
that the absolute threshold in §7.3 is measuring the sentences rather than the
compression. `test_allusion_index` asserts both.

Quantization is **per-vector**, not global. A 384-dimension unit vector has
components averaging about 1/√384 ≈ 0.05, so quantizing against a fixed
[-1, 1] range would leave roughly three usable bits per component. Scaling
each vector by its own largest component uses the full int8 range and costs
one float per verse (124 KB across the corpus).

The index file records **which model built it**, and loading refuses a
mismatch. This is not tidiness: two models' vector spaces are unrelated, so
searching one with the other's query returns high-scoring, entirely arbitrary
verses — a failure that looks exactly like a working system.

### 7.2.1 The embedder

`OnnxEmbedder` runs `bge-small-en-v1.5` through ONNX Runtime 1.28.0, behind
`CRATER_WITH_EMBEDDINGS` (OFF by default, same reasoning as
`CRATER_WITH_WHISPER`). The runtime is fetched at configure time and pinned by
**SHA-256**, not by version tag — this is a binary we execute, and a tag can be
re-pointed where a content hash cannot. The model itself is never fetched: it
is operator-supplied, like the whisper model, because nothing in this
subsystem may touch the network at run time (§8).

Two details are taken from the model's own config rather than from convention,
and both would have failed silently:

- **CLS pooling, not mean.** `1_Pooling/config.json` sets
  `pooling_mode_cls_token: true`. Mean pooling is the more common convention
  and what most example code does. Using it here would produce perfectly
  well-formed 384-dimension unit vectors in a space unrelated to the index's,
  and every query would still return a confident, arbitrary verse.
- **No query-instruction prefix.** BGE wants one for short-query-to-long-
  passage retrieval. Ours is sentence-to-sentence. Consistency matters more
  than the choice anyway: the index is built through this same class, so both
  sides of every comparison are produced identically by construction.

Tokenization is a hand-written `WordPieceTokenizer` against the bundled
`bert-base-uncased` vocabulary (30,522 tokens, shipped as a Qt resource so a
model can never be paired with the wrong vocab). The alternative was a second
native dependency the size of the inference runtime, to do string splitting.
Its tests pin **exact token ids**, computed independently before the
implementation ran, because a wrong tokenizer does not error — it hands the
model plausible ids and gets back a vector pointing nowhere.

**Measured against the real model** (`test_onnx_embedder`):

| | cosine |
|---|---|
| paraphrase → the verse it paraphrases | 0.75, 0.79 |
| paraphrase → a plausible but wrong verse | 0.62 |
| ordinary announcements → nearest verse | 0.47 |
| query embedding cost | ~47 ms |

That distribution is where §7.3's thresholds come from, and it is why they are
not guesses. The full path — real embeddings, int8 quantization, flat scan,
all three gates — resolves the §2 paraphrase example to John 3:16 at tier
`possible`, and stays silent on four different announcements.

**What is still missing: the shipped index.** Everything above runs against
indexes built in-process during tests. Generating the real
31,102-verse `.crai` and shipping it beside the Bible DB is the remaining
step, and until it exists `AllusionMatcher::isReady()` is false and
`NarrationService` skips the pass entirely.

Embeddings are computed once at build time and shipped beside the Bible DB.
Only **one** reference translation is embedded — identification returns verse
*coordinates*, and the operator's chosen translation supplies the text for
display. Embedding all translations would multiply the index for no gain.

### 7.3 Why allusion matching needs a hard distinctiveness gate

Sermons are saturated with biblical language. "We need to love one another"
is semantically adjacent to dozens of verses. Raw top-1 cosine would fire
constantly.

Three gates, all required:

1. **Absolute threshold** on top-1 similarity.
2. **Margin test**: top-1 must clearly beat top-2. If fifty verses are all
   equally close, the phrase is generic rather than a quotation of any one
   of them.
3. **Content floor**: ≥5 non-stopword tokens in the window. Short phrases
   carry too little signal.

Even clearing all three, the result is tier **Possible**, which per §5 never
fires on its own.

---

## 8. Privacy and security — amendment to `architecture.md` §5

This subsystem adds a threat surface the original security model has no entry
for: **a continuously open microphone in a church building.**

A sanctuary mic hears more than the sermon. It hears the pre-service
conversation, the prayer request whispered at the altar, the counselling
conversation nobody realized was in range. This is materially more sensitive
than any data Crater has handled to date, and it justifies stricter defaults
than a normal feature.

**Rules, non-negotiable:**

- **Audio never touches disk.** Fixed-size ring buffer, overwritten
  continuously. No recording, no cache, no "debug mode" that writes WAVs.
  If we ever need capture for debugging, it is a separate build, not a flag.
- **Audio never leaves the machine.** No network calls in this subsystem at
  all. This is what makes the offline requirement (§7) a security property and
  not just a convenience.
- **Explicit arming only.** The mic opens on an operator action and never on
  app start, schedule load, or go-live. There is no configuration that makes
  it auto-arm.
- **Always-visible hot indicator.** When the mic is open it is obvious from
  across the room, in both the operator console and any output-monitor UI.
  Not a small icon in a corner.
- **Transcripts are session-scoped**, held in memory, discarded on disarm.
  The heard log (§5) retains detected *references* and their short trigger
  spans, not the full transcript.

This also extends §5.2: the v1.1 remote-control server must never expose
narration transcript text, and `arm()` is a write-command requiring PIN.

---

## 9. Performance — amendment to `architecture.md` §6

The original budget (Intel HD 4000, 4 GB RAM, <150 MB resident) does not
survive contact with local speech recognition, and we're not going to pretend
otherwise.

**Narration is an opt-in feature with its own budget, applied only while
armed.** The base app budget in §6 is unchanged and still governs everything
else. Crater with narration disarmed must still hit every number in §6.

| Metric | Budget |
|---|---|
| Additional resident memory, armed (`small.en`) | < 550 MB |
| Additional resident memory, armed (`base.en`) | < 300 MB |
| Speech to on-screen, Certain tier | < 2.5 s |
| **Main-thread** detector work per utterance | < 20 ms |
| Quotation pass (own thread) | < 250 ms |
| Allusion index scan | < 5 ms |
| Idle CPU while armed, no speech (VAD gating) | < 3% of one core |

### 9.1 Why the quotation pass has its own thread

The detector budget originally said "20 ms per utterance" without qualifying
which thread. Measurement made that untenable and the split above is the
honest version.

A single FTS5 trigram AND over a real 285 MB library of fourteen translations
costs **1–48 ms**, depending entirely on how common the phrase's words are:
`begotten` alone is 2 ms, `god` alone is 125 ms, and FTS5's own planner
already intersects rarest-first, so there is no query rewriting left to
harvest. A full quotation pass measures **~63 ms**. Trimming windows to their
rarest words was tried and bought almost nothing, because under a *trigram*
tokenizer a longer word costs more postings to intersect, not fewer.

On the UI thread that is up to a tenth of a second of frozen console every
time the preacher finishes a sentence. So `NarrationService` runs the
quotation pass on its own thread, over **its own SQLite connection** — we
build SQLite with `SQLITE_THREADSAFE=2` (one connection per thread) and
prepared statements are unprotected even under `FULLMUTEX`, so sharing the UI
thread's `BibleService` would be a data race. Two read-only connections to one
file is what SQLite is for, and the second costs a file handle.

Citation stays inline: it is text parsing plus at most one indexed
single-verse lookup, comfortably inside architecture.md §3's 5 ms sync
threshold.

`test_quotation_matcher` asserts the measured figure against a regression
bound rather than a target, so a pathological regression is caught without
pretending an FTS scan belongs on the UI thread.

Crater must **refuse to arm** rather than degrade, if the machine can't hold
the budget: no model loaded, no swap thrash on a 4 GB machine mid-sermon. The
low-end target machines still run Crater. They just don't run narration, and
they say so plainly.

---

## 10. Phasing

Ordered so that the highest-risk, highest-value component is testable first
and needs no audio hardware, no models, and no UI.

| Phase | Scope | Verifiable by |
|---|---|---|
| **0** | `SpokenNumbers`, `CitationDetector`, `RefContext`, `HeardReference` | `core/tests/test_reference_detector.cpp` against transcript fixtures |
| **1** | `SpeechRecognizer` interface + `NullRecognizer` + whisper.cpp + `VoiceGate` + `AudioRing` + `AudioTap` | `test_voice_gate` for the ring and the gate; live mic for the tap |
| **2** | `NarrationService`, `TrustGate`, mic toggle, hot-mic bar, heard queue, all three modes wired | `test_narration_service` for the gate matrix and routing; operator console |
| **3** | `QuotationMatcher` over existing FTS, on its own thread (§9.1) | `test_quotation_matcher`: fixture corpus for the gate logic, then the real 31,102-verse index for precision and latency |
| **4** | `AllusionIndex`, `AllusionMatcher`, `WordPieceTokenizer`, `OnnxEmbedder` — **index generation still to do** (§7.2.1) | `test_allusion_index` (quantization, format, scan cost, gates), `test_wordpiece_tokenizer` (exact ids), `test_onnx_embedder` (real model, real geometry, end to end) |
| **5** | Auto mode, grace period, heard log, settings page | `test_narration_service` for log amendment and lifetime; a full service run in Auto with the log reviewed after |

Phase 0 carries most of the design risk and none of the dependencies, so it
goes first and it goes in with tests.

---

## 11. Known-hard cases

Recorded now so they're deliberate decisions later rather than surprises.

- **"Psalm one nineteen"** — Psalm 119, or Psalm 1:19? Psalm 119 exists and
  Psalm 1 has only 6 verses, so canonical validation resolves this one. The
  general rule: when a parse yields a chapter:verse that doesn't exist,
  re-parse as a composed number before giving up.
- **"First John" vs "the first John…"** — the ordinal cue is ambiguous with
  ordinary speech. Requires numeric structure or an intent cue to fire.
- **Responsive reading** — congregation reading aloud with the preacher is
  extremely clean quotation input, and will fire the quotation path
  aggressively. Already-live suppression (§6) handles most of it.
- **Multiple translations open** — the preacher quotes the ESV while the
  operator has KJV selected. Identification uses the embedded reference
  translation and returns coordinates, so display follows the operator's
  selection regardless.
- **Non-English services** — out of scope for v1 and should be stated as such
  publicly. `small.en` is English-only by construction, and the allusion index
  is English-embedded. A multilingual path is a different model and a
  different index, not a setting.
