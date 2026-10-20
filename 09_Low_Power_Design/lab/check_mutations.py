"""安全不变量必须拒绝错误控制序列；编译失败/超时不算检出。"""
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parent
cases=[
    ("isolation_missing","Power_Sequence","power_seq",
     "next_state!=ON && next_state!=DRAIN && next_state!=SAVE",
     "next_state!=ON && next_state!=DRAIN && next_state!=SAVE && next_state!=OFF"),
    ("save_skipped","Power_Sequence","power_seq",
     "DRAIN: if(idle_ack) next_state=SAVE;",
     "DRAIN: if(idle_ack) next_state=ISOLATE;"),
    ("restore_skipped","Power_Sequence","power_seq",
     "RAMP: if(power_good) next_state=RESTORE;",
     "RAMP: if(power_good) next_state=INIT;"),
    ("frequency_too_early","DVFS","dvfs_seq",
     "voltage_req_high<=1; state<=UP_V;",
     "voltage_req_high<=1; frequency_req_high<=1; state<=UP_F;"),
    ("voltage_too_early","DVFS","dvfs_seq",
     "frequency_req_high<=0; state<=DOWN_F;",
     "frequency_req_high<=0; voltage_req_high<=0; state<=DOWN_V;"),
    ("operand_isolation_removed","Activity","operand_isolation",
     "assign isolated_product=a_iso*b_iso;",
     "assign isolated_product=a*b;"),
]
for name,lab,design,old,new in cases:
    source=(ROOT/lab/f"{design}.v").read_text()
    assert source.count(old)==1, name
    folder=ROOT/"build"/"mutations"/name
    folder.mkdir(parents=True,exist_ok=True)
    filename=folder/f"{design}.v"
    filename.write_text(source.replace(old,new))
    top={"power_seq":"tb_power_seq","dvfs_seq":"tb_dvfs","operand_isolation":"tb_activity"}[design]
    subprocess.run(["iverilog","-g2012","-s",top,"-o",str(folder/"sim"),str(filename),
                    str(ROOT/lab/f"{top}.sv")],check=True)
    result=subprocess.run(["vvp","-n","sim"],cwd=folder,capture_output=True,text=True,timeout=30)
    log=result.stdout+result.stderr
    (folder/"result.log").write_text(log)
    accepted=("FAIL unsafe power off","FAIL retention data","FAIL save before off",
              "FAIL raise frequency before voltage","FAIL lower voltage before frequency",
              "FAIL unsafe physical OPP","FAIL activity scenario")
    if result.returncode==0 or not any(marker in log for marker in accepted):
        raise RuntimeError(f"{name}: not rejected by intended checks\n{log}")
    print(f"PASS mutation caught: {name}")
print("PASS low-power mutations: 6/6")
