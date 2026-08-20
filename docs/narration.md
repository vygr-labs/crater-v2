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
string, then handed to the existing `BibleService::parseReference`.

The plan here was to reuse `crater::import::lookupBook` wholesale, on the
grounds that its exact / alias / prefix / subsequence / edit-distance tiers are
exactly the tolerance a mangled transcript needs. That turned out to be half
right, and the half that was wrong matters. `lookupBook` is tuned for an
operator at a search box, where a wrong guess costs one keystroke: it accepts
subsequences and edit distance up to three, which over sermon prose makes "in"
a match for 1 K**in**gs and "page" a match for Jude at distance three. Run over
arbitrary speech it answers for nearly every clause.

So the scanner uses a strict spoken-form table, and fuzzy matching comes back
only where surrounding structure has established intent —
`lookupBookNearMiss()`, which drops the prefix and subsequence tiers entirely,
takes a hard distance cap (one edit under eight characters, two above), matches
canonical names only, and refuses ties. See §4.3.1 for what forced this.

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

### 4.3.1 When the recognizer mishears the book

The first live microphone run transcribed "turn with me to john chapter 3 verse
16" as *"turn with me to **join** chapter 3 verse 16"*. One substituted letter,
word error rate 11.1%, and the most-cited verse in English preaching stopped
being detected at all.

The obvious fix — loosen the rescue's five-character floor — is the wrong one.
Between the cue and the chapter, four-letter words that `lookupBook` will
happily resolve are everywhere: "page" reaches Jude at distance three, "slide"
and "point" reach others. Loosening the length while keeping distance-three
tolerance trades one missed citation for a class of fabricated ones, and a
fabricated reference at `certain` tier is the worst output this subsystem can
produce.

What licenses a guess is **structure on both sides**, not a looser matcher:

- an intent cue immediately before the candidate ("turn with me to …"), and
- a chapter keyword, verse keyword, or number immediately after it, and
- a distance cap of one edit at this length, via `lookupBookNearMiss` rather
  than `lookupBook`, and
- the token is not a function word, and
- the exact table has already declined it.

All five together. "join" between "turn with me to" and "chapter" satisfies
them; "page" in "turn to page four" satisfies four of five and fails on the
distance cap, which is the only one that separates them.

**Both rescue paths emit `high`, never `certain`.** A book name we had to guess
at is not the evidence a book name we read is, and §5's rule that tier is a
property of the path makes that a tier difference rather than a score
adjustment. The practical consequence is the whole safety story here: at `high`
even Auto mode stages and stops, so the cost of a wrong guess is an operator
glancing at a wrong chip rather than a congregation reading one. This also
downgrades the pre-existing "phillipians chapter four" rescue, which had been
emitting `certain` on the same kind of evidence.

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

### 7.1.1 Suggestions while the sentence is still being spoken

Pause-based segmentation is right for accuracy and, on its own, unusable
live. The gate closes an utterance after 600 ms of silence with a 15 s
backstop, so a preacher in full flow says "turn with me to John three sixteen"
and the operator sees nothing until they stop for breath. The first live run
reported exactly that: *"I want it to bring suggestions as we talk."*

So the utterance in progress is re-transcribed on a cadence — `transcribeInterim()`
emits `partial()`, and detection runs on the result. Three constants
(`NarrationService.cpp`):

| | | |
|---|---|---|
| `kInterimMs` | 900 | cadence. Was 1200 while interim passes ran on the operator's full model; the draft model below removed that as the binding constraint |
| `kInterimMinMs` | 900 | skip passes over a word or two, where spurious matches come from |
| `kInterimWindowMs` | 5000 | tail re-read. Longer than any single spoken citation, short enough that the hypothesis is about the phrase being spoken now |

Interim work shares the `kMaxInFlight` budget with real utterances and
deliberately yields to them: a partial that crowded out the finished utterance
behind it would trade a result the operator can act on for a guess that is
about to be superseded. The same verse is normally found twice — once on a
partial, once on the final — and the 20 s de-duplication window collapses them.

**A partial may never be projected.** Not "should not": the trust gate takes
`fromPartial` and caps the outcome at `staged`, so the single cell that would
have gone live (certain × auto) becomes staged and every other cell is
untouched. "Turn to John three" identifies John 3:1 with complete confidence
and is wrong the moment the next word is "sixteen"; Auto mode exists to remove
the human from the loop, which is precisely why it must not be handed an
unfinished sentence. Asserted over the whole tier × mode matrix in
`test_narration_service`.

### 7.1.1.1 Two models, because the two passes want opposite things

The first version ran both passes on the operator's chosen model, and the
second live run reported the predictable result: *"the delay is annoying."*

