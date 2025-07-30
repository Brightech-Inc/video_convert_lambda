#!/bin/bash

# API使用例スクリプト

API_BASE_URL="https://your-api-id.execute-api.us-east-1.amazonaws.com/dev"

# 1. ファイルアップロード
echo "=== ファイルアップロード ==="

# 動画ファイルをBase64エンコード
VIDEO_BASE64=$(base64 -i sample_video.mp4)

# アップロードリクエスト
UPLOAD_RESPONSE=$(curl -X POST "$API_BASE_URL/upload" \
  -H "Content-Type: application/json" \
  -d "{
    \"file\": \"$VIDEO_BASE64\",
    \"filename\": \"sample_video.mp4\"
  }")

echo "Upload Response: $UPLOAD_RESPONSE"

# ユニークキーを抽出
UNIQUE_KEY=$(echo $UPLOAD_RESPONSE | jq -r '.unique_key')
echo "Unique Key: $UNIQUE_KEY"

# 2. 動画変換実行
echo -e "\n=== 動画変換実行 ==="

CONVERT_RESPONSE=$(curl -X POST "$API_BASE_URL/convert" \
  -H "Content-Type: application/json" \
  -d "{
    \"unique_key\": \"$UNIQUE_KEY\"
  }")

echo "Convert Response: $CONVERT_RESPONSE"

# 3. 変換状態確認（ダウンロードエンドポイントを使用）
echo -e "\n=== 変換状態確認 ==="

while true; do
  STATUS_RESPONSE=$(curl -s "$API_BASE_URL/download/$UNIQUE_KEY")
  
  # レスポンスがJSONかどうかチェック
  if echo "$STATUS_RESPONSE" | jq . >/dev/null 2>&1; then
    STATUS=$(echo $STATUS_RESPONSE | jq -r '.status')
    echo "Status: $STATUS"
    
    if [ "$STATUS" == "completed" ]; then
      echo "変換が完了しました"
      break
    elif [ "$STATUS" == "error" ]; then
      echo "エラーが発生しました"
      echo $STATUS_RESPONSE | jq .
      exit 1
    else
      echo "変換中です... 5秒後に再確認します"
      sleep 5
    fi
  else
    # JSONでない場合は変換完了（ZIPファイル）
    echo "変換が完了しました"
    break
  fi
done

# 4. 変換結果ダウンロード
echo -e "\n=== 変換結果ダウンロード ==="

curl -o "$UNIQUE_KEY.zip" "$API_BASE_URL/download/$UNIQUE_KEY"
echo "ダウンロード完了: $UNIQUE_KEY.zip"

# ZIPファイルの内容確認
echo -e "\n=== ZIPファイルの内容 ==="
unzip -l "$UNIQUE_KEY.zip"