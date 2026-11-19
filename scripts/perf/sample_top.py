#!/usr/bin/env python3
"""Self-time summary of a macOS `sample` call graph.

usage: sample_top.py FILE [N]

Prints, per thread (busy threads only), the samples that were not waiting, and the
top N functions by self samples across the process, leaving out idle waits.
"""
import re
import sys
from collections import Counter, defaultdict

IDLE = re.compile(r"__psynch_cvwait|__workq_kernreturn|mach_msg2_trap|__semwait_signal|kevent|__select|"
                  r"__ulock_wait|start_wqthread|thread_start|_pthread_start|swtch_pri|__psynch_mutexwait|"
                  r"__accept|__recvfrom|__read_nocancel|__wait4|__sigsuspend")
INCLUSIVE = [(n, re.compile(p)) for n, p in [
    ("core render_rgba (rayon)", r"render_rgba|fringe_field_render_rgba"),
    ("rayon worker (any)", r"rayon_core::registry::WorkerThread"),
    ("core solver threads", r"fringe_core::solver::"),
    ("VectorRenderer.drawOverlays", r"VectorRenderer\.drawOverlays|drawOverlaysBody"),
    ("CGContextDrawImage", r"CGContextDrawImage"),
    ("SwiftUI graph update (AG::Graph)", r"AG::Graph::update|AG::Subgraph::update"),
    ("NSHostingView layout", r"NSHostingView.*layout|ViewGraph.*updateOutputs|updateOutputs"),
    ("CA::Transaction::commit", r"CA::Transaction::commit"),
    ("view bodies (.body.getter)", r"\.body\.getter"),
    ("JSONEncoder", r"JSONEncoder"),
    ("CFRunLoop observers", r"__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER"),
    ("Task.sleep / timers", r"Task.*sleep|_dispatch_after|TimerSource"),
]]
LINE = re.compile(r"^(?P<indent>[\s+!:|]*)(?P<count>\d+)\s+(?P<sym>.+?)(?:\s+\(in (?P<lib>[^)]+)\))?(?:\s+\+\s+\S+)?(?:\s+\[[^\]]+\])?\s*$")


def main():
    path = sys.argv[1]
    top_n = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    try:
        start = lines.index("Call graph:") + 1
    except ValueError:
        sys.exit("no call graph")
    nodes = []  # (depth, count, sym, lib, thread)
    thread = None
    for line in lines[start:]:
        if not line.strip():
            break
        m = LINE.match(line)
        if not m:
            continue
        depth = len(m.group("indent"))
        sym = m.group("sym").strip()
        if sym.startswith("Thread_"):
            thread = sym
            nodes.append((depth, int(m.group("count")), sym, "", thread, True))
            continue
        nodes.append((depth, int(m.group("count")), sym, m.group("lib") or "", thread, False))
    self_counts = Counter()
    per_thread_busy = defaultdict(int)
    child_sums = [0] * len(nodes)
    stack = []
    for i, node in enumerate(nodes):
        while stack and nodes[stack[-1]][0] >= node[0]:
            stack.pop()
        if stack:
            child_sums[stack[-1]] += node[1]
        stack.append(i)
    for i, (depth, count, sym, lib, thread, is_thread) in enumerate(nodes):
        own = count - child_sums[i]
        if own <= 0 or is_thread or IDLE.search(sym):
            continue
        self_counts[f"{sym}  [{lib}]"] += own
        per_thread_busy[thread] += own
    total = sum(self_counts.values())
    print(f"busy samples: {total}")
    for t, n in sorted(per_thread_busy.items(), key=lambda kv: -kv[1])[:12]:
        print(f"  {n:8d}  {t}")
    # Inclusive samples of a few frames of interest, outermost match per stack only.
    inclusive = Counter()
    open_matches = []  # (depth, pattern)
    for depth, count, sym, lib, thread, is_thread in nodes:
        while open_matches and open_matches[-1][0] >= depth:
            open_matches.pop()
        if is_thread:
            continue
        for name, pat in INCLUSIVE:
            if pat.search(sym) and all(n != name for _, n in open_matches):
                inclusive[name] += count
                open_matches.append((depth, name))
    print("inclusive samples of frames of interest:")
    for name, _ in INCLUSIVE:
        if inclusive[name]:
            print(f"  {inclusive[name]:8d}  {name}")
    print(f"top {top_n} functions by self samples:")
    for key, n in self_counts.most_common(top_n):
        print(f"  {n:8d} {100 * n / max(1, total):5.1f}%  {key[:150]}")


if __name__ == "__main__":
    main()
