#include <iostream>
#include <vector>
#include <string>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <emscripten/bind.h>

#define TEST_BUILD
#include "formant.cpp"

// ITU-R BS.1770 に準拠した K-weighting フィルターおよび LUFS 計算クラス
class LufsNormalizer {
public:
    static void normalize(std::vector<int16_t>& pcm_data, double target_lufs, double sample_rate) {
        if (pcm_data.empty()) return;

        // 1. 浮動小数点数への変換 (-1.0 〜 1.0)
        size_t n = pcm_data.size();
        std::vector<double> x(n);
        for (size_t i = 0; i < n; ++i) {
            x[i] = static_cast<double>(pcm_data[i]) / 32768.0;
        }

        // 2. Stage 1: 高域シェルビングフィルタ (RLB weighting の前段 / 高域ブースト)
        // 係数は ITU-R BS.1770-4 に準拠 (fs = 44100Hz などの場合は一般的な近似係数または設計式を使用)
        // ここでは一般的なサンプリングレートに対応する標準的なBS.1770フィルタ係数算出を適用
        std::vector<double> y1(n, 0.0);
        {
            // 係数例 (fs=44100Hz基準の近似、または標準フィルタ)
            // v0 = 1.58489319246, K = tan(pi * f0 / fs) 等の代わりに固定係数または動的計算
            // 簡易的かつ正確なBS.1770-4フィルター実装
            double f0 = 1681.974450955533;
            double Vh = 3.999843853973347;
            double Q = 0.7071752369554196;
            double K = std::tan(M_PI * f0 / sample_rate);

            double a0 = 1.0 + K / Q + K * K;
            double b0 = (1.0 + std::sqrt(Vh) * K / Q + K * K) / a0;
            double b1 = (2.0 * (K * K - 1.0)) / a0;
            double b2 = (1.0 - std::sqrt(Vh) * K / Q + K * K) / a0;
            double a1 = (2.0 * (K * K - 1.0)) / a0;
            double a2 = (1.0 - K / Q + K * K) / a0;

            double v_z1 = 0.0, v_z2 = 0.0;
            for (size_t i = 0; i < n; ++i) {
                double v = x[i] - a1 * v_z1 - a2 * v_z2;
                y1[i] = b0 * v + b1 * v_z1 + b2 * v_z2;
                v_z2 = v_z1;
                v_z1 = v;
            }
        }

        // 3. Stage 2: RLBウェイトフィルタ（高域通過 / 低域カット）
        std::vector<double> y2(n, 0.0);
        {
            double f0 = 38.13547087602444;
            double Q = 0.5003270373238773;
            double K = std::tan(M_PI * f0 / sample_rate);

            double a0 = 1.0 + K / Q + K * K;
            double b0 = 1.0 / a0;
            double b1 = -2.0 / a0;
            double b2 = 1.0 / a0;
            double a1 = (2.0 * (K * K - 1.0)) / a0;
            double a2 = (1.0 - K / Q + K * K) / a0;

            double v_z1 = 0.0, v_z2 = 0.0;
            for (size_t i = 0; i < n; ++i) {
                double v = y1[i] - a1 * v_z1 - a2 * v_z2;
                y2[i] = b0 * v + b1 * v_z1 + b2 * v_z2;
                v_z2 = v_z1;
                v_z1 = v;
            }
        }

        // 4. 平均二乗エネルギーの計算 (Mean Square)
        double sum_sq = 0.0;
        for (double val : y2) {
            sum_sq += val * val;
        }
        double mean_sq = sum_sq / static_cast<double>(n);

        if (mean_sq < 1e-12) return; // 無音に近い場合はスキップ

        // 5. 現在の LUFS 値の算出
        double current_lufs = -0.691 + 10.0 * std::log10(mean_sq);

        // 6. 目標 LUFS に向けたゲイン調整
        double diff_db = target_lufs - current_lufs;
        double gain = std::pow(10.0, diff_db / 20.0);

        // 7. 適用とクリッピング防止
        for (size_t i = 0; i < n; ++i) {
            double scaled = x[i] * gain;
            pcm_data[i] = static_cast<int16_t>(std::clamp(scaled * 32768.0, -32768.0, 32767.0));
        }
    }
};

emscripten::val synthesize_to_wav_bytes(std::string text, double target_lufs) {
    std::cout << "--- [WASM] Synthesize: " << text << " (Target LUFS: " << target_lufs << ") ---" << std::endl;
    auto sequence = textToPhoneme(text);
    
    std::vector<int16_t> pcm_data;
    Synthesizer synth;
    synth.synthesize(sequence, pcm_data);
    
    if (pcm_data.empty()) {
        pcm_data.resize(4410, 0);
    }
    /*
    // --- 雑音対策：簡易ローパスフィルター ---
    if (pcm_data.size() > 1) {
        std::vector<int16_t> filtered = pcm_data;
        float prev = pcm_data[0];
        float alpha = 0.75f;
        for (size_t i = 1; i < pcm_data.size(); ++i) {
            filtered[i] = static_cast<int16_t>(alpha * pcm_data[i] + (1.0f - alpha) * prev);
            prev = filtered[i];
        }
        pcm_data = std::move(filtered);
    }
    */
    // --- 本格的な ITU-R BS.1770 準拠 LUFS ラウドネス正規化 ---
    LufsNormalizer::normalize(pcm_data, target_lufs, kSampleRate);
    
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

    //return emscripten::val(emscripten::typed_memory_view(wav_file.size(), wav_file.data()));
    return emscripten::val(emscripten::typed_memory_view(wav_file.size(), wav_file.data())).call<emscripten::val>("slice", 0);
}

EMSCRIPTEN_BINDINGS(tiny_formant_synth) {
    emscripten::function("synthesize_to_wav_bytes", &synthesize_to_wav_bytes);
}
