FROM public.ecr.aws/lambda/python:3.11

# 必要なパッケージのインストール
RUN yum update -y && \
    yum install -y curl tar && \
    yum clean all

# 事前にビルドされたFFmpegバイナリをダウンロード
RUN curl -L "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz" \
    -o ffmpeg.tar.xz && \
    tar -xf ffmpeg.tar.xz && \
    cp ffmpeg-master-latest-linux64-gpl/bin/ffmpeg /usr/local/bin/ && \
    cp ffmpeg-master-latest-linux64-gpl/bin/ffprobe /usr/local/bin/ && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    rm -rf ffmpeg* && \
    yum remove -y curl tar && \
    yum clean all

# 依存関係のインストール
COPY requirements.txt .
RUN pip install -r requirements.txt

# Lambda関数のコピー
COPY lambda_function.py ${LAMBDA_TASK_ROOT}

# ハンドラーの設定
CMD ["lambda_function.lambda_handler"]