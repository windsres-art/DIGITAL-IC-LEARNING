#!/usr/bin/env python3
"""Dump FIFO gray sync events from VCD around write burst."""
path = "fifo_async.vcd"
text = open(path, encoding="utf-8", errors="ignore").read().splitlines()

scope = []
id2names = {}
i = 0
while i < len(text):
    line = text[i].strip()
    if line.startswith("$scope"):
        scope.append(line.split()[2])
    elif line.startswith("$upscope"):
        if scope:
            scope.pop()
    elif line.startswith("$var"):
        parts = line.split()
        vid = parts[3]
        name = " ".join(parts[4:]).replace("$end", "").strip()
        id2names.setdefault(vid, []).append(".".join(scope + [name]))
    elif line.startswith("$enddefinitions"):
        i += 1
        break
    i += 1

targets = {}
for vid, names in id2names.items():
    for n in names:
        if n.endswith("inst_FIFO_async.w_pointer_gray [2:0]"):
            targets["w_gray"] = vid
        if n.endswith("inst_FIFO_async.w_pointer_gray_sync [2:0]"):
            targets["w_gray_sync"] = vid
        if n.endswith("tb_FIFO_async.clk_r"):
            targets["clk_r"] = vid
        if n.endswith("tb_FIFO_async.clk_w"):
            targets["clk_w"] = vid
        if "w_pointer_bin" in n:
            targets["w_bin"] = vid
        if n.endswith("tb_FIFO_async.w_en"):
            targets["w_en"] = vid
        if "sync_w2r.dout_t" in n.replace(" ", ""):
            targets["sync_t"] = vid
        if n.endswith("sync_w2r.dout [2:0]") or n.endswith("sync_w2r.dout[2:0]"):
            targets["sync_dout"] = vid
        if "sync_w2r.din" in n:
            targets["sync_din"] = vid

print("IDs:")
for k, v in targets.items():
    print(f"  {k}: {v}  {id2names[v][0]}")

watch = set(targets.values())
vals = {vid: "x" for vid in watch}

print("\nGray table bin -> gray:")
for b in range(0, 6):
    g = (b >> 1) ^ b
    print(f"  {b} ({b:03b}) -> {g:03b}")

print("\nTimeline 400-900ns:")
# find first hash after definitions
while i < len(text) and not text[i].startswith("#"):
    i += 1

t = 0
while i < len(text):
    line = text[i].strip()
    if line.startswith("#"):
        t = int(line[1:])
        i += 1
        continue
    if not line or line.startswith("$"):
        i += 1
        continue

    changed = None
    if line[0] in "01xXzZ" and " " not in line:
        val, vid = line[0], line[1:]
        if vid in watch and vals.get(vid) != val:
            vals[vid] = val
            changed = vid
    elif line.startswith("b"):
        parts = line.split()
        val, vid = parts[0][1:], parts[1]
        if vid in watch and vals.get(vid) != val:
            vals[vid] = val
            changed = vid

    if changed is not None and 400 <= t <= 900:
        def g(key):
            return vals.get(targets.get(key, ""), "?")

        # only print when gray-related or clk_r rising-ish changes
        label = None
        for k, v in targets.items():
            if v == changed:
                label = k
        if label in ("w_bin", "w_gray", "w_gray_sync", "sync_t", "clk_r", "w_en"):
            print(
                f"{t:4d}ns  {label:12s}={vals[changed]:>4} | "
                f"bin={g('w_bin'):>3} gray={g('w_gray'):>3} "
                f"sync_t={g('sync_t'):>3} sync={g('w_gray_sync'):>3} "
                f"clk_r={g('clk_r')} w_en={g('w_en')}"
            )
    i += 1
