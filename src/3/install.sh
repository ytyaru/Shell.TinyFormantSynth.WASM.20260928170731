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

echo "=== [2/5] main_wasm.cpp の作成 (LUFSラウドネス正規化実装) ==="
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

emscripten::val synthesize_to_wav_bytes(std::string text, double target_lufs) {
    std::cout << "--- [WASM] Synthesize: " << text << " (Target LUFS: " << target_lufs << ") ---" << std::endl;
    auto sequence = textToPhoneme(text);
    
    std::vector<int16_t> pcm_data;
    Synthesizer synth;
    synth.synthesize(sequence, pcm_data);
    
    if (pcm_data.empty()) {
        pcm_data.resize(4410, 0);
    }
    
    // --- 本格的なラウドネス（RMSベース）正規化処理 ---
    // 1. RMS (二乗平均平方根) を計算
    double sum_squares = 0.0;
    for (int16_t sample : pcm_data) {
        double val = static_cast<double>(sample) / 32768.0;
        sum_squares += val * val;
    }
    double rms = std::sqrt(sum_squares / pcm_data.size());
    
    if (rms > 1e-6) {
        // ざっくりとしたLUFS推定 (簡便のため RMS dBFS + 0.6 をおおよそのLUFSとみなす、あるいはターゲットゲインを直接算出)
        // 目標LUFSからリニアゲインを逆算する (LUFS ≒ dBFS)
        // target_lufs (例: -14.0) に対する目標RMSを算出
        double target_rms = std::pow(10.0, target_lufs / 20.0);
        double gain = target_rms / rms;
        
        // 適用してクリッピングを防ぎつつゲインをかける
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

    return emscripten::val(emscripten::typed_memory_view(wav_file.size(), wav_file.data()));
}

EMSCRIPTEN_BINDINGS(tiny_formant_synth) {
    emscripten::function("synthesize_to_wav_bytes", &synthesize_to_wav_bytes);
}
CPP

echo "=== [3/5] index.html の作成 (常識的プレイヤー＆LUFS入力) ==="
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
            <span style="color:#666; font-size:12px;">(例: -14.0 が標準的です)</span>
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
        let wavArrayBuffer = null;
        
        let startOffset = 0;
        let startTime = 0;
        let isPlaying = false;
        let isFinished = false; // 再生が最後まで終わったか

        let moduleReady = new Promise((resolve) => {
            Module.onRuntimeInitialized = () => resolve(Module);
        });

        const statusDiv = document.getElementById('status');
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
                // 音声が最後まで自然に再生し終わったとき
                if (isPlaying) {
                    isPlaying = false;
                    isFinished = true;
                    playToggleBtn.innerText = '▶';
                    startOffset = 0;
                    statusDiv.innerText = "ステータス: 再生終了";
                }
            };

            startTime = audioCtx.currentTime;
            sourceNode.start(0, offset);
            isPlaying = true;
            isFinished = false;
            playToggleBtn.innerText = '⏸';
            statusDiv.innerText = "ステータス: 再生中...";
        }

        // 音声合成ボタン（自動再生付き）
        document.getElementById('synthesizeBtn').onclick = async () => {
            try {
                let Module = await moduleReady;
                let text = document.getElementById('textInput').value;
                let targetLufs = parseFloat(document.getElementById('lufsInput').value) || -14.0;
                
                statusDiv.innerText = "ステータス: フォルマント合成中 (LUFS: " + targetLufs + ")...";

                let wavBytes = Module.synthesize_to_wav_bytes(text, targetLufs);
                wavArrayBuffer = new Uint8Array(wavBytes).buffer;

                if (!audioCtx) {
                    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
                }

                audioCtx.decodeAudioData(wavArrayBuffer, (buffer) => {
                    audioBuffer = buffer;
                    startOffset = 0;
                    isFinished = false;
                    playToggleBtn.disabled = false;
                    downloadBtn.disabled = false;
                    statusDiv.innerText = "ステータス: 合成完了。自動再生します。";
                    
                    // 合成後、自動的に再生開始
                    playAudio(0);
                }, (err) => {
                    statusDiv.innerText = "エラー: WAVデコード失敗: " + err;
                });
            } catch (err) {
                statusDiv.innerText = "エラー発生: " + err;
            }
        };

        // 常識的な再生/一時停止トグルボタン
        playToggleBtn.onclick = () => {
            if (!audioBuffer) return;

            if (isPlaying) {
                // [一時停止] 再生中ならその場で止めてオフセットを記録
                startOffset += audioCtx.currentTime - startTime;
                if (sourceNode) {
                    sourceNode.stop();
                    sourceNode.disconnect();
                }
                isPlaying = false;
                playToggleBtn.innerText = '▶';
                statusDiv.innerText = "ステータス: 一時停止中";
            } else {
                // [再開 または 最初から]
                if (isFinished) {
                    // 最後まで再生し終わった後のクリックなら「最初から」再生
                    startOffset = 0;
                    isFinished = false;
                }
                // 中断された箇所（startOffset）から再開
                playAudio(startOffset);
            }
        };

        // ダウンロードボタン
        downloadBtn.onclick = () => {
            if (!wavArrayBuffer) return;
            let blob = new Blob([wavArrayBuffer], { type: 'audio/wav' });
            let url = URL.createObjectURL(blob);
            let a = document.createElement('a');
            a.href = url;
            a.download = 'formant_synth.wav';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            statusDiv.innerText = "ステータス: WAVファイルをダウンロードしました。";
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
