"""按 TAP 状态图生成覆盖全部 32 条 TMS 边的路径。"""
from pathlib import Path
from collections import deque

GRAPH=((1,0),(1,2),(3,9),(4,5),(4,5),(6,8),(6,7),(4,8),
       (1,2),(10,0),(11,12),(11,12),(13,15),(13,14),(11,15),(1,2))


def route(start,target):
    queue=deque([(start,[])])
    seen={start}
    while queue:
        state,path=queue.popleft()
        if state==target: return path
        for bit,nxt in enumerate(GRAPH[state]):
            if nxt not in seen:
                seen.add(nxt); queue.append((nxt,path+[bit]))
    raise RuntimeError("unreachable state")


state=0; rows=[]; edges=set()
for src in range(16):
    for bit in (0,1):
        for control in route(state,src)+[bit]:
            nxt=GRAPH[state][control]
            edges.add((state,control)); rows.append(f"{control} {nxt}")
            state=nxt
assert len(edges)==32
folder=Path(__file__).resolve().parent/"build"; folder.mkdir(exist_ok=True)
(folder/"walk.txt").write_text("\n".join(rows)+"\n")
print(f"REFERENCE TAP walk steps={len(rows)} states=16 edges={len(edges)}")
