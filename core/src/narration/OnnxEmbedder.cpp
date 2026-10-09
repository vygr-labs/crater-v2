#include "narration/OnnxEmbedder.h"

#include <QFileInfo>
#include <QThread>

#ifdef CRATER_WITH_EMBEDDINGS
#include <onnxruntime_cxx_api.h>
#endif

#include <algorithm>
#include <cmath>

namespace crater::narration {

namespace {

// The vocabulary is bundled with crater-core, so a model can never be paired
// with the wrong one — see the qt_add_resources block in core/CMakeLists.txt.
constexpr const char* kVocabResource = ":/narration/bge-small-en-v1.5-vocab.txt";

// Written into every index file and checked on load. Bump it if the model,
// the pooling, or the tokenization ever changes, so an index built by the old
// combination is refused rather than silently searched with the new one.
constexpr const char* kModelId = "bge-small-en-v1.5/cls/wordpiece-v1";

constexpr int kDims   = 384;   // bge-small's hidden_size
constexpr int kMaxLen = 512;   // its max_position_embeddings

}  // namespace

#ifdef CRATER_WITH_EMBEDDINGS

struct OnnxEmbedder::Impl
{
    Ort::Env env{ ORT_LOGGING_LEVEL_WARNING, "crater-narration" };
    std::unique_ptr<Ort::Session> session;
    Ort::AllocatorWithDefaultOptions alloc;

    WordPieceTokenizer tok;

    // Discovered from the graph rather than hard-coded. Exporters disagree
    // about names and ordering, and a wrong guess would either throw or —
    // worse — feed the attention mask in as token ids.
    std::vector<std::string> inputNames;
    std::vector<std::string> outputNames;
    int idsIdx = -1, maskIdx = -1, typeIdx = -1;
    int hiddenOut = -1;

