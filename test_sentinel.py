import os
from redis.sentinel import Sentinel
from redis import Redis

# Load .env from same directory
env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'env_example')
with open(env_path) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, val = line.split('=', 1)
            os.environ.setdefault(key.strip(), val.strip())

REDIS_IP = os.environ['REDIS_IP']
REDIS_PASSWORD = os.environ['REDIS_PASSWORD']

SENTINELS = [
    (REDIS_IP, 26379),
]

sentinel = Sentinel(SENTINELS, password=REDIS_PASSWORD, socket_timeout=5)

print("=== Sentinel Connection Test ===")

master_addr = sentinel.discover_master('mymaster')
replica_addrs = sentinel.discover_slaves('mymaster')
print(f"Master:   {master_addr}")
print(f"Replicas: {replica_addrs}")
print()

# Master SET / GET via sentinel
master = sentinel.master_for('mymaster', password=REDIS_PASSWORD, socket_timeout=5)
master.set('test_key', 'hello from sentinel')
val = master.get('test_key')
print(f"[Master  {master_addr[0]}:{master_addr[1]}] SET -> GET: {val.decode()}")

# Replicas GET via sentinel discovered addresses
for i, (ip, port) in enumerate(replica_addrs, start=1):
    replica = Redis(host=ip, port=port, password=REDIS_PASSWORD, socket_timeout=5)
    val = replica.get('test_key')
    print(f"[Slave{i}  {ip}:{port}] GET test_key: {val.decode()}")

print()
print("=== All passed ===")