The two passes are not the same job. A finished utterance is the answer an
operator acts on and has to be right. An in-progress hypothesis is superseded a
second later and can never project, so its only real failure mode is arriving
too late to be a hypothesis at all. Running the careful model on both makes the
fast path as slow as the careful one and buys nothing.

So `SpeechRecognizer::loadDraft()` takes an optional second model that answers
`transcribeInterim()` only. `NarrationService::draftModelPath()` discovers it
beside the main model, scanning candidates in speed order and **stopping at the
operator's own model** — reaching it means theirs is already at least that
fast, and a draft slower than the real thing would spend a second model's
memory to produce the guess later than the answer.

Two contexts, one worker thread. Serializing the passes is deliberate: a draft
pass stealing cores from the final pass it exists to precede would be
self-defeating.

The other half is `audio_ctx`. Whisper pads every input to a 30-second mel
spectrogram before the encoder runs, so a two-second clip costs very nearly
what a thirty-second one does — which is why shortening `kInterimWindowMs`, on
its own, buys much less than it looks like it should. `audio_ctx` caps how much
of that padded window the encoder attends to and is the only parameter that
makes encoder cost track the audio actually present. Interim only; the final
pass keeps the full context.

Measured on a 15 s desk-microphone recording of "turn with me to John chapter 3
verse 16", i7-8750H, CPU only, 11 threads:

| config | wall clock | WER |
|---|---|---|
| `small.en`, final pass (unchanged) | 13.8 s | 11.1% |
| `base.en`, final pass | 13.5 s | 44.4% |
| `base.en`, interim params (`audio_ctx`, single segment, no temperature fallback) | 2.0 s | 22.2% |
| `small.en` + `base.en` draft, interim pass — **shipping** | 3.1 s | 22.2% |

The interim parameters alone take the same model from 13.5 s to 2.0 s *and*
improve its accuracy, because the temperature fallback they disable was
spending its retries on the noise floor. Net effect: the operator sees a
suggestion roughly 4.5x sooner, at about double the word error rate, on a
hypothesis that is corrected within seconds and could never have projected.

### 7.1.2 Level, and why the first live run heard the wrong words

Whisper is trained on roughly normalized speech. A congregation microphone six
feet from a preacher does not deliver that — a laptop array at conversational
distance lands near -30 dBFS peak, about a sixth of full scale — and the model
answers a quiet prompt with confident invention rather than silence. That is
what "it's not picking my words correctly" turned out to mean.

`WhisperRecognizer` now scales every utterance to a 0.90 peak before
inference. Plain gain, one factor across the buffer, so nothing about the
speech changes except how loud it is. It attenuates too, since a clipped desk
mic is no better than a quiet lid array. Gain is capped at 25x so a near-silent
buffer cannot be blown up to full scale.

Both passes run through one function so a change to the audio handling cannot
land on the final pass and miss the interim one.

**The silence floor is the expensive part.** The first version of this gate
read the loudest single sample and skipped buffers peaking under about -48
dBFS. A door click or a plosive clears that easily while carrying no speech at
all, so a silent buffer with one transient in it was licensing 25x gain on
ventilation noise — and whisper was dutifully finding words in the result.

What that costs is not a wrong transcript, it is the worst latency case in the
system. Measured on the same recording: five seconds of a quiet office took
**4.8 s idle and 18-26 s under load** to return an empty string, and ten
seconds of it came back `"(clippers buzzing)"`. Every one of those seconds is a
second the recognizer thread is unavailable for the sentence actually being
spoken, and with `kMaxInFlight` at 2 it is also where dropped utterances come
from. A large part of "the delay is annoying" was this, not model speed.

The fix is RMS rather than peak, and an early return rather than a skipped
amplification — there are no words in a quiet room, and confirming that is not
worth twenty seconds of the only recognizer thread. Levels from that recording:

| window | peak | RMS | heard | before | after |
|---|---|---|---|---|---|
| 5 s, no speech | -49.1 dBFS | -69.6 dBFS | — | 4.8 s | 0.00 s |
| 10 s, no speech | -33.9 dBFS | -65.6 dBFS | `(clippers buzzing)` | 2.6 s | 0.00 s |
| 15 s, with speech | -18.2 dBFS | -40.5 dBFS | the sentence | 1.9 s | 1.9 s |

Peak separates those windows by 15 dB and misorders them; RMS separates them by
25 dB and orders them correctly. `kSpeechRmsFloor` sits in the middle of that
gap at about -55 dBFS. It is deliberately far looser than VoiceGate's -38 dBFS
speech threshold, so anything the gate was confident enough to forward passes
comfortably — this catches what the gate let through, not what it decided.

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

Which translation is therefore a free choice, and `build_allusion_index
--compare` measures it rather than assuming. Mean cosine from five spoken
paraphrases to the verses they paraphrase, across a real fourteen-translation
library:

