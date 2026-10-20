"""成功编译的错误实现必须被对应自检查拒绝。"""
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parent
CASES=[
    ("wrong_logic","Scan_ATPG","fault_cone","tb_fault",
     "p | q | dead","p & q & dead","FAIL fault oracle"),
    ("scan_direction","Scan_ATPG","scan_bank","tb_scan",
     "(q<<1)","(q>>1)","FAIL scan load"),
    ("mbist_no_compare","MBIST","march_c_minus","tb_march",
     "if(mem_rdata!={W{expect_one}})","if(1'b0)","FAIL fault detection"),
    ("mbist_wrong_direction","MBIST","march_c_minus","tb_march",
     "(phase==3 || phase==4)","(phase==4)","FAIL March operation order"),
    ("ir_capture_wrong","JTAG","tap_demo","tb_tap",
     "if(state==CAP_IR) ir_shift<=2'b01;","if(state==CAP_IR) ir_shift<=2'b00;","FAIL Capture IR"),
    ("boundary_no_update_latch","JTAG","tap_demo","tb_tap",
     "? boundary_update : core_out","? boundary_shift[3:0] : core_out","FAIL boundary changed during shift"),
    ("tap_pause_edge","JTAG","tap_demo","tb_tap",
     "PAUSE_DR: next_state=tms ? EXIT2_DR : PAUSE_DR;",
     "PAUSE_DR: next_state=tms ? UPDATE_DR : PAUSE_DR;","FAIL TAP state transition"),
]
for name,lab,design,top,old,new,marker in CASES:
    folder=ROOT/"build"/"mutations"/name
    folder.mkdir(parents=True,exist_ok=True)
    source=(ROOT/lab/f"{design}.v").read_text()
    assert source.count(old)==1,name
    (folder/f"{design}.v").write_text(source.replace(old,new))
    for vector in ("vectors.txt","walk.txt"):
        src=ROOT/lab/"build"/vector
        if src.exists(): shutil.copyfile(src,folder/vector)
    subprocess.run(["iverilog","-g2012","-s",top,"-o",str(folder/"sim"),
                    str(folder/f"{design}.v"),str(ROOT/lab/f"{top}.sv")],check=True)
    result=subprocess.run(["vvp","-n","sim"],cwd=folder,text=True,capture_output=True,timeout=30)
    log=result.stdout+result.stderr
    (folder/"result.log").write_text(log)
    if result.returncode==0 or marker not in log or "timeout" in log:
        raise RuntimeError(f"{name}: not caught by intended checker\n{log}")
    print(f"PASS mutation caught: {name}")
print("PASS DFT mutations: 7/7")
