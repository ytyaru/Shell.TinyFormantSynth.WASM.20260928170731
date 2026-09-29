[en](./README.md)

# TinyFormantSynth.WASM

tiny-formant-synthをWASM化してブラウザ上で音声合成してみる。

1. [ayutaz/tiny-formant-synth][]を少し改造しライブラリ化する
2. [emsdk][]でビルドしWASM化する
3. [index.html][DEMO]で読み込んで実行する

クロスプラットフォーム化されたので、最近のブラウザならどんなOSでも実行できるはず。

[ayutaz/tiny-formant-synth]:https://github.com/ayutaz/tiny-formant-synth
[emsdk]:https://github.com/emscripten-core/emsdk

# デモ

* [デモ][DEMO]

[DEMO]:https://ytyaru.github.io/Shell.TinyFormantSynth.WASM.20260928170731/

# 特徴

* 音声合成（フォルマント合成）
* 日本語
* 超軽量（245.2KB = wasm:167KB + js:78.2KB）
* クロスプラットフォーム（どのOSでも動作する [デモ][DEMO]）
* C++20言語製

# 開発環境

* <time datetime="20260928165843">20260928165843</time>
* [Raspbierry Pi](https://ja.wikipedia.org/wiki/Raspberry_Pi) 4 Model B Rev 1.2
* [Raspberry Pi OS](https://ja.wikipedia.org/wiki/Raspbian) buster 10.0 2020-08-20 <small>[setup](http://ytyaru.hatenablog.com/entry/2020/10/06/111111)</small>
* bash 5.2.15(1)-release

```sh
$ uname -a

```

# インストール

```sh
git clone https://github.com/ytyaru/Shell.TinyFormantSynth.WASM.20260928170731
```

# 使い方

```sh
cd Shell.TinyFormantSynth.WASM.20260928170731/src
./run.sh
```

# 注意

* 品質が低くノイズも入る。昨今のHMMやAI音声合成とは比べ物にならない。

# 著者

　ytyaru

* [![github](http://www.google.com/s2/favicons?domain=github.com)](https://github.com/ytyaru "github")
* [![hatena](http://www.google.com/s2/favicons?domain=www.hatena.ne.jp)](http://ytyaru.hatenablog.com/ytyaru "hatena")

<!--
* [![twitter](http://www.google.com/s2/favicons?domain=twitter.com)](https://twitter.com/ytyaru1 "twitter")
* [![mastodon](http://www.google.com/s2/favicons?domain=mstdn.jp)](https://mstdn.jp/web/accounts/233143 "mastdon")
-->

# ライセンス

　このソフトウェアはCC0ライセンスである。

[![CC0](http://i.creativecommons.org/p/zero/1.0/88x31.png "CC0")](http://creativecommons.org/publicdomain/zero/1.0/deed.ja)

# 謝辞

[ayutaz/tiny-formant-synth][]に感謝。