| | |
|---|---|
| GNT / CEV / NLT / NIV | 0.854 / 0.852 / 0.850 / 0.849 |
| NASB2020 / NKJV / AMPC / ESV / RSV / TLV | 0.826 – 0.843 |
| **KJV** / ASV | **0.780** / 0.780 |
| MSG / TPT | 0.751 / 0.726 |

Two things worth keeping. Modern translations beat the King James by about
0.07, which is a real margin: the model was trained on contemporary English
and preachers paraphrase in contemporary English, so archaic wording costs
distance on both sides of the comparison. And the loose paraphrase editions
score *worst*, not best — MSG and TPT paraphrase in their own idiom, which is
not the idiom anyone reaching for that verse would use.

One caveat this table cannot show, because it only measures true positives:
being closer to modern speech pulls in the announcements too. Measured end to
end in §7.3.2, the NKJV index leaks false positives at the same settings where
the KJV index leaks none. Higher similarity to paraphrase is not the same as
better separation, and separation is what the gates need.

The shipped index is **KJV** regardless, for a reason the numbers do not
capture: it is public domain. An index holds int8 vectors and coordinates
rather than text, but "is a derived vector index a redistributable work?" is a
licensing question, not an engineering one. KJV also happens to be what §7.3's
thresholds were calibrated against, so the two are consistent. Switching is
one flag (`--translation`) and one recalibration if that question is ever
answered.

### 7.3 Why allusion matching needs a hard distinctiveness gate

Sermons are saturated with biblical language. "We need to love one another"
is semantically adjacent to dozens of verses. Raw top-1 cosine would fire
constantly.

Three gates, all required:

1. **Content floor**: ≥5 non-stopword tokens, checked **per window** rather
   than over the whole utterance.
2. **Absolute threshold** on top-1 similarity — on the *top hit only*.
3. **Cluster size**: how many verses sit within 0.04 of the best hit. Membership
   is **relative only**; it deliberately does not re-apply gate 2.

Gates 2 and 3 answer different questions and must not be spent on each other.
Gate 2 asks "is this utterance near scripture at all", which is absolute. Gate 3
asks "which verses answer it *together with* the best one", which is meaningful
only relative to that best one. Requiring cluster members to also clear the
absolute threshold collapsed the 0.04 window to nothing whenever the top hit sat
near it — see §7.3.1.

Even clearing all three, the result is tier **Possible**, which per §5 never
fires on its own.

### 7.3.1 What calibration on the real index actually showed

The first version of this section had a *margin* test — top-1 must beat top-2
— and thresholds measured against a four-verse index. Both were wrong, and
`build_allusion_index --calibrate` against the real 31,102-verse index is what
showed it.

**The absolute threshold cannot do this job alone.** Top-1 scores for eight
real paraphrases and ten real church announcements:

```
paraphrases       0.707 .. 0.891
ordinary speech   0.580 .. 0.775
```

They **overlap**. That is arithmetic rather than a tuning failure: the nearest
neighbour of any sentence rises as the corpus grows, so "how close is the best
match" stops discriminating once there are thirty thousand candidates. Any
threshold calibrated on a toy index is wrong on the real one — ours was 0.68,
which would have fired on "there are envelopes in the back if you would like
to give today" (0.719 → 1 Peter 5:14).

**Cluster size is what separates them.** A correctly-resolved paraphrase sits
alone or near a few verses that genuinely say the same thing; ordinary speech
scores high only by being vaguely near a crowd:

| | score | cluster | |
|---|---|---|---|
| Philippians 4:13 | 0.891 | 1 | "i can handle anything because christ gives me strength" |
| Genesis 1:1 | 0.885 | 1 | "in the very beginning god made the heavens and the earth" |
| 1 John 1:9 | 0.863 | 1 | "if we admit what we have done wrong he will forgive us" |
| Romans 8:28 | 0.822 | 2 | "everything works out for good for the people who love god" |
| Psalms 23:1 | 0.786 | 3 | "the lord takes care of me like a shepherd" |
| 1 John 4:9 | 0.779 | 7 | "god loved us so much that he sent his own son to die" |
| Revelation 22:21 | 0.775 | 8+ | *"good morning church, wonderful to see everybody"* |
| Psalms 66:8 | 0.755 | 8+ | *"thank the worship team for leading us"* |

`--calibrate` probes eight deep, so a cluster of 8 means "eight or more" — the
matcher itself probes 16 precisely so a seven-verse cluster is a measurement
rather than a guess. A cluster that fills the probe is rejected, since k
near-ties cannot be told apart from k-and-counting.

