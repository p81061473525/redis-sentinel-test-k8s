#!/usr/bin/env python3

import datetime
import time

import redis
import redis.sentinel


sentinel = redis.sentinel.Sentinel(
    sentinels=[
        ('127.0.0.1', 26379),
    ],
)

while True:
    try:
        master = sentinel.master_for('mymaster')
        master.set('foo', 'bar')
        result = master.get('foo')
        print(datetime.datetime.now(), 'ok:', result)
    except Exception as ex:
        print(datetime.datetime.now(), 'error:', ex)
    time.sleep(1)
