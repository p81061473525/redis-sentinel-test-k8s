import redis
import socket
from kubernetes import client, config
from flask import Flask, Response

NAMESPACE = "redis"  # 你的 namespace
SENTINEL_PORT = 26379

app = Flask(__name__)

def is_sentinel(host, port):
    try:
        r = redis.StrictRedis(host=host, port=port, socket_connect_timeout=2)
        # Sentinel 支援 SENTINEL PING 指令
        resp = r.execute_command("SENTINEL PING")
        return resp == b'PONG'
    except redis.exceptions.ResponseError:
        # 普通 Redis 會回 unknown command
        return False
    except Exception:
        return False

def get_redis_i_services():
    # 載入 k8s 設定（在 Pod 內自動載入）
    try:
        config.load_incluster_config()
    except Exception:
        # 若在本機測試，則載入本地 kubeconfig
        config.load_kube_config()
    v1 = client.CoreV1Api()
    # 取得所有 service
    services = v1.list_namespaced_service(namespace=NAMESPACE)
    # 過濾名稱符合 redis-i*
    redis_i_services = [svc.metadata.name for svc in services.items if svc.metadata.name.startswith("redis-i")]
    return redis_i_services

@app.route("/metrics")
def metrics():
    output = []
    redis_i_services = get_redis_i_services()
    for name in redis_i_services:
        host = f"{name}.{NAMESPACE}.svc.cluster.local"
        try:
            ip = socket.gethostbyname(host)
        except Exception:
            status = 0
        else:
            status = 1 if is_sentinel(host, SENTINEL_PORT) else 0
        # Prometheus metrics 格式
        output.append(f'redis_sentinel_status{{service="{name}"}} {status}')
    return Response("\n".join(output) + "\n", mimetype="text/plain")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)