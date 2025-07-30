#!/bin/bash

# FFmpegバイナリを取得するスクリプト

set -e

echo "FFmpegバイナリを取得しています..."

# binディレクトリを作成
mkdir -p bin

# FFmpegの軽量版を取得（GitHub Actions環境で実行）
if [ "$CI" = "true" ]; then
    echo "CI環境でFFmpegをダウンロード中..."
    curl -L "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/linux-x64" -o bin/ffmpeg
    chmod +x bin/ffmpeg
    
    # ffprobeも必要な場合は追加
    # curl -L "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffprobe-linux-x64" -o bin/ffprobe
    # chmod +x bin/ffprobe
else
    echo "ローカル環境では手動でFFmpegバイナリを配置してください"
    echo "または、GitHub Actionsでビルドしてください"
fi

echo "FFmpegバイナリの取得完了"