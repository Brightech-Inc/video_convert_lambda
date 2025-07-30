FROM public.ecr.aws/lambda/python:3.11

# FFmpegのインストール
RUN yum update -y && \
    yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm && \
    yum localinstall -y --nogpgcheck https://download1.rpmfusion.org/free/el/rpmfusion-free-release-7.noarch.rpm && \
    yum install -y ffmpeg && \
    yum clean all

# 依存関係のインストール
COPY requirements.txt .
RUN pip install -r requirements.txt

# Lambda関数のコピー
COPY lambda_function.py ${LAMBDA_TASK_ROOT}

# ハンドラーの設定
CMD ["lambda_function.lambda_handler"]