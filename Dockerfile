FROM public.ecr.aws/lambda/python:3.11

# 依存関係のインストール
COPY requirements.txt .
RUN pip install -r requirements.txt

# FFmpegバイナリをコピー（事前にダウンロード済み）
COPY bin/ffmpeg /usr/local/bin/
RUN chmod +x /usr/local/bin/ffmpeg

# Lambda関数のコピー
COPY lambda_function.py ${LAMBDA_TASK_ROOT}

# ハンドラーの設定
CMD ["lambda_function.lambda_handler"]