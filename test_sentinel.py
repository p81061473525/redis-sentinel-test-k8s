from redis.sentinel import Sentinel
from redis import Redis

SENTINELS = [
    ('35.78.204.205', 26379),
    ('35.78.204.205', 26380),
    ('35.78.204.205', 26381),
]

sentinel = Sentinel(SENTINELS, password='1234', socket_timeout=5)

print("=== Sentinel Connection Test ===")

master_addr = sentinel.discover_master('mymaster')
replica_addrs = sentinel.discover_slaves('mymaster')
print(f"Master:   {master_addr}")
print(f"Replicas: {replica_addrs}")
print()

# Master SET / GET via sentinel
master = sentinel.master_for('mymaster', password='1234', socket_timeout=5)
master.set('test_key', 'hello from sentinel')
val = master.get('test_key')
print(f"[Master  {master_addr[0]}:{master_addr[1]}] SET -> GET: {val.decode()}")

# Replicas GET via sentinel discovered addresses
for i, (ip, port) in enumerate(replica_addrs, start=1):
    replica = Redis(host=ip, port=port, password='1234', socket_timeout=5)
    val = replica.get('test_key')
    print(f"[Slave{i}  {ip}:{port}] GET test_key: {val.decode()}")

print()
print("=== All passed ===")
