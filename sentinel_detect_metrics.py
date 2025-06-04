from prometheus_client import Gauge, CollectorRegistry, generate_latest
from flask import Flask, Response
from redis.sentinel import Sentinel
import threading
import time

SENTINEL_HOSTS = [
    'redis-sentinel.redis-i1',
    'redis-sentinel.redis-i2',
    'redis-sentinel.redis-i3'
]
SENTINEL_PORT = 26379
MASTER_NAME = 'mymaster'
POLL_INTERVAL = 0.2
STABLE_COUNT = 3

# 自訂 registry，不帶預設 metrics
REGISTRY = CollectorRegistry()
failover_time_gauge = Gauge(
    'failover_time', 'Redis Sentinel failover duration (seconds)', ['namespace'], registry=REGISTRY
)

# 這裡預設所有 namespace failover_time=0
for host in SENTINEL_HOSTS:
    namespace = host.split('.')[-1]
    failover_time_gauge.labels(namespace=namespace).set(0)

# Flask app 提供 /metrics endpoint
app = Flask(__name__)

@app.route("/metrics")
def metrics():
    return Response(generate_latest(REGISTRY), mimetype="text/plain")

# 啟動 HTTP server (port 9121)
threading.Thread(target=lambda: app.run(host="0.0.0.0", port=9121), daemon=True).start()

sentinels = {}
for host in SENTINEL_HOSTS:
    try:
        sentinel = Sentinel([(host, SENTINEL_PORT)], socket_timeout=0.5)
        last_master = sentinel.discover_master(MASTER_NAME)
        sentinels[host] = {
            "sentinel": sentinel,
            "last_master": last_master,
            "in_failover": False,
            "failover_start_ts": None,
            "candidate_master": None,
            "stable_counter": 0,
        }
    except Exception as e:
        print(f"[{host}] Initialization error: {e}")

while True:
    for host, state in sentinels.items():
        try:
            sentinel = state["sentinel"]
            current_master = sentinel.discover_master(MASTER_NAME)

            if not state["in_failover"] and current_master != state["last_master"]:
                state["in_failover"] = True
                state["failover_start_ts"] = time.time()
                state["candidate_master"] = current_master
                state["stable_counter"] = 1
                state["last_master"] = current_master
                continue

            if state["in_failover"]:
                if state["candidate_master"] == current_master:
                    state["stable_counter"] += 1
                else:
                    state["candidate_master"] = current_master
                    state["stable_counter"] = 1
                if state["stable_counter"] >= STABLE_COUNT:
                    duration = time.time() - state["failover_start_ts"]
                    namespace = host.split('.')[-1]
                    failover_time_gauge.labels(namespace=namespace).set(duration)
                    state["in_failover"] = False
                    state["last_master"] = state["candidate_master"]
                    state["candidate_master"] = None
                    state["stable_counter"] = 0

        except Exception as e:
            pass
    time.sleep(POLL_INTERVAL)