**The two gates were fighting each other.** At `minScore 0.78` and
`maxCluster 3` the result was 5 of 8 paraphrases and 0 of 10 announcements, and
§2's own flagship example — "God loved us so much that he sent his own son to
die" — was among the misses. Raising `maxCluster` alone changed nothing, which
is what exposed the real bug: cluster *membership* also required each member to
clear `minScore`, so with a top hit at 0.779 and a threshold at 0.780 the 0.04
window admitted a band 0.001 wide. Six genuine co-answers were filtered out
before anything counted them, and the crowd gate was measuring a crowd of one.

Making membership relative-only fixed it, and made the path **stricter** on
noise rather than looser: announcement clusters grew too, so they are now
rejected by crowd size at thresholds where they previously slipped through.

**The absolute threshold is a floor, not the discriminator.** Sweeping it with
`--gates --min-score` produces one flat plateau:

| minScore | paraphrases | announcements |
|---|---|---|
| 0.650 | 6/8 | **3/10** |
| 0.680 | 6/8 | **2/10** |
| 0.700 | 6/8 | **1/10** |
| 0.720 – 0.778 | 6/8 | 0/10 |
| 0.780 and up | **5/8** | 0/10 |

Everything inside 0.720–0.778 behaves identically, because inside it gate 3
decides every case. The edges are sharp: below 0.720 announcements start
clearing gate 2, and at 0.780 the gospel paraphrase dies on its 0.779 top hit.
**0.75** is the midpoint, ~0.03 clear of both. A value tucked just inside one
edge is a value that moves the next time the index is rebuilt.

**`maxCluster` is 7 because the canon says so.** The gospel paraphrase resolves
to 1 John 4:9, Romans 5:8, John 3:16, Romans 5:10, 1 John 4:10, 1 John 4:11 and
2 Thessalonians 2:16. Five are squarely what was paraphrased; the last two are
adjacent. The claim is therefore not "seven right answers" but "the right verse
is in the offered set, and the set is short enough to scan" — the correct bar
for a queue. Seven is also structurally safe rather than luckily safe: the
announcements that have to be rejected cluster at **eight or more**, so the
boundary sits in a real gap instead of splitting a continuum.

The asymmetry throughout is deliberate: this tier populates a suggestion queue,
where a wrong entry costs the operator's trust and a missing one costs nothing
they would notice.

**The two remaining misses.** "Do not be anxious about tomorrow" (Matthew 6:34)
and "God has plans to give you a future and a hope" (Jeremiah 29:11) still do
not fire at any threshold — lowering `minScore` to 0.65 does not recover them,
so their tops are crowded rather than distant. Catching them needs a better
sentence encoder, not a looser gate.

### 7.3.2 The operating point does not transfer between translations

Everything above is measured against `allusion-KJV.crai`. Running the identical
config against `allusion-NKJV.crai` gives **2 of 10 false positives**: "good
morning church, it is wonderful to see everybody here today" returns Titus 3:15,
1 Peter 5:14, Philippians 4:21 and 2 Corinthians 13:14, and the thanks-to-the-
worship-team line returns seven verses.

| | KJV | NKJV |
|---|---|---|
| `minScore 0.75`, `maxCluster 7` | 6/8, **0**/10 | 6/8, **2**/10 |
| `minScore 0.75`, `maxCluster 3` | 5/8, 0/10 | 5/8, 0/10 |
| `minScore 0.82`, `maxCluster 7` | 4/8, 0/10 | 4/8, 0/10 |

Both parameters move, and no single pair is best for both. The cause is the
same property §7.2 measured as an advantage: the NKJV is modern English, so a
modern paraphrase sits closer to it — but so does a modern *announcement*.
Greeting a congregation is genuinely near "Greet those who love us in the
faith" once both are in contemporary wording. The KJV's archaic register is a
poor match for paraphrase and an even poorer one for church admin, and that gap
is what the gates have been living on. §7.2's conclusion therefore needs the
qualifier it did not have: a modern translation raises recall and lowers
precision together.

**Consequence, and the shape of the fix.** Gate thresholds are a property of
*the index*, not of the matcher, so they belong in the `.crai` header beside the
model id — calibrated when the index is built, applied when it is loaded. That
is a format change and is not done yet. Until it is, only the calibrated KJV
index is discoverable; an uncalibrated index must not be left in the models
directory where `allusionIndexPath()` will prefer it over the fallback.

This costs nothing in what the operator reads. Detection returns coordinates and
display follows the operator's own translation selection (§11), so a KJV-built
index projects NKJV text exactly as before.

**The margin test is gone**, and its removal is the reason cluster size
exists. A top-1-versus-top-2 gap cannot tell three correct co-answers from
three meaningless near-ties, because a gap is not what distinguishes them.
Crowd size is — which was always the stated intent here ("if fifty verses are
all equally close…"); the margin was a crude proxy that failed at exactly the
moment it mattered.

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
| Draft model, when one is found (§7.1.1.1) | + ~110 MB (`base.en` q5_1: 59 MB weights, rest compute buffers) |
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
