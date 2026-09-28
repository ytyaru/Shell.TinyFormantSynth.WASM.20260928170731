cat << 'EOF' > run_all.sh
#!/bin/bash
set -e

echo "=== [0/4] 既存のポート8081のプロセスを終了 ==="
fuser -k 8081/tcp 2>/dev/null || true
sleep 1

echo "=== [1/4] 環境の自動検出と準備 ==="
EMSDK_ENV=""
for path in "./emsdk/emsdk_env.sh" "../emsdk/emsdk_env.sh" "$HOME/emsdk/emsdk_env.sh" "/tmp/work/emsdk/emsdk_env.sh"; do
    if [ -f "$path" ]; then
        EMSDK_ENV="$path"
        break
    fi
done

if [ -z "$EMSDK_ENV" ]; then
    echo "エラー: emsdkが見つかりません。"
    exit 1
fi

source "$EMSDK_ENV"

if [ ! -d "tiny-formant-synth" ]; then
    if [ -d "../tiny-formant-synth" ]; then
        cd ..
    fi
fi
cd tiny-formant-synth

echo "=== [2/4] main_wasm.cpp の作成 (完全修正版) ==="
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
    std::cout << "--- [WASM] Synthesize called with text: " << text << " (size: " << text.size() << ") ---" << std::endl;
    
    // 1. ひらがなから音素シーケンスへ変換
    auto sequence = textToPhoneme(text);
    std::cout << "--- [WASM] Generated sequence size: " << sequence.size() << " ---" << std::endl;
    
    std::vector<int16_t> pcm_data;
    Synthesizer synth;
    synth.synthesize(sequence, pcm_data);
    
    std::cout << "--- [WASM] PCM data generated. Samples: " << pcm_data.size() << " ---" << std::endl;
    
    // 万が一空の場合は無音（または極短のダミー）を返す
    if (pcm_data.empty()) {
        pcm_data.resize(4410, 0);
    }
    
    int sample_rate = static_cast<int>(kSampleRate);
    int data_size = pcm_data.size() * sizeof(int16_t);
    std::vector<uint8_t> wav_file;
    
    auto append_bytes = [&](const void* data, size_t size) {
        const uint8_t* p = (const uint8_t*)data;
        wav_file.insert(wav_file.end(), p, p + size);
    };

    // WAV ヘッダ構築
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

echo "=== [3/4] index.html の作成 ==="
cat << 'HTML' > index.html
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <title>Tiny Formant Synth</title>
    <style>
        body { font-family: sans-serif; margin: 40px; background: #f4f4f9; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); max-width: 600px; }
        textarea { width: 100%; height: 80px; padding: 8px; margin-bottom: 10px; font-size: 16px; }
        button { padding: 10px 16px; margin-right: 5px; cursor: pointer; font-weight: bold; }
        #status { margin-top: 15px; color: #333; white-space: pre-wrap; font-family: monospace; background: #eee; padding: 10px; border-radius: 4px; }
    </style>
</head>
<body>
    <div class="card">
        <h2>Tiny Formant Synth (Formant Synthesis)</h2>
        <textarea id="textInput">あいうえお</textarea>
        <div>
            <button id="synthesizeBtn" style="background:#4CAF50; color:white;">音声合成</button>
            <button id="playBtn" disabled style="background:#2196F3; color:white;">再生</button>
            <button id="pauseBtn" disabled style="background:#FF9800; color:white;">一時停止</button>
            <button id="resumeBtn" disabled style="background:#9C27B0; color:white;">再開</button>
        </div>
        <div id="status">ステータス: 待機中</div>
    </div>

    <script src="synth.js"></script>
    <script>
        let audioCtx = null;
        let audioBuffer = null;
        let sourceNode = null;
        
        let startOffset = 0;
        let startTime = 0;
        let isPlaying = false;

        let moduleReady = new Promise((resolve) => {
            Module.onRuntimeInitialized = () => {
                console.log("WASM Module initialized.");
                resolve(Module);
            };
        });

        const statusDiv = document.getElementById('status');

        document.getElementById('synthesizeBtn').onclick = async () => {
            try {
                let Module = await moduleReady;
                let text = document.getElementById('textInput').value;
                statusDiv.innerText = "ステータス: フォルマント合成中...";

                let wavBytes = Module.synthesize_to_wav_bytes(text);
                let arrayBuffer = new Uint8Array(wavBytes).buffer;

                if (!audioCtx) {
                    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
                }

                audioCtx.decodeAudioData(arrayBuffer, (buffer) => {
                    audioBuffer = buffer;
                    startOffset = 0;
                    statusDiv.innerText = "ステータス: 合成完了！フォルマント音声が再生可能です。";
                    document.getElementById('playBtn').disabled = false;
                    document.getElementById('pauseBtn').disabled = true;
                    document.getElementById('resumeBtn').disabled = true;
                }, (err) => {
                    statusDiv.innerText = "エラー: WAVのデコードに失敗しました: " + err;
                });
            } catch (err) {
                statusDiv.innerText = "エラー発生: " + err;
                console.error(err);
            }
        };

        document.getElementById('playBtn').onclick = () => {
            if (!audioBuffer) return;
            if (sourceNode) { try { sourceNode.stop(); } catch(e){} sourceNode.disconnect(); }
            
            sourceNode = audioCtx.createBufferSource();
            sourceNode.buffer = audioBuffer;
            sourceNode.connect(audioCtx.destination);
            
            sourceNode.onended = () => {
                if (isPlaying) {
                    isPlaying = false;
                    statusDiv.innerText = "ステータス: 再生終了";
                    document.getElementById('pauseBtn').disabled = true;
                    document.getElementById('resumeBtn').disabled = true;
                }
            };

            startTime = audioCtx.currentTime;
            sourceNode.start(0, startOffset);
            isPlaying = true;
            
            statusDiv.innerText = "ステータス: 再生中...";
            document.getElementById('pauseBtn').disabled = false;
            document.getElementById('playBtn').disabled = true;
        };

        document.getElementById('pauseBtn').onclick = () => {
            if (!isPlaying) return;
            startOffset += audioCtx.currentTime - startTime;
            if (sourceNode) {
                sourceNode.stop();
                sourceNode.disconnect();
            }
            isPlaying = false;
            statusDiv.innerText = "ステータス: 一時停止中";
            document.getElementById('pauseBtn').disabled = true;
            document.getElementById('resumeBtn').disabled = false;
        };

        document.getElementById('resumeBtn').onclick = () => {
            if (isPlaying || !audioBuffer) return;
            
            sourceNode = audioCtx.createBufferSource();
            sourceNode.buffer = audioBuffer;
            sourceNode.connect(audioCtx.destination);
            
            startTime = audioCtx.currentTime;
            sourceNode.start(0, startOffset);
            isPlaying = true;
            
            statusDiv.innerText = "ステータス: 再生中...";
            document.getElementById('pauseBtn').disabled = false;
            document.getElementById('playBtn').disabled = true;
        };
    </script>
</body>
</html>
HTML

echo "=== [4/4] コンパイルとサーバー起動 (ポート 8081) ==="
em++ main_wasm.cpp -o synth.js \
    -O3 \
    -std=c++20 \
    --bind \
    -s ALLOW_MEMORY_GROWTH=1 \
    -s EXPORTED_RUNTIME_METHODS='["cwrap", "ccall"]'

echo "=================================================="
echo " 修正完了しました！ブラウザで以下にアクセスしてください:"
echo " http://<ラズパイのIP>:8081/"
echo "=================================================="

python3 -m http.server 8081
EOF

chmod +x run_all.sh
./run_all.sh
