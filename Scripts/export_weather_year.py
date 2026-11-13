#!/usr/bin/env python3
"""Export Cagbang weather/solar history for energy comparisons (stdlib only)."""
import argparse
import calendar
import hashlib
import json
import os
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
import tempfile
from urllib.parse import urlencode
from urllib.request import urlopen
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
TZ = ZoneInfo('Asia/Manila')
HOURLY = ['temperature_2m', 'relative_humidity_2m', 'dew_point_2m',
          'apparent_temperature', 'precipitation', 'rain', 'weather_code',
          'cloud_cover', 'wind_speed_10m', 'wind_direction_10m',
          'shortwave_radiation', 'direct_radiation', 'diffuse_radiation',
          'direct_normal_irradiance', 'terrestrial_radiation',
          'sunshine_duration', 'is_day']
DAILY = ['weather_code', 'temperature_2m_max', 'temperature_2m_min',
         'temperature_2m_mean', 'apparent_temperature_max',
         'apparent_temperature_min', 'apparent_temperature_mean',
         'sunrise', 'sunset', 'daylight_duration', 'sunshine_duration',
         'precipitation_sum', 'rain_sum', 'wind_speed_10m_max',
         'shortwave_radiation_sum']
BASES = (24, 26, 28)


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.weather-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def strict_sum(values):
    return round(sum(values), 6) if values and all(v is not None for v in values) else None


def strict_mean(values):
    total = strict_sum(values)
    return round(total / len(values), 4) if total is not None else None


