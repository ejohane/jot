#include "whisper.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// stdin is raw mono float32 PCM at 16 kHz. stdout is one tab-delimited event
// per line: R (model ready), P (replace provisional phrase),
// F (commit phrase), D (done), E (overflow).
// The reader never waits for inference. Only the newest provisional snapshot
// is inferred; finalized phrases are queued in order.
namespace {
constexpr int sampleRate = 16000;
constexpr int blockSamples = sampleRate / 10;
constexpr int minSpeechSamples = sampleRate / 4;
constexpr int maxPhraseSamples = sampleRate * 12;
constexpr int partialStepSamples = sampleRate * 3 / 2;
constexpr float voiceThreshold = 0.010f;

struct Shared {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<float> phrase;
    std::vector<float> preroll;
    std::deque<std::vector<float>> completed;
    size_t speechSamples = 0;
    size_t lastPartialSamples = 0;
    int silentBlocks = 0;
    bool eof = false;
    bool failed = false;
};

void event(char kind, const std::string & value = {}) {
    std::string clean = value;
    for (char & c : clean) if (c == '\n' || c == '\r' || c == '\t') c = ' ';
    const auto first = clean.find_first_not_of(' ');
    const auto last = clean.find_last_not_of(' ');
    clean = first == std::string::npos ? "" : clean.substr(first, last - first + 1);
    std::printf("%c\t%s\n", kind, clean.c_str());
    std::fflush(stdout);
}

void complete(Shared & shared) {
    if (shared.speechSamples >= minSpeechSamples) {
        if (shared.completed.size() >= 4) shared.failed = true;
        else shared.completed.push_back(std::move(shared.phrase));
    }
    shared.phrase.clear();
    shared.speechSamples = 0;
    shared.lastPartialSamples = 0;
    shared.silentBlocks = 0;
    shared.preroll.clear();
    shared.changed.notify_one();
}

void readAudio(Shared & shared) {
    std::vector<float> block(blockSamples);
    while (true) {
        const size_t read = std::fread(block.data(), sizeof(float), block.size(), stdin);
        if (read == 0) break;
        float energy = 0;
        for (size_t i = 0; i < read; ++i) energy += block[i] * block[i];
        const bool voiced = std::sqrt(energy / read) > voiceThreshold;
        {
            std::lock_guard lock(shared.mutex);
            if (shared.failed) break;
            if (shared.phrase.empty()) {
                if (voiced) {
                    shared.phrase = std::move(shared.preroll);
                    shared.phrase.insert(shared.phrase.end(), block.begin(), block.begin() + read);
                    shared.speechSamples = read;
                } else {
                    shared.preroll.insert(shared.preroll.end(), block.begin(), block.begin() + read);
                    if (shared.preroll.size() > sampleRate / 3)
                        shared.preroll.erase(shared.preroll.begin(), shared.preroll.end() - sampleRate / 3);
                }
            } else {
                shared.phrase.insert(shared.phrase.end(), block.begin(), block.begin() + read);
                if (voiced) {
                    shared.speechSamples += read;
                    shared.silentBlocks = 0;
                } else {
                    ++shared.silentBlocks;
                }
                if (shared.silentBlocks >= 9 || shared.phrase.size() >= maxPhraseSamples) complete(shared);
                else if (shared.phrase.size() >= shared.lastPartialSamples + partialStepSamples) shared.changed.notify_one();
            }
        }
    }
    std::lock_guard lock(shared.mutex);
    if (!shared.failed && !shared.phrase.empty()) complete(shared);
    shared.eof = true;
    shared.failed = shared.failed || std::ferror(stdin);
    shared.changed.notify_one();
}

std::string infer(whisper_context * context, const std::vector<float> & samples) {
    if (samples.empty()) return {};
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = "en";
    params.translate = false;
    params.no_context = true;
    params.single_segment = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.suppress_blank = true;
    params.n_threads = 4;
    if (whisper_full(context, params, samples.data(), static_cast<int>(samples.size())) != 0) return {};
    std::string result;
    for (int i = 0; i < whisper_full_n_segments(context); ++i)
        result += whisper_full_get_segment_text(context, i);
    return result;
}
}

int main(int argc, char ** argv) {
    if (argc != 3 || std::strcmp(argv[1], "-m") != 0) return 2;
    auto params = whisper_context_default_params();
    params.use_gpu = true;
    whisper_context * context = whisper_init_from_file_with_params(argv[2], params);
    if (!context) return 3;
    Shared shared;
    std::thread reader(readAudio, std::ref(shared));
    event('R');
    while (true) {
        std::vector<float> audio;
        bool final = false;
        {
            std::unique_lock lock(shared.mutex);
            shared.changed.wait_for(lock, std::chrono::milliseconds(250), [&] {
                return !shared.completed.empty() || shared.eof ||
                    shared.phrase.size() >= shared.lastPartialSamples + partialStepSamples;
            });
            if (!shared.completed.empty()) {
                audio = std::move(shared.completed.front());
                shared.completed.pop_front();
                final = true;
            } else if (shared.phrase.size() >= shared.lastPartialSamples + partialStepSamples) {
                audio = shared.phrase;
                shared.lastPartialSamples = shared.phrase.size();
            } else if (shared.eof) break;
        }
        if (audio.empty()) continue;
        const std::string result = infer(context, audio);
        if (final) event('F', result);
        else {
            std::lock_guard lock(shared.mutex);
            // A phrase can finalize while inference is running; its final event
            // will follow and replace this provisional text.
            if (shared.completed.empty() && !shared.phrase.empty()) event('P', result);
        }
    }
    reader.join();
    whisper_free(context);
    if (shared.failed) { event('E'); return 4; }
    event('D');
    return 0;
}
