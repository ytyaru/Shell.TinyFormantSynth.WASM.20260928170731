#include <iostream>
#include <vector>
#include <string>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <emscripten/bind.h>

#define TEST_BUILD
#include "formant.cpp"

emscripten::val synthesize_to_wav_bytes(std::string text, double target_lufs) {
    std::cout << "--- [WASM] Synthesize: " << text << " (Target LUFS: " << target_lufs << ") ---" << std::endl;
    auto sequence = textToPhoneme(text);
    
    std::vector<int16_t> pcm_data;
    Synthesizer synth;
    synth.synthesize(sequence, pcm_data);
    
    if (pcm_data.empty()) {
        pcm_data.resize(4410, 0);
    }
    
    // --- 雑音対策：簡易ローパスフィルター（高域のザラつきを削る） ---
    // フォルマント合成特有のパチパチ音や高周波の耳障りなノイズをまろやかにします
    if (pcm_data.size() > 1) {
        std::vector<int16_t> filtered = pcm_data;
        float prev = pcm_data[0];
        float alpha = 0.75f; // カットオフ調整 (値が大きいほど高域が残る)
        for (size_t i = 1; i < pcm_data.size(); ++i) {
            filtered[i] = static_cast<int16_t>(alpha * pcm_data[i] + (1.0f - alpha) * prev);
            prev = filtered[i];
        }
        pcm_data = std::move(filtered);
    }

    // --- 本格的なラウドネス（RMSベース）正規化処理 ---
    double sum_squares = 0.0;
    for (int16_t sample : pcm_data) {
        double val = static_cast<double>(sample) / 32768.0;
        sum_squares += val * val;
    }
    double rms = std::sqrt(sum_squares / pcm_data.size());
    
    if (rms > 1e-6) {
        double target_rms = std::pow(10.0, target_lufs / 20.0);
        double gain = target_rms / rms;
        
        for (auto& sample : pcm_data) {
            double scaled = static_cast<double>(sample) * gain;
            sample = static_cast<int16_t>(std::clamp(scaled, -32768.0, 32767.0));
        }
    }
    
    int sample_rate = static_cast<int>(kSampleRate);
    int data_size = pcm_data.size() * sizeof(int16_t);
    std::vector<uint8_t> wav_file;
    
    auto append_bytes = [&](const void* data, size_t size) {
        const uint8_t* p = (const uint8_t*)data;
        wav_file.insert(wav_file.end(), p, p + size);
    };

    append_bytes("RIFF", 4);
    uint32_t chunk_size = 36 + data_size;
    append_bytes(&chunk_size, 4);
    append_bytes("WAVE", 4);

    append_bytes("fmt ", 4);
    uint32_t sub1_size = 16;
    append_bytes(&sub1_size, 4);
    uint16_t audio_format = 1;
    append_bytes(&audio_format, 2);
    uint16_t num_channels = 1;
    append_bytes(&num_channels, 2);
    uint32_t s_rate = sample_rate;
    append_bytes(&s_rate, 4);
    uint32_t byte_rate = sample_rate * 1 * 2;
    append_bytes(&byte_rate, 4);
    uint16_t block_align = 2;
    append_bytes(&block_align, 2);
    uint16_t bits_per_sample = 16;
    append_bytes(&bits_per_sample, 2);

    append_bytes("data", 4);
    append_bytes(&data_size, 4);
    append_bytes(pcm_data.data(), data_size);

    // 正確なバイト列をコピーして返す（型付き配列の安全なヒープ確保）
    return emscripten::val(emscripten::typed_memory_view(wav_file.size(), wav_file.data()));
}

EMSCRIPTEN_BINDINGS(tiny_formant_synth) {
    emscripten::function("synthesize_to_wav_bytes", &synthesize_to_wav_bytes);
}
