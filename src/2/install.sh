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
# formant.cpp がカレントまたは上の階層にあれば tiny-formant-synth にコピー、なければそのまま
if [ -f "formant.cpp" ]; then
    cp formant.cpp tiny-formant-synth/
elif [ -f "../formant.cpp" ]; then
    cp ../formant.cpp tiny-formant-synth/
fi

cd tiny-formant-synth

if [ ! -f "formant.cpp" ]; then
    echo "エラー: formant.cpp が見つかりません。スクリプトと同じディレクトリに配置してください。"
    exit 1
fi

echo "=== [2/5] main_wasm.cpp の作成 (ラウドネス正規化・音量増幅対応) ==="
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

emscripten::val synthesize_to_wav_bytes(std::string text) {
    std::cout << "--- [WASM] Synthesize: " << text << " ---" << std::endl;
    auto sequence = textToPhoneme(text);
    
    std::vector<int16_t> pcm_data;
    Synthesizer synth;
    synth.synthesize(sequence, pcm_data);
    
    if (pcm_data.empty()) {
        pcm_data.resize(4410, 0);
    }
    
    // --- ラウドネス正規化 & ピークブースト（音量増幅） ---
    // フォルマント合成の出力は小さいため、最大ピークを検出して目標レベルまで引き上げます
    double max_val = 0.0;
    for (int16_t sample : pcm_data) {
        max_val = std::max(max_val, static_cast<double>(std::abs(sample)));
    }
    
    if (max_val > 0.0) {
        // 安全なマージンを持たせつつ、しっかり聞こえる音量（-14 LUFS相当のダイナミクス）にブースト
        double target_peak = 32767.0 * 0.85; // 85%の許容最大振幅
        double gain = target_peak / max_val;
        if (gain > 1.0) {
            for (auto& sample : pcm_data) {
                double scaled = static_cast<double>(sample) * gain;
                sample = static_cast<int16_t>(std::clamp(scaled, -32768.0, 32767.0));
            }
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

echo "=== [3/5] index.html の作成 (直感的な再生・停止・ダウンロードUI) ==="
cat << 'HTML' > index.html
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <title>Tiny Formant Synth</title>
    <style>
        body { font-family: sans-serif; margin: 40px; background: #f4f4f9; }
        .card { background: white; padding: 25px; border-radius: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 600px; }
        textarea { width: 100%; height: 80px; padding: 10px; margin-bottom: 15px; font-size: 16px; border: 1px solid #ccc; border-radius: 6px; box-sizing: border-box; }
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
        <h2>Tiny Formant Synth (WASM)</h2>
        <textarea id="textInput">こんにちは。ふぉるまんとごうせいのてすとです。</textarea>
        
        <div class="btn-group">
            <button id="synthesizeBtn">1. 音声合成</button>
            <button id="playToggleBtn" disabled>▶</button>
            <button id="downloadBtn" disabled>3. ダウンロード (.wav)</button>
        </div>
        
        <div id="status">ステータス: 待機中（「音声合成」を押してください）</div>
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

        let moduleReady = new Promise((resolve) => {
            Module.onRuntimeInitialized = () => resolve(Module);
        });

        const statusDiv = document.getElementById('status');
        const playToggleBtn = document.getElementById('playToggleBtn');
        const downloadBtn = document.getElementById('downloadBtn');

        function setPlayButtonState(state) {
            if (state === 'play') {
                isPlaying = true;
                playToggleBtn.innerText = '⏸';
            } else {
                isPlaying = false;
                playToggleBtn.innerText = '▶';
                startOffset = 0; // 停止時は先頭に戻す
            }
        }

        // 1. 音声合成ボタン
        document.getElementById('synthesizeBtn').onclick = async () => {
            try {
                let Module = await moduleReady;
                let text = document.getElementById('textInput').value;
                statusDiv.innerText = "ステータス: フォルマント合成中...";

                let wavBytes = Module.synthesize_to_wav_bytes(text);
                wavArrayBuffer = new Uint8Array(wavBytes).buffer;

                if (!audioCtx) {
                    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
                }

                audioCtx.decodeAudioData(wavArrayBuffer, (buffer) => {
                    audioBuffer = buffer;
                    startOffset = 0;
                    statusDiv.innerText = "ステータス: 合成完了！▶ボタンで再生できます。";
                    playToggleBtn.disabled = false;
                    downloadBtn.disabled = false;
                    setPlayButtonState('pause');
                }, (err) => {
                    statusDiv.innerText = "エラー: WAVデコード失敗: " + err;
                });
            } catch (err) {
                statusDiv.innerText = "エラー発生: " + err;
            }
        };

        // 2. 再生/一時停止 トグルボタン（終了時は自動で▶に戻り、次回は最初から再生）
        playToggleBtn.onclick = () => {
            if (!audioBuffer) return;

            if (!isPlaying) {
                // 再生開始（または一時停止からの再開）
                if (sourceNode) { try { sourceNode.stop(); } catch(e){} sourceNode.disconnect(); }
                
                sourceNode = audioCtx.createBufferSource();
                sourceNode.buffer = audioBuffer;
                sourceNode.connect(audioCtx.destination);
                
                sourceNode.onended = () => {
                    // 音声が最後まで再生し終わったら自動停止し、ボタンを▶に戻す
                    if (isPlaying) {
                        setPlayButtonState('pause');
                        statusDiv.innerText = "ステータス: 再生終了（次回は最初から再生されます）";
                    }
                };

                startTime = audioCtx.currentTime;
                sourceNode.start(0, startOffset);
                setPlayButtonState('play');
                statusDiv.innerText = "ステータス: 再生中...";
            } else {
                // 一時停止
                startOffset += audioCtx.currentTime - startTime;
                if (sourceNode) {
                    sourceNode.stop();
                    sourceNode.disconnect();
                }
                setPlayButtonState('pause');
                statusDiv.innerText = "ステータス: 一時停止中";
            }
        };

        // 3. ダウンロードボタン
        downloadBtn.onclick = () => {
            if (!wavArrayBuffer) return;
            let blob = new Blob([wavArrayBuffer], { type: 'audio/wav' });
            let url = URL.createObjectURL(blob);
            let a = document.createElement('a');
            a.href = url;
            a.download = 'こんにちは。ふぉるまんとごうせいのてすとです。.wav';
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
