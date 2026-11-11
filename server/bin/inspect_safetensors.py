#!/usr/bin/env python3
"""Bounded, CPU-only safetensors inspection. Does not deserialize executable code."""
import collections
import hashlib
import json
import os
import struct
import sys

MAX_HEADER = 16 * 1024 * 1024
BITS = {'BOOL': 8, 'U8': 8, 'I8': 8, 'F8_E4M3': 8, 'F8_E5M2': 8,
        'I16': 16, 'U16': 16, 'F16': 16, 'BF16': 16, 'I32': 32,
        'U32': 32, 'F32': 32, 'F64': 64, 'I64': 64, 'U64': 64}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate header key')
        result[key] = value
    return result


def inspect(path):
    with open(path, 'rb') as stream:
        size = os.fstat(stream.fileno()).st_size
        prefix = stream.read(8)
        if len(prefix) != 8:
            raise ValueError('Missing safetensors header')
        length, = struct.unpack('<Q', prefix)
        if not 2 <= length <= MAX_HEADER or length + 8 > size:
            raise ValueError('Invalid or oversized header')
        raw = stream.read(length)
        if not raw.startswith(b'{'):
            raise ValueError('Header must begin with an object')
        header = json.loads(raw, object_pairs_hook=unique_object)
        if not isinstance(header, dict):
            raise ValueError('Header must be an object')
        metadata = header.pop('__metadata__', {})
        if not isinstance(metadata, dict) or any(not isinstance(v, str) for v in metadata.values()):
            raise ValueError('Metadata must contain string values')
        ranges, dtypes, ranks = [], collections.Counter(), set()
        parameters = 0
        adapters = 0
        for name, tensor in header.items():
            if not isinstance(tensor, dict):
                raise ValueError('Invalid tensor descriptor')
            shape, dtype, offsets = tensor.get('shape'), tensor.get('dtype'), tensor.get('data_offsets')
            if not isinstance(shape, list) or any(type(d) is not int or d < 0 for d in shape):
                raise ValueError('Invalid tensor shape')
            if not isinstance(dtype, str) or dtype not in BITS:
                raise ValueError('Unsupported tensor dtype')
            count = 1
            for dimension in shape:
                count *= dimension
            if (not isinstance(offsets, list) or len(offsets) != 2
                    or any(type(v) is not int for v in offsets)
                    or not 0 <= offsets[0] <= offsets[1] <= size - 8 - length
                    or offsets[1] - offsets[0] != (count * BITS[dtype] + 7) // 8):
                raise ValueError('Invalid tensor data range or byte count')
            ranges.append(tuple(offsets))
            dtypes[dtype] += 1
            parameters += count
            if '.lora_A.' in name or '.lora_down.' in name:
                adapters += 1
                if len(shape) >= 2:
                    ranks.add(shape[0])
            elif '.lora_B.' in name or '.lora_up.' in name:
                adapters += 1
        end = 0
        for start, stop in sorted(ranges):
            if start != end:
                raise ValueError('Overlapping tensors or gaps in data')
            end = stop
        if end != size - 8 - length:
            raise ValueError('Truncated file or unreferenced data')
        digest = hashlib.sha256()
        stream.seek(0)
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    declared = metadata.get('ss_base_model_version') or metadata.get('modelspec.architecture')
    evidence = []
    if declared:
        evidence.append('Embedded metadata declares ' + declared + '; this is not proof of provenance.')
    if adapters:
        evidence.append('LoRA tensor names detected; rank inferred from down-projection shapes.')
    return dict(scanner_version=1, size_bytes=size, sha256=digest.hexdigest(),
                header_bytes=length, tensor_count=len(header), parameter_count=parameters,
                dtypes=dict(dtypes), lora_ranks=sorted(ranks),
                file_type='LoRA adapter' if adapters else 'Tensor weights (unclassified)',
                model_family=declared, identification='Declared in metadata' if declared else 'Unknown',
                exact_base_model=metadata.get('ss_sd_model_name') or None,
                evidence=evidence, metadata=metadata, tensors=header)


if __name__ == '__main__':
    try:
        print(json.dumps(inspect(sys.argv[1]), ensure_ascii=True, allow_nan=False))
    except (ValueError, OSError, IndexError) as error:
        print('Inspection failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
