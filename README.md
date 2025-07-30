# Video Converter Lambda

AWS Lambdaを使用してMP4動画をHLS形式に変換するサービス

## 機能

- ファイルアップロード → 変換 → ダウンロードの3ステップAPI
- MP4動画ファイルをHLS形式に変換
- 変換状態管理（S3ファイルベース、DB不要）
- 変換結果のZIPダウンロード機能
- ユニークキー生成（タイムスタンプ+UUID）でDB連携に対応
- バックアップ機能（階層構造: /ユニークキー/YYYYMMDDHHmmss_元ファイル名）
- API Gateway経由でのアクセス

## セットアップ

### 必要な準備

1. AWS CLIの設定
2. GitHub Secretsに以下を設定:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

### デプロイ

#### 初回デプロイ

初回は以下のスクリプトを実行:

```bash
# AWS認証情報を設定後
export AWS_REGION=ap-northeast-1
./scripts/initial-deploy.sh
```

#### 継続的デプロイ

GitHub Actionsを使用した自動デプロイ:

```bash
# mainブランチへのpushで自動デプロイ
git push origin main

# 手動デプロイ（GitHub Actions画面から）
# Actions → Deploy Video Converter Lambda → Run workflow
```

## API使用方法

### 1. ファイルアップロード

**エンドポイント:** `POST /upload`

**リクエスト例:**
```json
{
  "file": "base64エンコードされた動画ファイル",
  "filename": "sample_video.mp4"
}
```

**レスポンス例:**
```json
{
  "unique_key": "20240130123456-a1b2c3d4",
  "s3_location": "s3://upload-bucket/uploads/20240130123456-a1b2c3d4/original_sample_video.mp4",
  "message": "File uploaded successfully"
}
```

### 2. 動画変換実行

**エンドポイント:** `POST /convert`

**リクエスト例:**
```json
{
  "unique_key": "20240130123456-a1b2c3d4",
  "output_bucket": "my-output-bucket",
  "backup_bucket": "my-backup-bucket"
}
```

**レスポンス例（成功時）:**
```json
{
  "unique_key": "20240130123456-a1b2c3d4",
  "status": "completed",
  "playlist_url": "https://my-output-bucket.s3.amazonaws.com/converted/20240130123456-a1b2c3d4/playlist.m3u8",
  "output_location": "s3://my-output-bucket/converted/20240130123456-a1b2c3d4/"
}
```

**レスポンス例（処理中）:**
```json
{
  "unique_key": "20240130123456-a1b2c3d4",
  "status": "processing",
  "message": "Conversion is already in progress"
}
```

### 3. 変換結果ダウンロード

**エンドポイント:** `GET /download/{unique_key}`

**レスポンス:**
- **変換完了時:** ZIPファイル（バイナリ）
- **処理中:** 
  ```json
  {
    "status": "processing",
    "message": "Conversion is still in progress",
    "unique_key": "20240130123456-a1b2c3d4"
  }
  ```
- **エラー時:**
  ```json
  {
    "status": "error",
    "message": "Conversion failed",
    "unique_key": "20240130123456-a1b2c3d4",
    "error_details": {...}
  }
  ```

## ローカルでのテスト

```bash
# Dockerイメージのビルド
docker build -t video-converter .

# ローカル実行（要Lambda Runtime Interface Emulator）
docker run -p 9000:8080 video-converter
```

## アーキテクチャ

- **Lambda Function**: コンテナイメージとして実装（FFmpeg同梱）
- **API Gateway**: HTTPエンドポイント提供（3つのルート）
  - `/upload`: ファイルアップロード
  - `/convert`: 変換実行
  - `/download/{unique_key}`: ZIPダウンロード
- **S3バケット構成**:
  - Upload Bucket: アップロードファイルと変換済みファイル保存（30日保持）
  - Output Bucket: 変換済みファイルの公開用
  - Backup Bucket: バックアップ保存用（90日保持、バージョニング有効）
- **状態管理**: S3ファイルベース（DB不要）
  - `processing.txt`: 変換中
  - `completed.txt`: 変換完了
  - `error.txt`: エラー発生
- **CloudFormation**: インフラストラクチャの管理
- **GitHub Actions**: CI/CDパイプライン

## ユニークキーとディレクトリ構造

### ユニークキー形式
- 形式: `YYYYMMDDHHmmss-XXXXXXXX`
- 例: `20240130123456-a1b2c3d4`
- タイムスタンプ（14桁）+ ハイフン + UUID短縮版（8桁）で構成

### S3ディレクトリ構造

**アップロードバケット:**
```
s3://upload-bucket/uploads/{ユニークキー}/
  ├── original_video.mp4        # アップロードされた元ファイル
  ├── processing.txt            # 変換中フラグ
  ├── completed.txt             # 変換完了フラグ
  ├── error.txt                 # エラー情報（エラー時のみ）
  └── converted/                # 変換済みファイル
      ├── playlist.m3u8
      ├── segment_000.ts
      └── ...
```

**出力バケット:**
```
s3://output-bucket/converted/{ユニークキー}/
  ├── playlist.m3u8
  ├── segment_000.ts
  ├── segment_001.ts
  └── ...
```

**バックアップバケット:**
```
s3://backup-bucket/backup/{ユニークキー}/{YYYYMMDDHHmmss}_{元ファイル名}/
  ├── playlist.m3u8
  ├── segment_000.ts
  ├── segment_001.ts
  └── ...
```

### バックアップ機能の特徴
- バックアップは90日間保持され、その後自動削除されます
- バージョニングが有効なため、同名ファイルの履歴も保持されます
- ユニークキーによりDB連携時の管理が容易になります