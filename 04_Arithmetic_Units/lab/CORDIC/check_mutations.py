"""使用数学容差参考拒绝算法错误，编译错误不算通过。"""
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parent
source=(ROOT/"cordic_iter.v").read_text()
mutations={
    "missing_rotation_gain": ("else begin x<=KINV; z<=angle_in; end",
                              "else begin x<=ONE; z<=angle_in; end"),
    "wrong_coarse_rotation": ("x<=-KINV; z<=angle_in-PI;",
                              "x<=KINV; z<=angle_in-PI;"),
    "wrong_vector_direction": ("vector_mode ? y[23] : !z[23]",
                               "vector_mode ? !y[23] : !z[23]"),
    "logical_shift": ("x >>> step", "$signed($unsigned(x) >> step)"),
    "wrong_output_component": ("24'sd0 : x_next;", "24'sd0 : y_next;"),
    "missing_zero_flag": ("zero_vector<=zero_saved;", "zero_vector<=1'b0;"),
}
for name,(old,new) in mutations.items():
    assert source.count(old)==1, name
    folder=ROOT/"build"/"mutations"/name
    folder.mkdir(parents=True, exist_ok=True)
    (folder/"cordic_iter.v").write_text(source.replace(old,new))
    shutil.copyfile(ROOT/"cordic_tables.vh", folder/"cordic_tables.vh")
    shutil.copyfile(ROOT/"build"/"n8"/"vectors.txt", folder/"vectors.txt")
    subprocess.run(["iverilog","-g2012","-gstrict-expr-width","-I",str(folder),
                    "-s","tb_cordic","-Ptb_cordic.ITER=8","-o",str(folder/"sim"),
                    str(folder/"cordic_iter.v"),str(ROOT/"tb_cordic.sv")], check=True)
    result=subprocess.run(["vvp","-n","sim"],cwd=folder,capture_output=True,text=True,timeout=30)
    log=result.stdout+result.stderr
    (folder/"result.log").write_text(log)
    if result.returncode==0 or not any(s in log for s in ("FAIL numeric","FAIL flags")):
        raise RuntimeError(f"{name}: not caught by arithmetic/flag checks\n{log}")
    print(f"PASS mutation caught: {name}")
print("PASS CORDIC mutations: 6/6")
