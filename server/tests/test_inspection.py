"""Inspection behavior and rejection of malformed/untrusted file structures."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('scanner', Path(__file__).parents[1] / 'bin/inspect_safetensors.py')
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class InspectionTests(unittest.TestCase):
    def scan(self, header, data=b'\0' * 16):
        raw = json.dumps(header).encode() if isinstance(header, dict) else header
        with tempfile.NamedTemporaryFile() as file:
            file.write(struct.pack('<Q', len(raw)) + raw + data)
            file.flush()
            return scanner.inspect(file.name)

    def tensor(self, **changes):
        return dict(dtype='BF16', shape=[2, 4], data_offsets=[0, 16], **changes)

    def test_lora_without_base_metadata_stays_unknown(self):
        result = self.scan({'block.lora_A.weight': self.tensor()})
        self.assertEqual(result['file_type'], 'LoRA adapter')
        self.assertEqual(result['lora_ranks'], [2])
        self.assertIsNone(result['model_family'])
        self.assertIsNone(result['exact_base_model'])
        self.assertEqual(result['parameter_count'], 8)
        self.assertEqual(len(result['sha256']), 64)

    def test_model_declaration_is_not_exact_checkpoint(self):
        result = self.scan({'__metadata__': {'ss_base_model_version': 'qwen_image'}, 'w': self.tensor()})
        self.assertEqual(result['model_family'], 'qwen_image')
        self.assertEqual(result['identification'], 'Declared in metadata')
        self.assertIsNone(result['exact_base_model'])

    def test_truncated_data(self):
        with self.assertRaises(ValueError):
            self.scan({'w': self.tensor()}, b'\0' * 15)

    def test_overlapping_tensors(self):
        with self.assertRaises(ValueError):
            self.scan({'a': self.tensor(), 'b': self.tensor()})

    def test_wrong_shape_byte_count(self):
        tensor = self.tensor()
        tensor['shape'] = [3, 4]
        with self.assertRaises(ValueError):
            self.scan({'w': tensor})

    def test_duplicate_header_keys(self):
        with self.assertRaises(ValueError):
            self.scan(b'{"w":{},"w":{}}')

    def test_non_string_metadata(self):
        with self.assertRaises(ValueError):
            self.scan({'__metadata__': {'model': 42}, 'w': self.tensor()})

    def test_unreferenced_trailing_data(self):
        with self.assertRaises(ValueError):
            self.scan({'w': self.tensor()}, b'\0' * 17)

    def test_oversized_header(self):
        with tempfile.NamedTemporaryFile() as file:
            file.write(struct.pack('<Q', scanner.MAX_HEADER + 1))
            file.flush()
            with self.assertRaises(ValueError):
                scanner.inspect(file.name)


if __name__ == '__main__':
    unittest.main()
