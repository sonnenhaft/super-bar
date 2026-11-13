"""Test the pure renderer without loading private report data or writing output."""
import importlib.util
from pathlib import Path
import unittest

source = Path(__file__).parents[1] / 'research/solar-2026/html_output.py'
spec = importlib.util.spec_from_file_location('report_html_output', source)
html_output = importlib.util.module_from_spec(spec)
spec.loader.exec_module(html_output)


class ReportHTMLTests(unittest.TestCase):
    def test_imported_headers_and_bill_metadata_cannot_create_html(self):
        payload = '<img src=x onerror="alert(1)">'
        rendered = html_output.table([payload], [[payload], ['A & B']])
        self.assertNotIn('<img', rendered)
        self.assertIn('&lt;img', rendered)
        self.assertIn('&quot;alert(1)&quot;', rendered)
        self.assertIn('A &amp; B', rendered)

    def test_authored_markup_is_explicit_and_other_cells_remain_escaped(self):
        rendered = html_output.table(['Benefit'], [[html_output.TrustedHTML('<strong>42</strong>')],
                                                 ['<strong>untrusted</strong>']])
        self.assertIn('<td><strong>42</strong></td>', rendered)
        self.assertIn('&lt;strong&gt;untrusted&lt;/strong&gt;', rendered)
