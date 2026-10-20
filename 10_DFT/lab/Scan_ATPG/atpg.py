"""对明确列出的 14 个单 stuck-at 故障穷举，贪心压缩，不冒充工业 ATPG。"""
from pathlib import Path
from itertools import product

ROOT=Path(__file__).resolve().parent
SITES=("a","b","c","p","q","dead","y")
PATTERNS=list(product((0,1),repeat=3))
FAULTS=list(product(range(7),(0,1)))


def circuit(pattern, fault=None):
    def inj(site,value):
        return fault[1] if fault and fault[0]==site else value
    a,b,c=(inj(i,v) for i,v in enumerate(pattern))
    p=inj(3,a & b); q=inj(4,(1-a)&c); dead=inj(5,a & (1-a))
    return inj(6,p|q|dead)


def main():
    build=ROOT/"build"; build.mkdir(exist_ok=True)
    detects={p:{f for f in FAULTS if circuit(p)!=circuit(p,f)} for p in PATTERNS}
    detectable=set.union(*detects.values())
    undetectable=set(FAULTS)-detectable
    assert undetectable=={(5,0)}
    remaining=set(detectable); chosen=[]
    while remaining:
        best=max(PATTERNS,key=lambda p:len(detects[p]&remaining))
        assert detects[best]&remaining
        chosen.append(best); remaining-=detects[best]
    rows=[]
    for p in PATTERNS:
        rows.append(" ".join(map(str,(*p,0,0,0,circuit(p)))))
        for site,stuck in FAULTS:
            rows.append(" ".join(map(str,(*p,1,site,stuck,circuit(p,(site,stuck))))))
    (build/"vectors.txt").write_text("\n".join(rows)+"\n")
    report=[f"site={SITES[s]} SA{v}: "+",".join("".join(map(str,p)) for p in PATTERNS if (s,v) in detects[p])
            for s,v in FAULTS]
    (build/"fault_dictionary.txt").write_text("\n".join(report)+"\n")
    print(f"PASS exhaustive fault simulation: patterns=8 faults=14 detectable={len(detectable)} undetectable={len(undetectable)}")
    print("ATPG greedy patterns="+",".join("".join(map(str,p)) for p in chosen))
    print(f"COVERAGE raw={len(detectable)}/14={len(detectable)/14:.6%}; testable={len(detectable)}/{len(detectable)}=100%")
    # 输出端两向量转换故障：延迟到捕获窗口之后，抽象成旧输出仍被捕获。
    rises=[(p0,p1) for p0 in PATTERNS for p1 in PATTERNS if circuit(p0)==0 and circuit(p1)==1]
    falls=[(p0,p1) for p0 in PATTERNS for p1 in PATTERNS if circuit(p0)==1 and circuit(p1)==0]
    assert len(rises)==16 and len(falls)==16
    print(f"PASS output transition abstraction: pairs=64 slow_rise_detecting={len(rises)} slow_fall_detecting={len(falls)}")
    print("NOTE transition abstraction has no physical delay or at-speed clock model")


if __name__=="__main__": main()
