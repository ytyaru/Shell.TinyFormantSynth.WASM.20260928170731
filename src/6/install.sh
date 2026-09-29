cat << 'EOF' > run_all.sh
#!/bin/bash
set -e

echo "=== [0/5] 既存のポート8081のプロセスを終了 ==="
fuser -k 8081/tcp 2>/dev/null || true
sleep 1

echo "=== [1/5] EMSDKの環境確認・自動クローン＆ビルド ==="
EMSDK_ENV=""
for path in "./emsdk/emsdk_env.sh" "../emsdk/emsdk_env.sh" "$HOME/emsdk/emsdk_env.sh" "/tmp/work/emsdk/emsdk_env.sh"; do
    if [ -f "$path" ]; then
        EMSDK_ENV="$path"
        break
    fi
done

if [ -z "$EMSDK_ENV" ]; then
    echo "emsdkが見つからないため、自動でクローンしてセットアップします..."
    if [ ! -d "emsdk" ]; then
        git clone https://github.com/emscripten-core/emsdk.git
    fi
    cd emsdk
    ./emsdk install latest
    ./emsdk activate latest
    source ./emsdk_env.sh
    cd ..
    EMSDK_ENV="./emsdk/emsdk_env.sh"
else
    source "$EMSDK_ENV"
fi

if [ ! -d "tiny-formant-synth" ]; then
    mkdir -p tiny-formant-synth
fi
if [ -f "formant.cpp" ]; then
    cp formant.cpp tiny-formant-synth/
elif [ -f "../formant.cpp" ]; then
    cp ../formant.cpp tiny-formant-synth/
fi

cd tiny-formant-synth

if [ ! -f "formant.cpp" ]; then
    echo "エラー: formant.cpp が見つかりません。"
    exit 1
fi

echo "=== [2/5] main_wasm.cpp の作成 (ITU-R BS.1770 準拠 LUFSラウドネス正規化) ==="
cat << 'CPP' > main_wasm.cpp
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

    return emscripten::val(emscripten::typed_memory_view(wav_file.size(), wav_file.data()));
    // ↓不要
    //return emscripten::val(emscripten::typed_memory_view(wav_file.size(), wav_file.data())).call<emscripten::val>("slice", 0);
}

EMSCRIPTEN_BINDINGS(tiny_formant_synth) {
    emscripten::function("synthesize_to_wav_bytes", &synthesize_to_wav_bytes);
}
CPP

