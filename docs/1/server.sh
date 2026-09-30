#!/bin/bash
cd "$(dirname "$0")"
python3 -m http.server 8080
echo -n "http://0.0.0.0:8080" | xclip -selection clipboard