def transform(raw_dir, year, through):
    start = datetime(year, 1, 1, tzinfo=TZ)
    stop = datetime.combine(through + timedelta(days=1), datetime.min.time(), TZ)
    samples, source_days, grids, hashes = {}, {}, [], {}
    hourly_units = daily_units = None
    for path in sorted(raw_dir.glob('[0-9][0-9].json')):
        raw_bytes = path.read_bytes()
        raw = json.loads(raw_bytes)
        if raw.get('error'):
            raise ValueError(raw)
        assert raw['timezone'] == 'Asia/Manila' and raw['utc_offset_seconds'] == 28800
        if hourly_units is not None:
            assert raw['hourly_units'] == hourly_units
            assert raw['daily_units'] == daily_units
        hourly_units, daily_units = raw['hourly_units'], raw['daily_units']
        for key, required in [('hourly', HOURLY), ('daily', DAILY)]:
            table = raw[key]
            assert all(v in table for v in required)
            assert all(len(v) == len(table['time']) for v in table.values())
        grid = {k: raw[k] for k in ('latitude', 'longitude', 'elevation')}
        if grid not in grids:
            grids.append(grid)
        hashes[path.name] = hashlib.sha256(raw_bytes).hexdigest()
        for i, timestamp in enumerate(raw['hourly']['time']):
            endpoint = datetime.fromisoformat(timestamp).replace(tzinfo=TZ)
            if start <= endpoint <= stop:
                assert endpoint not in samples, 'Duplicate source hour'
                samples[endpoint] = {k: raw['hourly'][k][i] for k in HOURLY}
        for i, day in enumerate(raw['daily']['time']):
            if start.date() <= date.fromisoformat(day) <= through:
                assert day not in source_days, 'Duplicate source date'
                source_days[day] = {k: raw['daily'][k][i] for k in DAILY}

    hourly, by_day = [], defaultdict(list)
    endpoint = start + timedelta(hours=1)
    missing_timestamps = []
    while endpoint <= stop:
        values = samples.get(endpoint)
        if values is None:
            missing_timestamps.append(endpoint.isoformat())
            values = dict.fromkeys(HOURLY)
        interval_start = endpoint - timedelta(hours=1)
        row = {'time': interval_start.isoformat(), 'interval_end': endpoint.isoformat(),
               'source_sample_time': endpoint.isoformat(), **values}
        ghi = values['shortwave_radiation']
        row['solar_energy_kwh_m2'] = round(ghi / 1000, 6) if ghi is not None else None
        t = values['temperature_2m']
        row['cooling_degree_hours'] = {
            str(b): round(max(t - b, 0), 3) if t is not None else None for b in BASES}
        hourly.append(row)
        by_day[interval_start.date().isoformat()].append(row)
        endpoint += timedelta(hours=1)

    daily = []
    for day, hours in sorted(by_day.items()):
        source = source_days.get(day, dict.fromkeys(DAILY))
        sunshine = strict_sum([h['sunshine_duration'] for h in hours])
        daylight = source['daylight_duration']
        fraction = sunshine / daylight if sunshine is not None and daylight else None
        temperatures = [h['temperature_2m'] for h in hours]
        ghi = [h['shortwave_radiation'] for h in hours]
        day_hours = [h for h in hours if h['is_day'] == 1]
        row = {
            'date': day, 'weather_code': source['weather_code'],
            'temperature_mean_c': source['temperature_2m_mean'],
            'temperature_min_c': source['temperature_2m_min'],
            'temperature_max_c': source['temperature_2m_max'],
            'apparent_temperature_mean_c': source['apparent_temperature_mean'],
            'apparent_temperature_max_c': source['apparent_temperature_max'],
            'relative_humidity_mean_pct': strict_mean([h['relative_humidity_2m'] for h in hours]),
            'cloud_cover_mean_pct': strict_mean([h['cloud_cover'] for h in hours]),
            'daylight_cloud_cover_mean_pct': strict_mean([h['cloud_cover'] for h in day_hours]),
            'precipitation_mm': strict_sum([h['precipitation'] for h in hours]),
            'wind_speed_max_m_s': source['wind_speed_10m_max'],
            'solar_energy_kwh_m2': strict_sum([h['solar_energy_kwh_m2'] for h in hours]),
            'peak_hourly_ghi_w_m2': max(ghi) if all(v is not None for v in ghi) else None,
            'sunshine_hours': round(sunshine / 3600, 6) if sunshine is not None else None,
            'daylight_hours': round(daylight / 3600, 6) if daylight is not None else None,
            'sunshine_fraction': round(fraction, 6) if fraction is not None else None,
            'is_sunny': fraction >= 0.8 if fraction is not None else None,
            'cooling_degree_hours': {str(b): strict_sum([h['cooling_degree_hours'][str(b)] for h in hours]) for b in BASES},
            'hours_above_temperature': {str(b): sum(t > b for t in temperatures) if all(t is not None for t in temperatures) else None for b in BASES},
            'source_daily': source,
        }
        daily.append(row)
    months = defaultdict(list)
    for row in daily:
        months[row['date'][:7]].append(row)
    monthly = []
    for month, days in sorted(months.items()):
        monthly.append({
            'month': month, 'days': len(days),
            'complete_calendar_month': len(days) == calendar.monthrange(year, int(month[-2:]))[1],
            'sunny_days': sum(d['is_sunny'] is True for d in days),
            'unclassified_days': sum(d['is_sunny'] is None for d in days),
            'solar_energy_kwh_m2': strict_sum([d['solar_energy_kwh_m2'] for d in days]),
            'sunshine_hours': strict_sum([d['sunshine_hours'] for d in days]),
            'temperature_mean_c': strict_mean([d['temperature_mean_c'] for d in days]),
            'precipitation_mm': strict_sum([d['precipitation_mm'] for d in days]),
            'cooling_degree_hours': {str(b): strict_sum([d['cooling_degree_hours'][str(b)] for d in days]) for b in BASES},
        })
    missing = {k: sum(h[k] is None for h in hourly) for k in HOURLY}
    missing_daily = {k: sum(d['source_daily'][k] is None for d in daily) for k in DAILY}
    manifest_path = raw_dir / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    return {
        'schema_version': 1,
        'location': {'name': 'Cagbang, Oton, Iloilo, Philippines',
                     'requested_latitude': 10.6992, 'requested_longitude': 122.5018,
                     'coordinate_source': 'https://www.philatlas.com/visayas/r06/iloilo/oton/cagbang.html',
                     'returned_model_grid_points': grids},
        'period': {'start_date': start.date().isoformat(), 'end_date': through.isoformat(),
                   'timezone': 'Asia/Manila', 'utc_offset_seconds': 28800,
                   'complete_days_only': True},
        'source': {'provider': 'Open-Meteo', 'model': 'ecmwf_ifs',
                   'type': 'gridded historical model archive, not an on-site sensor',
                   'nominal_resolution_km': 9,
                   'documentation': 'https://open-meteo.com/en/docs/historical-weather-api',
                   'attribution': 'Weather data by Open-Meteo, ECMWF IFS; CC BY 4.0',
                   'license': 'https://creativecommons.org/licenses/by/4.0/',
                   'retrieval_manifest': manifest, 'raw_sha256': hashes},
        'definitions': {
            'hourly_time': 'time is interval start; interval_end is exclusive for energy joins. Radiation is the provider mean over the preceding hour ending at source_sample_time; precipitation and sunshine are preceding-hour sums. Other weather values are instantaneous samples at source_sample_time (the right endpoint), not hourly averages.',
            'solar_energy_kwh_m2': 'Global horizontal irradiation (GHI) integrated over each 1-hour interval: shortwave_radiation W/m² / 1000. Daily values sum the 24 intervals of the local day. Not electricity produced by panels.',
            'radiation_fields': 'shortwave_radiation=GHI; direct_radiation=direct horizontal; diffuse_radiation=DHI; direct_normal_irradiance=DNI. terrestrial_radiation is extraterrestrial horizontal solar radiation, not clear-sky surface radiation.',
            'sunshine': 'Provider sunshine duration uses direct normal irradiance >120 W/m². Derived duration is model-based, not a measured sunshine recorder.',
            'is_sunny': 'Custom comparison flag: sunshine_duration / daylight_duration >= 0.8. Not an official sunny-day classification; a flagged day can also have rain. No clipping of the underlying fraction.',
            'cooling_degree_hours': 'For each base temperature (24,26,28 °C), sum max(temperature_2m - base, 0) × 1 h using endpoint samples. Unit °C·h. A heat-load proxy, not measured cooling energy or a known thermostat setting.',
            'hours_above_temperature': 'Number of hourly endpoint samples exceeding the base, interpreted as approximate hours. Not continuous measured duration.',
            'daily_weather': 'Daily min/max/mean temperatures, apparent temperatures, weather code and max wind retain provider daily aggregation. Derived humidity/cloud means and cooling proxies use 24 right-endpoint samples. source_daily preserves all original provider daily fields and units.',
            'weather_code': 'WMO weather interpretation code; lookup in weather_codes.',
            'missing_values': 'null means unavailable, never zero. Sums/means become null if any required value is missing; missing hours are retained.',
            'comparison': 'Join daily energy by date and hourly energy by [time, interval_end) in Asia/Manila. Actual PV output and electricity consumption must come from the existing meter/inverter archive; they are not estimated here.',
            'limitations': 'Approximate barangay coordinates. Model grid cannot resolve individual roofs, shade or local showers. Panel tilt, orientation, installed kWp, inverter limits and cooling equipment schedules are unknown. This dataset does not establish a temperature-consumption correlation by itself.',
        },
        'hourly_units': {**{k: v for k, v in hourly_units.items() if k != 'time'},
                         'solar_energy_kwh_m2': 'kWh/m²', 'cooling_degree_hours': '°C·h'},
        'source_daily_units': daily_units,
        'weather_codes': {'0': 'Clear sky', '1': 'Mainly clear', '2': 'Partly cloudy',
                          '3': 'Overcast', '45': 'Fog', '48': 'Depositing rime fog',
                          '51': 'Light drizzle', '53': 'Moderate drizzle', '55': 'Dense drizzle',
                          '56': 'Light freezing drizzle', '57': 'Dense freezing drizzle',
                          '61': 'Slight rain', '63': 'Moderate rain', '65': 'Heavy rain',
                          '66': 'Light freezing rain', '67': 'Heavy freezing rain',
                          '71': 'Slight snow', '73': 'Moderate snow', '75': 'Heavy snow',
                          '77': 'Snow grains', '80': 'Slight rain showers',
                          '81': 'Moderate rain showers', '82': 'Violent rain showers',
                          '85': 'Slight snow showers', '86': 'Heavy snow showers',
                          '95': 'Thunderstorm', '96': 'Thunderstorm with slight hail',
                          '99': 'Thunderstorm with heavy hail'},
        'coverage': {'days': len(daily), 'hours': len(hourly),
                     'missing_source_timestamps': missing_timestamps,
                     'null_hourly_values_by_variable': missing,
                     'null_source_daily_values_by_variable': missing_daily,
                     'complete': not missing_timestamps and not any(missing.values()) and not any(missing_daily.values())},
        'summary': {'sunny_days': sum(d['is_sunny'] is True for d in daily),
                    'solar_energy_kwh_m2': strict_sum([d['solar_energy_kwh_m2'] for d in daily]),
                    'sunshine_hours': strict_sum([d['sunshine_hours'] for d in daily])},
        'sunny_dates': [d['date'] for d in daily if d['is_sunny'] is True],
        'monthly': monthly, 'daily': daily, 'hourly': hourly,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--year', type=int, default=datetime.now(TZ).year)
    parser.add_argument('--through', type=date.fromisoformat)
    parser.add_argument('--from-cache', action='store_true', help='Rebuild without network requests')
    args = parser.parse_args()
    yesterday = datetime.now(TZ).date() - timedelta(days=1)
    through = args.through or min(date(args.year, 12, 31), yesterday)
    if through.year != args.year or through > yesterday:
        parser.error('--through must be a completed day in --year')
    raw_dir = ROOT / 'generated' / f'weather-{args.year}-responses'
    if not args.from_cache:
        requests = []
        # Include the next midnight to complete the last preceding-hour interval.
        query_end = through + timedelta(days=1)
        for month in range(1, query_end.month + 1 if query_end.year == args.year else 13):
            begin = date(args.year, month, 1)
            end = min(date(args.year, month, calendar.monthrange(args.year, month)[1]), query_end)
            if month == 12 and query_end.year > args.year:
                end = query_end
            params = {'latitude': 10.6992, 'longitude': 122.5018,
                      'start_date': begin.isoformat(), 'end_date': end.isoformat(),
                      'hourly': ','.join(HOURLY), 'daily': ','.join(DAILY),
                      'timezone': 'Asia/Manila', 'models': 'ecmwf_ifs', 'wind_speed_unit': 'ms'}
            url = 'https://archive-api.open-meteo.com/v1/archive?' + urlencode(params)
            print(f'Downloading {begin} through {end}', flush=True)
            with urlopen(url, timeout=120) as response:
                data = json.load(response)
            if data.get('error'):
                raise RuntimeError(data)
            save(raw_dir / f'{month:02d}.json', data)
            requests.append({'month': f'{month:02d}', 'start': str(begin), 'end': str(end), 'url': url})
        save(raw_dir / 'manifest.json', {'provider': 'Open-Meteo Historical Weather API',
             'model': 'ecmwf_ifs', 'retrieved_on': datetime.now(TZ).isoformat(),
             'retrieval_method': 'Python urllib.request', 'requests': requests})
    result = transform(raw_dir, args.year, through)
    output = ROOT / 'generated' / f'weather-cagbang-{args.year}.json'
    save(output, result)
    print(json.dumps({'output': str(output), 'coverage': result['coverage'],
                      'summary': result['summary']}, ensure_ascii=False, indent=2))
    return 0 if result['coverage']['complete'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
