"""Swift message lexer and source/catalog consistency, without executing Swift input."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('catalog', ROOT/'Tools/Localization/catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CatalogTests(unittest.TestCase):
    def keys(self, source):
        lexer = catalog.SwiftStrings(source); lexer.code()
        return [n['key'] for n in lexer.nodes]

    def test_nested_interpolation_preserves_expressions(self):
        source = r'let text = "数量 \(String(format: "%.2f", value)) \(flag ? "成功" : "失败")"'
        keys = self.keys(source)
        self.assertEqual(keys, ['成功', '失败', '数量 ⟦0⟧ ⟦1⟧'])

    def test_comments_raw_strings_and_escapes(self):
        source = '// "跳过"\n/* outer /* "忽略" */ */\n' + r'let text = #"提示 \#(value) \n"#'
        self.assertEqual(self.keys(source), ['提示 ⟦0⟧ \\n'])
        self.assertEqual(self.keys(r'let t = "标题 \"引用\"\n正文"'), ['标题 "引用"\n正文'])

    def test_multiline_indentation(self):
        source = 'let t = """\n    第一行\n    第二行\n    """'
        self.assertEqual(self.keys(source), ['第一行\n第二行'])

    def test_nested_call_arguments_are_not_split_inside_values(self):
        tail = ', ["value,one", "two"], flag ? function(a, b) : other, { x, y in x + y }'
        self.assertEqual(len(catalog.split_arguments(tail)), 3)

    def test_native_catalogs_and_source_keys_match(self):
        report, calls = catalog.check(ROOT)
        self.assertEqual(report['issues'], [])
        self.assertEqual(report['languages'], ['en', 'zh-Hans'])
        self.assertGreater(report['keys'], 1600)
        self.assertGreater(len(calls), 1600)



if __name__ == '__main__': unittest.main()
