import json, pathlib, datetime, io, os, sys
import zstandard

FIELDS = ('inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'totalTokens')
CACHE_VERSION = 1


def _newer(item, best):
    return item is not None and (best is None or item[0] > best[0])


def summarize_file(path):
    """Read one session transcript into a cacheable summary (no cross-file state)."""
    out = dict(requests=0, total=0, input=0, output=0, cache_read=0, days={},
               sessions=[], completed=None, attention=None, errors=0)
    session = str(path.parent)
    latest_assistant = ''
    seen = set()
    with path.open('rb') as source, zstandard.ZstdDecompressor().stream_reader(source) as reader:
        for line in io.TextIOWrapper(reader, encoding='utf-8'):
            try:
                row = json.loads(line)
                kind = row.get('type')
                if kind == 'session':
                    session = row.get('id', session)
                    continue
                data = row.get('data', {})
                if kind == 'tool/call' and data.get('name') == 'ask_user_question':
                    try:
                        args = json.loads(data.get('arguments') or '{}')
                        qs = args.get('questions') or []
                        msg = ' / '.join(str(q.get('question', '')).strip() for q in qs if isinstance(q, dict))
                    except (ValueError, TypeError):
                        msg = ''
                    item = [int(row.get('time', 0) or 0), session, row.get('seq'), msg or '需要你回答一个问题']
                    if _newer(item, out['attention']): out['attention'] = item
                    continue
                if kind == 'tool/result' and data.get('isError'):
                    raw = json.dumps(data.get('message', {}).get('content', ''), ensure_ascii=False)
                    if any(word in raw.lower() for word in ('permission', 'approval', '授权', '允许')):
                        item = [int(row.get('time', 0) or 0), session, row.get('seq'), '有一个权限请求需要你处理']
                        if _newer(item, out['attention']): out['attention'] = item
                    continue
                if kind == 'turn/end' and data.get('reason', {}).get('kind') == 'completed':
                    item = [int(row.get('time', 0) or 0), session, row.get('seq'), latest_assistant]
                    if latest_assistant.rstrip().endswith(('?', '？')):
                        if _newer(item, out['attention']): out['attention'] = item
                    elif _newer(item, out['completed']): out['completed'] = item
                    continue
                if kind != 'assistant/message':
                    continue
                try:
                    parts = data.get('message', {}).get('content', [])
                    texts = [str(x.get('text', '')).strip() for x in parts if isinstance(x, dict) and x.get('type') == 'text']
                    if texts: latest_assistant = '\n'.join(texts)[-1200:]
                except (AttributeError, TypeError):
                    pass
                usage = data.get('usage')
                if not isinstance(usage, dict):
                    continue
                key = (session, row.get('seq'))
                if key in seen:
                    continue
                nums = {k: max(0, int(usage.get(k, 0) or 0)) for k in FIELDS}
                total = nums['totalTokens'] if usage.get('totalTokens') is not None else sum(nums[k] for k in FIELDS[:-1])
                day = datetime.datetime.fromtimestamp(row['time'] / 1000).astimezone().date().isoformat()
                seen.add(key)
                out['requests'] += 1
                out['total'] += total
                out['input'] += nums['inputTokens']
                out['output'] += nums['outputTokens']
                out['cache_read'] += nums['cacheReadTokens']
                d = out['days'].setdefault(day, [0, 0])
                d[0] += total
                d[1] += 1
            except (ValueError, TypeError, KeyError):
                out['errors'] += 1
    out['sessions'] = sorted({s for s, _ in seen})
    return out


def _load_cache(cache_path):
    try:
        with open(cache_path, 'r', encoding='utf-8') as f:
            c = json.load(f)
        if c.get('version') == CACHE_VERSION and isinstance(c.get('files'), dict):
            return c['files']
    except (OSError, ValueError):
        pass
    return {}


def _save_cache(cache_path, files):
    tmp = str(cache_path) + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump({'version': CACHE_VERSION, 'files': files}, f, ensure_ascii=False)
        os.replace(tmp, cache_path)
    except OSError:
        try: os.remove(tmp)
        except OSError: pass


def summarize(root, today=None, cache_path=None):
    today = (today or datetime.datetime.now().astimezone().date()).isoformat()
    result = dict(Status='ok', TodayTokens=0, TotalTokens=0, Requests=0, TodayRequests=0,
                  InputTokens=0, OutputTokens=0, CacheReadTokens=0, Sessions=0, Errors=0,
                  LatestCompletedKey='', LatestCompletedAt='', LatestCompletedSession='', LatestCompletedMessage='',
                  LatestAttentionKey='', LatestAttentionAt='', LatestAttentionSession='', LatestAttentionMessage='',
                  AsOf=datetime.datetime.now().astimezone().isoformat(timespec='seconds'))
    if not root.is_dir():
        result['Status'] = 'unavailable'
        return result
    old = _load_cache(cache_path) if cache_path else {}
    files = {}
    sessions = set()
    completed = None
    attention = None
    for path in root.rglob('session.v4.jsonl.zstd'):
        name = str(path)
        try:
            st = path.stat()
            stamp = [st.st_mtime_ns, st.st_size]
            entry = old.get(name)
            if not entry or entry.get('stamp') != stamp:
                entry = dict(summarize_file(path), stamp=stamp)
        except (OSError, zstandard.ZstdError, UnicodeError):
            result['Errors'] += 1
            continue
        # Only cache clean reads; a file mid-write is re-read next time.
        if not entry['errors']:
            files[name] = entry
        result['Errors'] += entry['errors']
        result['Requests'] += entry['requests']
        result['TotalTokens'] += entry['total']
        result['InputTokens'] += entry['input']
        result['OutputTokens'] += entry['output']
        result['CacheReadTokens'] += entry['cache_read']
        t = entry['days'].get(today)
        if t:
            result['TodayTokens'] += t[0]
            result['TodayRequests'] += t[1]
        sessions.update(entry['sessions'])
        if _newer(entry['completed'], completed): completed = entry['completed']
        if _newer(entry['attention'], attention): attention = entry['attention']
    if cache_path:
        _save_cache(cache_path, files)
    result['Sessions'] = len(sessions)
    if completed:
        ms, sess, seq, msg = completed
        result.update(LatestCompletedKey=f'{sess}:{seq}', LatestCompletedAt=datetime.datetime.fromtimestamp(ms/1000).astimezone().isoformat(timespec='seconds'), LatestCompletedSession=sess, LatestCompletedMessage=msg)
    if attention:
        ms, sess, seq, msg = attention
        result.update(LatestAttentionKey=f'{sess}:{seq}', LatestAttentionAt=datetime.datetime.fromtimestamp(ms/1000).astimezone().isoformat(timespec='seconds'), LatestAttentionSession=sess, LatestAttentionMessage=msg)
    if result['Errors']: result['Status'] = 'partial'
    return result


if __name__ == '__main__':
    app_dir = pathlib.Path(__file__).resolve().parent.parent
    cache = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else app_dir / 'deepseek-usage-cache.json'
    print(json.dumps(summarize(pathlib.Path.home()/'.dsh'/'sessions', cache_path=cache)))
