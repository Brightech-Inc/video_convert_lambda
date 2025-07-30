import os
import json
import subprocess
import tempfile
import boto3
import uuid
import zipfile
import io
import base64
from urllib.parse import urlparse, unquote
from datetime import datetime
from botocore.exceptions import ClientError

s3 = boto3.client('s3')

def lambda_handler(event, context):
    """メインハンドラー: ルーティング処理"""
    try:
        # HTTPメソッドとパスの取得
        http_method = event.get('httpMethod', 'GET')
        path = event.get('path', '/')
        
        # ルーティング
        if http_method == 'POST' and path == '/upload':
            return handle_upload(event, context)
        elif http_method == 'POST' and path == '/convert':
            return handle_convert(event, context)
        elif http_method == 'GET' and path.startswith('/download/'):
            unique_key = path.split('/')[-1]
            return handle_download(event, context, unique_key)
        else:
            return {
                'statusCode': 404,
                'body': json.dumps({'error': 'Not Found'})
            }
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def handle_upload(event, context):
    """ファイルアップロード処理"""
    try:
        # ユニークキーの生成
        timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
        unique_suffix = str(uuid.uuid4())[:8]
        unique_key = f"{timestamp}-{unique_suffix}"
        
        # バケット名取得
        upload_bucket = os.environ.get('UPLOAD_BUCKET')
        if not upload_bucket:
            return {
                'statusCode': 500,
                'body': json.dumps({'error': 'UPLOAD_BUCKET not configured'})
            }
        
        # ファイルデータの取得
        content_type = event.get('headers', {}).get('content-type', '')
        
        if 'multipart/form-data' in content_type:
            # multipart/form-dataの処理
            body = base64.b64decode(event['body'])
            # 簡易的な実装（本番環境では適切なmultipartパーサーを使用）
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Please use base64 encoded file in JSON body'})
            }
        else:
            # JSON形式でbase64エンコードされたファイルを受け取る
            body = json.loads(event.get('body', '{}'))
            file_content_base64 = body.get('file')
            filename = body.get('filename', 'video.mp4')
            
            if not file_content_base64:
                return {
                    'statusCode': 400,
                    'body': json.dumps({'error': 'file field is required'})
                }
            
            # Base64デコード
            file_content = base64.b64decode(file_content_base64)
            
            # S3にアップロード
            s3_key = f"uploads/{unique_key}/original_{filename}"
            s3.put_object(
                Bucket=upload_bucket,
                Key=s3_key,
                Body=file_content,
                ContentType='video/mp4'
            )
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'unique_key': unique_key,
                    's3_location': f"s3://{upload_bucket}/{s3_key}",
                    'message': 'File uploaded successfully'
                })
            }
            
    except Exception as e:
        print(f"Upload error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def handle_convert(event, context):
    """動画変換処理"""
    try:
        # リクエストボディのパース
        body = json.loads(event.get('body', '{}'))
        unique_key = body.get('unique_key')
        
        if not unique_key:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'unique_key is required'})
            }
        
        # バケット名取得
        upload_bucket = os.environ.get('UPLOAD_BUCKET')
        output_bucket = body.get('output_bucket', os.environ.get('OUTPUT_BUCKET'))
        backup_bucket = body.get('backup_bucket', os.environ.get('BACKUP_BUCKET'))
        
        if not upload_bucket or not output_bucket:
            return {
                'statusCode': 500,
                'body': json.dumps({'error': 'Bucket configuration error'})
            }
        
        # 処理状態チェック
        status_check = check_conversion_status(upload_bucket, unique_key)
        if status_check['status'] == 'processing':
            return {
                'statusCode': 202,
                'body': json.dumps({
                    'unique_key': unique_key,
                    'status': 'processing',
                    'message': 'Conversion is already in progress'
                })
            }
        elif status_check['status'] == 'completed':
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'unique_key': unique_key,
                    'status': 'completed',
                    'message': 'Conversion already completed'
                })
            }
        
        # 元ファイルの存在チェック
        original_file_key = find_original_file(upload_bucket, unique_key)
        if not original_file_key:
            return {
                'statusCode': 404,
                'body': json.dumps({'error': 'Original file not found'})
            }
        
        # 処理中フラグを設定
        s3.put_object(
            Bucket=upload_bucket,
            Key=f"uploads/{unique_key}/processing.txt",
            Body=json.dumps({'started_at': datetime.now().isoformat()})
        )
        
        # 一時ディレクトリで変換処理
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                # 元ファイルをダウンロード
                input_file = os.path.join(temp_dir, 'input.mp4')
                s3.download_file(upload_bucket, original_file_key, input_file)
                
                # 出力ディレクトリの作成
                output_dir = os.path.join(temp_dir, 'output')
                os.makedirs(output_dir)
                
                # HLS変換の実行
                output_playlist = os.path.join(output_dir, 'playlist.m3u8')
                convert_to_hls(input_file, output_dir, output_playlist)
                
                # 変換後ファイルをS3にアップロード
                upload_converted_files(output_dir, upload_bucket, unique_key)
                
                # 出力バケットにもアップロード
                output_prefix = f"converted/{unique_key}/"
                uploaded_files = upload_to_s3(output_dir, output_bucket, output_prefix)
                
                # バックアップの実行
                if backup_bucket:
                    timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
                    original_filename = os.path.basename(original_file_key).replace('original_', '')
                    backup_prefix = f"backup/{unique_key}/{timestamp}_{original_filename.split('.')[0]}/"
                    upload_to_s3(output_dir, backup_bucket, backup_prefix)
                
                # 完了フラグを設定
                s3.put_object(
                    Bucket=upload_bucket,
                    Key=f"uploads/{unique_key}/completed.txt",
                    Body=json.dumps({
                        'completed_at': datetime.now().isoformat(),
                        'output_bucket': output_bucket,
                        'files_count': len(uploaded_files)
                    })
                )
                
                # 処理中フラグを削除
                s3.delete_object(
                    Bucket=upload_bucket,
                    Key=f"uploads/{unique_key}/processing.txt"
                )
                
                # プレイリストURL生成
                playlist_key = next(f for f in uploaded_files if f.endswith('playlist.m3u8'))
                playlist_url = f"https://{output_bucket}.s3.amazonaws.com/{playlist_key}"
                
                return {
                    'statusCode': 200,
                    'body': json.dumps({
                        'unique_key': unique_key,
                        'status': 'completed',
                        'playlist_url': playlist_url,
                        'output_location': f"s3://{output_bucket}/{output_prefix}"
                    })
                }
                
        except Exception as e:
            # エラーフラグを設定
            s3.put_object(
                Bucket=upload_bucket,
                Key=f"uploads/{unique_key}/error.txt",
                Body=json.dumps({
                    'error': str(e),
                    'failed_at': datetime.now().isoformat()
                })
            )
            # 処理中フラグを削除
            try:
                s3.delete_object(
                    Bucket=upload_bucket,
                    Key=f"uploads/{unique_key}/processing.txt"
                )
            except:
                pass
            raise
            
    except Exception as e:
        print(f"Convert error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def handle_download(event, context, unique_key):
    """ZIPダウンロード処理"""
    try:
        # バケット名取得
        upload_bucket = os.environ.get('UPLOAD_BUCKET')
        if not upload_bucket:
            return {
                'statusCode': 500,
                'body': json.dumps({'error': 'UPLOAD_BUCKET not configured'})
            }
        
        # 変換状態チェック
        status_check = check_conversion_status(upload_bucket, unique_key)
        
        if status_check['status'] == 'not_found':
            return {
                'statusCode': 404,
                'body': json.dumps({
                    'error': 'Unique key not found',
                    'unique_key': unique_key
                })
            }
        elif status_check['status'] == 'processing':
            return {
                'statusCode': 202,
                'body': json.dumps({
                    'status': 'processing',
                    'message': 'Conversion is still in progress',
                    'unique_key': unique_key
                })
            }
        elif status_check['status'] == 'error':
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'status': 'error',
                    'message': 'Conversion failed',
                    'unique_key': unique_key,
                    'error_details': status_check.get('error_details')
                })
            }
        elif status_check['status'] != 'completed':
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'status': 'pending',
                    'message': 'Conversion not started',
                    'unique_key': unique_key
                })
            }
        
        # 変換済みファイルをZIP化
        zip_buffer = io.BytesIO()
        with zipfile.ZipFile(zip_buffer, 'w', zipfile.ZIP_DEFLATED) as zip_file:
            # 変換済みファイルのリストを取得
            prefix = f"uploads/{unique_key}/converted/"
            response = s3.list_objects_v2(
                Bucket=upload_bucket,
                Prefix=prefix
            )
            
            if 'Contents' not in response:
                return {
                    'statusCode': 404,
                    'body': json.dumps({
                        'error': 'No converted files found',
                        'unique_key': unique_key
                    })
                }
            
            # 各ファイルをZIPに追加
            for obj in response['Contents']:
                file_key = obj['Key']
                file_name = file_key.replace(prefix, '')
                
                # S3からファイルを取得
                file_obj = s3.get_object(Bucket=upload_bucket, Key=file_key)
                file_content = file_obj['Body'].read()
                
                # ZIPに追加
                zip_file.writestr(file_name, file_content)
        
        # ZIPファイルをbase64エンコード
        zip_buffer.seek(0)
        zip_content = zip_buffer.read()
        zip_base64 = base64.b64encode(zip_content).decode('utf-8')
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/zip',
                'Content-Disposition': f'attachment; filename="{unique_key}.zip"'
            },
            'body': zip_base64,
            'isBase64Encoded': True
        }
        
    except Exception as e:
        print(f"Download error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def check_conversion_status(bucket, unique_key):
    """変換状態をチェック"""
    try:
        # 各種フラグファイルの存在確認
        flags = {
            'processing': f"uploads/{unique_key}/processing.txt",
            'completed': f"uploads/{unique_key}/completed.txt",
            'error': f"uploads/{unique_key}/error.txt"
        }
        
        # まずディレクトリの存在確認
        response = s3.list_objects_v2(
            Bucket=bucket,
            Prefix=f"uploads/{unique_key}/",
            MaxKeys=1
        )
        
        if 'Contents' not in response:
            return {'status': 'not_found'}
        
        # 各フラグの確認
        for status, key in flags.items():
            try:
                obj = s3.head_object(Bucket=bucket, Key=key)
                if status == 'error':
                    # エラー詳細を取得
                    error_obj = s3.get_object(Bucket=bucket, Key=key)
                    error_details = json.loads(error_obj['Body'].read())
                    return {'status': 'error', 'error_details': error_details}
                else:
                    return {'status': status}
            except ClientError as e:
                if e.response['Error']['Code'] != 'NotFound':
                    raise
        
        return {'status': 'pending'}
        
    except Exception as e:
        print(f"Status check error: {str(e)}")
        return {'status': 'error', 'error': str(e)}

def find_original_file(bucket, unique_key):
    """元ファイルを検索"""
    prefix = f"uploads/{unique_key}/original_"
    response = s3.list_objects_v2(
        Bucket=bucket,
        Prefix=prefix,
        MaxKeys=1
    )
    
    if 'Contents' in response and len(response['Contents']) > 0:
        return response['Contents'][0]['Key']
    return None

def convert_to_hls(input_file, output_dir, output_playlist):
    """FFmpegを使用してHLS形式に変換"""
    cmd = [
        'ffmpeg',
        '-i', input_file,
        '-c:v', 'libx264',
        '-c:a', 'aac',
        '-hls_time', '10',
        '-hls_list_size', '0',
        '-hls_segment_filename', os.path.join(output_dir, 'segment_%03d.ts'),
        '-f', 'hls',
        output_playlist
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"FFmpeg conversion failed: {result.stderr}")

def upload_converted_files(local_dir, bucket, unique_key):
    """変換済みファイルをアップロードバケットに保存"""
    for root, dirs, files in os.walk(local_dir):
        for file in files:
            local_path = os.path.join(root, file)
            relative_path = os.path.relpath(local_path, local_dir)
            s3_key = f"uploads/{unique_key}/converted/{relative_path}".replace('\\', '/')
            
            content_type = 'application/x-mpegURL' if file.endswith('.m3u8') else 'video/MP2T'
            
            s3.upload_file(
                local_path,
                bucket,
                s3_key,
                ExtraArgs={'ContentType': content_type}
            )

def upload_to_s3(local_dir, bucket, key_prefix):
    """ディレクトリ内のファイルをS3にアップロード"""
    uploaded_files = []
    
    for root, dirs, files in os.walk(local_dir):
        for file in files:
            local_path = os.path.join(root, file)
            relative_path = os.path.relpath(local_path, local_dir)
            s3_key = os.path.join(key_prefix, relative_path).replace('\\', '/')
            
            content_type = 'application/x-mpegURL' if file.endswith('.m3u8') else 'video/MP2T'
            
            s3.upload_file(
                local_path,
                bucket,
                s3_key,
                ExtraArgs={'ContentType': content_type}
            )
            uploaded_files.append(s3_key)
    
    return uploaded_files