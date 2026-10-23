"""Speed of the real-time service from its log, without the warm-up chunks.

Reads the "Cam2V AR <index> [warmup|steady] | N frames | ... | generate X ms | Y fps" lines that the service logs for every
chunk, splits them into sessions (the chunk index restarts at 0), drops the chunks the service itself marks as warmup, and
reports for the rest the numbers the EdenLive report uses for its H100 table (section 5.4):

  generation throughput  total frames / total generate time       (the report's "Generation throughput", no condition processing)
  inter-chunk gap P95    95th percentile of the time between the log lines of successive chunks
  RTF                    total generate time / playback time of those frames, at --fps

The first chunk of each session is also printed on its own, because it is not steady state. A session with no steady chunks
(only warmup lines) is reported as such.

    python realtime/chunk_stats.py                       .eden_app.log next to this file
    python realtime/chunk_stats.py --log FILE [FILE ...] --fps 24
"""
import argparse
import re
import statistics
from datetime import datetime
from pathlib import Path

LINE = re.compile(
    r'^(?P<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) \|.*Cam2V AR (?P<index>\d+) \[(?P<phase>\w+)\] \| (?P<frames>\d+) frames'
    r' \| capture (?P<capture>[\d.]+) ms \(eval (?P<eval>[\d.]+), decode (?P<decode>[\d.]+)\) \| generate (?P<generate>[\d.]+) ms'
    r'(?:.*GPU mem (?P<alloc>[\d.]+) GiB allocated, (?P<peak>[\d.]+) peak, (?P<reserved>[\d.]+) reserved)?'
)


def parse(path):
    chunks = []
    for line in Path(path).read_text(errors='replace').splitlines():
        match = LINE.match(line)
        if match:
            chunks.append({
                'time': datetime.strptime(match['time'], '%Y-%m-%d %H:%M:%S.%f').timestamp(),
                'index': int(match['index']),
                'phase': match['phase'],
                'frames': int(match['frames']),
                'generate_ms': float(match['generate']),
                'capture_ms': float(match['capture']),
                'peak_gib': float(match['peak']) if match['peak'] else None,
                'reserved_gib': float(match['reserved']) if match['reserved'] else None,
            })
    return chunks


def sessions(chunks):
    current = []
    for chunk in chunks:
        if current and chunk['index'] <= current[-1]['index']:
            yield current
            current = []
        current.append(chunk)
    if current:
        yield current


def percentile(values, share):
    ordered = sorted(values)
    position = (len(ordered) - 1) * share
    low, high = int(position), min(int(position) + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def report(number, session, fps):
    first = session[0]
    started = datetime.fromtimestamp(first['time']).strftime('%m-%d %H:%M:%S')
    steady = [chunk for chunk in session if chunk['phase'] != 'warmup']
    print(f'session {number} ({started}): {len(session)} chunks, {len(session) - len(steady)} warmup, {len(steady)} steady')
    print(f'  first chunk: {first["frames"]} frames, generate {first["generate_ms"]:.0f} ms (not steady state, left out below)')
    if len(steady) < 2:
        print('  no steady chunks to report')
        return
    frames = sum(chunk['frames'] for chunk in steady)
    seconds = sum(chunk['generate_ms'] for chunk in steady) / 1000
    per_chunk = [chunk['frames'] * 1000 / chunk['generate_ms'] for chunk in steady]
    gaps = [(b['time'] - a['time']) * 1000 for a, b in zip(steady, steady[1:]) if b['index'] == a['index'] + 1]
    print(f'  generation throughput  {frames / seconds:7.2f} fps   ({frames} frames in {seconds:.1f} s of generate time)')
    print(f'  per-chunk fps          median {statistics.median(per_chunk):6.2f}   min {min(per_chunk):6.2f}   max {max(per_chunk):6.2f}')
    print(f'  generate per chunk     median {statistics.median(chunk["generate_ms"] for chunk in steady):6.0f} ms   '
          f'P95 {percentile([chunk["generate_ms"] for chunk in steady], 0.95):6.0f} ms   ({statistics.median(chunk["frames"] for chunk in steady):.0f} frames)')
    if gaps:
        print(f'  inter-chunk gap P95    {percentile(gaps, 0.95):7.0f} ms   (median {statistics.median(gaps):.0f} ms, {len(gaps)} gaps; '
              f'includes any wait for player input)')
    peaks = [chunk['peak_gib'] for chunk in session if chunk['peak_gib'] is not None]
    if peaks:
        reserved = [chunk['reserved_gib'] for chunk in session if chunk['reserved_gib'] is not None]
        print(f'  GPU memory (this process)  peak allocated {max(peaks):.1f} GiB, reserved {max(reserved):.1f} GiB')
    print(f'  RTF                    {seconds / (frames / fps):7.4f}      (generate time / playback time at {fps:g} fps; below 1 keeps up)')
    verdict = 'keeps up with' if frames / seconds >= fps else 'is slower than'
    print(f'  -> generation {verdict} {fps:g} fps playback')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--log', nargs='*', default=[str(Path(__file__).resolve().parent / '.eden_app.log')])
    parser.add_argument('--fps', type=float, default=24.0)
    args = parser.parse_args()
    for path in args.log:
        chunks = parse(path)
        print(f'{path}: {len(chunks)} chunk lines')
        if not chunks:
            print('  none found; the service logs them when its log_model_timing option is on')
        for number, session in enumerate(sessions(chunks), 1):
            report(number, session, args.fps)
        print()


if __name__ == '__main__':
    main()