    int threads = 1;
};

OnnxEmbedder::OnnxEmbedder()
    : m_impl(std::make_unique<Impl>())
{
    // Leave a core for the UI and the projection renderer, same reasoning as
    // WhisperRecognizer: dropped frames on the audience screen cost more than
    // a few extra milliseconds of embedding.
    m_impl->threads = std::max(1, QThread::idealThreadCount() - 1);
}

OnnxEmbedder::~OnnxEmbedder() { unload(); }

bool OnnxEmbedder::load(const QString& modelPath, QString* error)
{
    unload();

    const QFileInfo fi(modelPath);
    if (!fi.exists() || !fi.isFile()) {
        if (error) *error = QStringLiteral("Embedding model not found at %1").arg(modelPath);
        return false;
    }

    if (!m_impl->tok.loadVocab(QString::fromLatin1(kVocabResource), error))
        return false;

    try {
        Ort::SessionOptions opts;
        opts.SetIntraOpNumThreads(m_impl->threads);
        opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

        m_impl->session = std::make_unique<Ort::Session>(
            m_impl->env, modelPath.toStdWString().c_str(), opts);

        const size_t nIn  = m_impl->session->GetInputCount();
        const size_t nOut = m_impl->session->GetOutputCount();

        for (size_t i = 0; i < nIn; ++i) {
            auto n = m_impl->session->GetInputNameAllocated(i, m_impl->alloc);
            m_impl->inputNames.emplace_back(n.get());
        }
        for (size_t i = 0; i < nOut; ++i) {
            auto n = m_impl->session->GetOutputNameAllocated(i, m_impl->alloc);
            m_impl->outputNames.emplace_back(n.get());
        }

        for (int i = 0; i < int(m_impl->inputNames.size()); ++i) {
            const std::string& n = m_impl->inputNames[size_t(i)];
            if (n == "input_ids")           m_impl->idsIdx  = i;
            else if (n == "attention_mask") m_impl->maskIdx = i;
            else if (n == "token_type_ids") m_impl->typeIdx = i;
        }
        if (m_impl->idsIdx < 0 || m_impl->maskIdx < 0) {
            if (error) *error = QStringLiteral(
                "This ONNX model does not look like a BERT encoder: it has no "
                "input_ids / attention_mask inputs.");
            unload();
            return false;
        }

        // CLS pooling reads the first token of the last hidden state, so the
        // output we want is the 3-D one. "last_hidden_state" by name where
        // present; otherwise the first rank-3 output. A model exposing only
        // "pooler_output" (rank 2) is the wrong export for this — pooler
        // output is a trained dense+tanh head, not the CLS embedding BGE
        // normalizes, and would put every vector in a different space.
        for (int i = 0; i < int(m_impl->outputNames.size()); ++i) {
            if (m_impl->outputNames[size_t(i)] == "last_hidden_state") { m_impl->hiddenOut = i; break; }
        }
        if (m_impl->hiddenOut < 0) {
            for (int i = 0; i < int(m_impl->outputNames.size()); ++i) {
                const auto info = m_impl->session->GetOutputTypeInfo(size_t(i));
                const auto shape = info.GetTensorTypeAndShapeInfo().GetShape();
                if (shape.size() == 3) { m_impl->hiddenOut = i; break; }
            }
        }
        if (m_impl->hiddenOut < 0) {
            if (error) *error = QStringLiteral(
                "This ONNX model has no sequence output to pool from; it may be a "
                "pooler-only export, which is not the embedding BGE normalizes.");
            unload();
            return false;
        }
    } catch (const Ort::Exception& e) {
        if (error) *error = QStringLiteral("ONNX Runtime could not load the model: %1")
                                .arg(QString::fromUtf8(e.what()));
        unload();
        return false;
    }

    return true;
}

void OnnxEmbedder::unload()
{
    m_impl->session.reset();
    m_impl->inputNames.clear();
    m_impl->outputNames.clear();
    m_impl->idsIdx = m_impl->maskIdx = m_impl->typeIdx = -1;
    m_impl->hiddenOut = -1;
}

bool    OnnxEmbedder::isReady()    const { return m_impl->session != nullptr; }
int     OnnxEmbedder::dimensions() const { return kDims; }
QString OnnxEmbedder::modelId()    const { return QString::fromLatin1(kModelId); }

QList<float> OnnxEmbedder::embedOne(const QString& text)
{
    const auto all = embed(QStringList{ text });
    return all.isEmpty() ? QList<float>() : all.first();
}

QList<QList<float>> OnnxEmbedder::embed(const QStringList& texts)
{
    QList<QList<float>> out;
    if (!isReady()) return out;
    out.reserve(texts.size());

    const Ort::MemoryInfo mem =
        Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    for (const QString& text : texts) {
        const auto enc = m_impl->tok.encode(text, kMaxLen);
        if (enc.isEmpty()) { out.append(QList<float>()); continue; }

        const int64_t seq = int64_t(enc.ids.size());
        const std::array<int64_t, 2> shape{ 1, seq };

        // Copied into vectors ORT can take a non-const pointer to. QList's
        // storage would work, but borrowing it would tie tensor lifetime to
        // container details that are not worth relying on.
        std::vector<int64_t> ids(enc.ids.begin(), enc.ids.end());
        std::vector<int64_t> mask(enc.attentionMask.begin(), enc.attentionMask.end());
        std::vector<int64_t> types(enc.tokenTypeIds.begin(), enc.tokenTypeIds.end());

        try {
            std::vector<const char*> inNames;
            std::vector<Ort::Value>  inValues;

            const int maxIdx = std::max({ m_impl->idsIdx, m_impl->maskIdx, m_impl->typeIdx });
            for (int i = 0; i <= maxIdx; ++i) {
                if (i == m_impl->idsIdx) {
                    inNames.push_back(m_impl->inputNames[size_t(i)].c_str());
                    inValues.push_back(Ort::Value::CreateTensor<int64_t>(
                        mem, ids.data(), ids.size(), shape.data(), shape.size()));
                } else if (i == m_impl->maskIdx) {
                    inNames.push_back(m_impl->inputNames[size_t(i)].c_str());
                    inValues.push_back(Ort::Value::CreateTensor<int64_t>(
                        mem, mask.data(), mask.size(), shape.data(), shape.size()));
                } else if (i == m_impl->typeIdx) {
                    inNames.push_back(m_impl->inputNames[size_t(i)].c_str());
                    inValues.push_back(Ort::Value::CreateTensor<int64_t>(
                        mem, types.data(), types.size(), shape.data(), shape.size()));
                }
            }

            const char* outName = m_impl->outputNames[size_t(m_impl->hiddenOut)].c_str();
            auto result = m_impl->session->Run(Ort::RunOptions{ nullptr },
                                               inNames.data(), inValues.data(),
                                               inValues.size(), &outName, 1);
            if (result.empty()) { out.append(QList<float>()); continue; }

            const auto info  = result.front().GetTensorTypeAndShapeInfo();
            const auto rshape = info.GetShape();
            if (rshape.size() != 3 || rshape[2] != kDims) { out.append(QList<float>()); continue; }

            const float* data = result.front().GetTensorData<float>();

            // CLS pooling: token 0 of the sequence. NOT a mean over tokens —
            // see the header for why that distinction is load-bearing.
            QList<float> vec;
            vec.resize(kDims);
            for (int d = 0; d < kDims; ++d) vec[d] = data[d];

            // L2 normalize, which is both what BGE specifies and what
            // AllusionIndex assumes when it treats a dot product as cosine.
            double norm = 0.0;
            for (const float v : vec) norm += double(v) * double(v);
            norm = std::sqrt(norm);
            if (norm > 0.0)
                for (float& v : vec) v = float(double(v) / norm);

            out.append(std::move(vec));
        } catch (const Ort::Exception&) {
            out.append(QList<float>());
        }
    }

    return out;
}

#else  // !CRATER_WITH_EMBEDDINGS

struct OnnxEmbedder::Impl { };

OnnxEmbedder::OnnxEmbedder() : m_impl(std::make_unique<Impl>()) {}
OnnxEmbedder::~OnnxEmbedder() = default;

bool OnnxEmbedder::load(const QString&, QString* error)
{
    if (error) {
        *error = QStringLiteral(
            "This build of Crater was compiled without semantic search "
            "(configure with -DCRATER_WITH_EMBEDDINGS=ON).");
    }
    return false;
}

void    OnnxEmbedder::unload() {}
bool    OnnxEmbedder::isReady()    const { return false; }
int     OnnxEmbedder::dimensions() const { return kDims; }
QString OnnxEmbedder::modelId()    const { return QString::fromLatin1(kModelId); }

QList<QList<float>> OnnxEmbedder::embed(const QStringList&) { return {}; }
QList<float>        OnnxEmbedder::embedOne(const QString&)  { return {}; }

#endif  // CRATER_WITH_EMBEDDINGS

}  // namespace crater::narration