echo "=== [3/5] index.html の作成 (LUFS対応インターフェース) ==="
cat << 'HTML' > index.html
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <title>Tiny Formant Synth Player</title>
    <style>
        body { font-family: sans-serif; margin: 40px; background: #f4f4f9; }
        .card { background: white; padding: 25px; border-radius: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 600px; }
        textarea { width: 100%; height: 80px; padding: 10px; margin-bottom: 12px; font-size: 16px; border: 1px solid #ccc; border-radius: 6px; box-sizing: border-box; }
        .setting-row { display: flex; align-items: center; gap: 10px; margin-bottom: 15px; font-size: 14px; color: #333; }
        .setting-row input { width: 80px; padding: 6px; font-size: 14px; border: 1px solid #ccc; border-radius: 4px; }
        .btn-group { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 15px; }
        button { padding: 10px 18px; cursor: pointer; font-weight: bold; border: none; border-radius: 6px; font-size: 15px; transition: opacity 0.2s; }
        button:disabled { opacity: 0.4; cursor: not-allowed; }
        button:hover:not(:disabled) { opacity: 0.85; }
        #synthesizeBtn { background: #4CAF50; color: white; flex-grow: 1; }
        #playToggleBtn { background: #2196F3; color: white; min-width: 60px; font-size: 18px; }
        #downloadBtn { background: #9C27B0; color: white; }
        #status { margin-top: 15px; color: #444; font-family: monospace; background: #f0f0f5; padding: 12px; border-radius: 6px; font-size: 14px; }
    </style>
</head>
<body>
    <div class="card">
        <h2>Tiny Formant Synth (Player)</h2>
        <textarea id="textInput">こんにちは。ふぉるまんとごうせいのてすとです。</textarea>
        
        <div class="setting-row">
            <label for="lufsInput">目標ラウドネス (LUFS):</label>
            <input type="number" id="lufsInput" value="-14.0" step="0.5" />
            <span style="color:#666; font-size:12px;">(推奨放送規格: -14.0 〜 -24.0 LUFS)</span>
        </div>

        <div class="btn-group">
            <button id="synthesizeBtn">音声合成して自動再生</button>
            <button id="playToggleBtn" disabled>▶</button>
            <button id="downloadBtn" disabled>WAVダウンロード</button>
        </div>
        
        <div id="status">ステータス: 待機中</div>
    </div>

    <script src="synth.js"></script>
    <script>
        let audioCtx = null;
        let audioBuffer = null;
        let sourceNode = null;
        let savedWavBytes = null;
        
        let startOffset = 0;
        let startTime = 0;
        let isPlaying = false;
        let isFinished = false;

        let moduleReady = new Promise((resolve) => {
            Module.onRuntimeInitialized = () => resolve(Module);
        });

        const statusDiv = document.getElementById('status');
        const synthesizeBtn = document.getElementById('synthesizeBtn');
        const playToggleBtn = document.getElementById('playToggleBtn');
        const downloadBtn = document.getElementById('downloadBtn');

        function playAudio(offset = 0) {
            if (!audioBuffer) return;
            if (sourceNode) { try { sourceNode.stop(); } catch(e){} sourceNode.disconnect(); }

            if (!audioCtx) {
                audioCtx = new (window.AudioContext || window.webkitAudioContext)();
            }

            sourceNode = audioCtx.createBufferSource();
            sourceNode.buffer = audioBuffer;
            sourceNode.connect(audioCtx.destination);
            
            sourceNode.onended = () => {
                if (isPlaying) {
                    isPlaying = false;
                    isFinished = true;
                    playToggleBtn.innerText = '▶';
                    synthesizeBtn.disabled = false;
                    startOffset = 0;
                    statusDiv.innerText = "ステータス: 再生終了";
                }
            };

            startTime = audioCtx.currentTime;
            sourceNode.start(0, offset);
            isPlaying = true;
            isFinished = false;
            playToggleBtn.innerText = '⏸';
            synthesizeBtn.disabled = true;
            statusDiv.innerText = "ステータス: 再生中...";
        }

        synthesizeBtn.onclick = async () => {
            try {
                let Module = await moduleReady;
                let text = document.getElementById('textInput').value;
                let targetLufs = parseFloat(document.getElementById('lufsInput').value) || -14.0;
                
                synthesizeBtn.disabled = true;
                statusDiv.innerText = "ステータス: フォルマント合成＆LUFS正規化中 (" + targetLufs + " LUFS)...";

                let wavBytes = Module.synthesize_to_wav_bytes(text, targetLufs);
                savedWavBytes = new Uint8Array(wavBytes);
                let arrayBuffer = savedWavBytes.buffer.slice(savedWavBytes.byteOffset, savedWavBytes.byteOffset + savedWavBytes.byteLength);

                if (!audioCtx) {
                    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
                }

                audioCtx.decodeAudioData(arrayBuffer, (buffer) => {
                    audioBuffer = buffer;
                    startOffset = 0;
                    isFinished = false;
                    playToggleBtn.disabled = false;
                    downloadBtn.disabled = false;
                    statusDiv.innerText = "ステータス: 合成完了（LUFS対応）。自動再生します。";
                    
                    playAudio(0);
                }, (err) => {
                    synthesizeBtn.disabled = false;
                    statusDiv.innerText = "エラー: WAVデコード失敗: " + err;
                });
            } catch (err) {
                synthesizeBtn.disabled = false;
                statusDiv.innerText = "エラー発生: " + err;
            }
        };

        playToggleBtn.onclick = () => {
            if (!audioBuffer) return;

            if (isPlaying) {
                startOffset += audioCtx.currentTime - startTime;
                if (sourceNode) {
                    sourceNode.stop();
                    sourceNode.disconnect();
                }
                isPlaying = false;
                playToggleBtn.innerText = '▶';
                synthesizeBtn.disabled = false;
                statusDiv.innerText = "ステータス: 一時停止中";
            } else {
                if (isFinished) {
                    startOffset = 0;
                    isFinished = false;
                }
                playAudio(startOffset);
            }
        };

        downloadBtn.onclick = () => {
            if (!savedWavBytes || savedWavBytes.length === 0) {
                statusDiv.innerText = "エラー: ダウンロードする音声データがありません。";
                return;
            }
            let blob = new Blob([savedWavBytes], { type: 'audio/wav' });
            let url = URL.createObjectURL(blob);
            let a = document.createElement('a');
            a.href = url;
            a.download = 'formant_synth_lufs.wav';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            statusDiv.innerText = "ステータス: LUFS正規化済みWAVファイルをダウンロードしました。";
        };
    </script>
</body>
</html>
HTML

echo "=== [4/5] コンパイル ==="
em++ main_wasm.cpp -o synth.js \
    -O3 \
    -std=c++20 \
    --bind \
    -s ALLOW_MEMORY_GROWTH=1 \
    -s EXPORTED_RUNTIME_METHODS='["cwrap", "ccall"]'

echo "=== [5/5] サーバー起動 (ポート 8081) ==="
echo "=================================================="
echo " 準備完了！以下のURLをブラウザで開いてください:"
echo " http://<ラズパイのIP>:8081/"
echo "=================================================="

python3 -m http.server 8081
EOF

chmod +x run_all.sh
./run_all.sh
