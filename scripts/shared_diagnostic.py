"""Read immutable shared diagnostics; retain original files when exporting."""
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import uuid
import zlib

MAX_BYTES = 16 * 1024 * 1024

def valid_name(name):
    if not (name.startswith('shared-') and name.endswith('.hqdiag')) or '/' in name:
        return False
    try:
        uuid.UUID(name[7:-7])
        return True
    except (ValueError, TypeError):
        return False

def read(path):
    if not valid_name(path.name):
        raise ValueError('invalid shared filename')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 12 < info.st_size <= MAX_BYTES:
            raise ValueError('invalid shared file')
        with os.fdopen(os.dup(fd), 'rb') as source:
            data = source.read(MAX_BYTES + 1)
        after = os.fstat(fd)
        if any(getattr(after,k)!=getattr(info,k) for k in ("st_dev","st_ino","st_mode","st_uid","st_nlink","st_size","st_mtime_ns","st_ctime_ns")) or len(data) != info.st_size:
            raise ValueError('shared file changed')
    finally:
        os.close(fd)
    if data[:8] != b'HQSHR001':
        raise ValueError('invalid shared magic')
    size, = struct.unpack('<I', data[8:12])
    if not 0 < size <= 1024 * 1024 or 12 + size >= len(data):
        raise ValueError('invalid shared header length')
    header = json.loads(data[12:12 + size])
    body = data[12 + size:]
    if header['schema'] != 1 or not 0 < header['rawBytes'] <= MAX_BYTES or hashlib.sha256(body).hexdigest() != header['digest']:
        raise ValueError('invalid shared payload digest or size')
    uuid.UUID(header['owner']); uuid.UUID(header['runID'])
    if header.get('metadataBase') and not valid_name(header['metadataBase']):
        raise ValueError('invalid metadata dependency')
    if header['compressed']:
        decoder = zlib.decompressobj(-15)  # Apple Compression uses raw DEFLATE.
        raw = decoder.decompress(body, header['rawBytes'] + 1)
        if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise ValueError('invalid compressed payload')
    else:
        raw = body
    if len(raw) != header['rawBytes']:
        raise ValueError('invalid decoded length')
    payload = json.loads(raw)
    if len(payload['frames']) != header['ownFrameCount'] or len(payload['fields']) > 4096 or len(set(payload['fields'])) != len(payload['fields']):
        raise ValueError('invalid shared dictionary')
    return header, payload

def unpack(encoded, fields):
    data = base64.b64decode(encoded, validate=True)
    if len(data) > 65536:
        raise ValueError('oversized frame')
    offset = 0
    def take(count):
        nonlocal offset
        if not 0 <= count <= len(data) - offset:
            raise ValueError('truncated packed value')
        result = data[offset:offset+count]; offset += count
        return result
    def number():
        result = 0
        for i in range(10):
            b = take(1)[0]
            if i == 9 and b > 1:
                raise ValueError('integer overflow')
            result |= (b & 127) << (i*7)
            if b < 128:
                return result
        raise ValueError('integer overflow')
    def value(depth=0):
        if depth >= 32:
            raise ValueError('packed nesting')
        tag = take(1)[0]
        if tag == 0: return None
        if tag == 1: return False
        if tag == 2: return True
        if tag == 3: return number()
        if tag == 4: return -1 - number()
        if tag == 5: return struct.unpack('<d', take(8))[0]
        if tag == 6: return take(number()).decode('utf-8')
        if tag in (7, 8):
            count, = struct.unpack('<I', take(4))
            if count > len(data): raise ValueError('invalid packed count')
            if tag == 8: return [value(depth+1) for _ in range(count)]
            result = {}
            for _ in range(count):
                index = number()
                if index >= len(fields) or fields[index] in result:
                    raise ValueError('invalid dictionary field')
                result[fields[index]] = value(depth+1)
            return result
        raise ValueError('unknown packed tag')
    result = value()
    if offset != len(data): raise ValueError('unused packed bytes')
    return result

def expand(path):
    path = Path(path)
    seen = set()
    def meta(name):
        if name in seen or len(seen) >= 64: raise ValueError('metadata cycle')
        seen.add(name)
        header, payload = read(path.parent / name)
        result = {}
        if header.get('metadataBase'):
            prior, _, result = meta(header['metadataBase'])
            if prior['owner'] != header['owner']: raise ValueError('foreign metadata')
        for change in payload['changes']:
            keys = change['path']
            if not keys:
                if 'value' not in change: raise ValueError('invalid root deletion')
                result = change['value']; continue
            if len(keys) >= 32: raise ValueError('metadata nesting')
            target = result
            for key in keys[:-1]: target = target[key]
            if 'value' in change: target[keys[-1]] = change['value']
            else: target.pop(keys[-1], None)
        return header, payload, result
    header, payload, result = meta(path.name)
    frames = []; previous_name = None; previous = None
    for ref in header['ranges']:
        name = ref['file']
        if not valid_name(name): raise ValueError('invalid frame dependency')
        if name == path.name: source = payload
        elif name == previous_name: source = previous
        else:
            owner, source = read(path.parent/name)
            if (owner['owner'], owner['runID']) != (header['owner'], header['runID']): raise ValueError('foreign frames')
            previous_name, previous = name, source
        start, count = ref['first'], ref['count']
        if not 0 <= start <= len(source['frames']) or not 0 < count <= len(source['frames']) - start: raise ValueError('invalid frame range')
        if len(frames) + count > 65536: raise ValueError('too many frames')
        for packet in source['frames'][start:start+count]:
            frame = unpack(packet['data'], source['fields'])
            if (frame['sequence'], frame['milliseconds']) != (packet['sequence'], packet['milliseconds']): raise ValueError('frame identity mismatch')
            frames.append(frame)
    if len(frames) != header['frameCount']: raise ValueError('frame count mismatch')
    result['frames'] = frames
    return result
