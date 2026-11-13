"""HTML rendering for report metadata; imported cell text is always escaped."""
from html import escape


class TrustedHTML(str):
    """Markup authored by this report, never values copied from imported data."""


def table(headers, rows):
    def cell(value):
        return str(value) if isinstance(value, TrustedHTML) else escape(str(value))

    heading = ''.join('<th>' + escape(str(value)) + '</th>' for value in headers)
    body = ''.join('<tr>' + ''.join('<td>' + cell(value) + '</td>' for value in row)
                   + '</tr>' for row in rows)
    return '<div class="table"><table><thead><tr>' + heading + '</tr></thead><tbody>' + body + '</tbody></table></div>'
