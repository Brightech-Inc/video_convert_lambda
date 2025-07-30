FROM public.ecr.aws/lambda/python:3.11

# 必要なツールのインストール
RUN yum update -y && \
    yum install -y wget xz && \
    yum clean all

# FFmpegの静的ビルドをダウンロード
RUN wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xf ffmpeg-release-amd64-static.tar.xz && \
    mv ffmpeg-*-amd64-static/ffmpeg /usr/local/bin/ && \
    mv ffmpeg-*-amd64-static/ffprobe /usr/local/bin/ && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    rm -rf ffmpeg-* && \
    yum remove -y wget xz && \
    yum clean all

# 依存関係のインストール
COPY requirements.txt .
RUN pip install -r requirements.txt

# Lambda関数のコピー
COPY lambda_function.py ${LAMBDA_TASK_ROOT}

# ハンドラーの設定
CMD ["lambda_function.lambda_handler"]