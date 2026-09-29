# =============================================================================
# 计数器仿真流程（先 source /root/oss-cad-suite/environment）
#   make                      编译 + 仿真（默认 W=8 SEED=1）
#   make sim W=4 SEED=7       W 变了会重新编译；只改 SEED 不重新编译
#   make sim BUG=1 CORNER=1   打开注入的 bug / corner 偏置
#   make lint                 Verilator lint
#   make regress              串行回归（regress.sh）
#   make clean
# =============================================================================
W      ?= 8
SEED   ?= 1
CYCLES ?= 1000
CORNER ?= 0
BUG    ?= 0

BUILD := build
RTL   := counter.v
TB    := tb_counter.v

ifeq ($(BUG),1)
  DEFINES := -DINJECT_BUG
  SUFFIX  := _bug
endif

# 编译产物名只含“编译期”参数（W、BUG），运行期参数（SEED 等）放进日志名
SIM_BIN := $(BUILD)/sim_W$(W)$(SUFFIX).vvp
RUN_TAG := W$(W)_S$(SEED)_C$(CORNER)$(SUFFIX)

.PHONY: all compile sim lint regress clean

all: sim

compile: $(SIM_BIN)

# | 后面是 order-only 依赖：目录只要存在即可，它的时间戳变化不会触发重编译
$(SIM_BIN): $(RTL) $(TB) | $(BUILD)
	iverilog -g2012 -Wall -P tb_counter.W=$(W) $(DEFINES) -o $@ $^

$(BUILD):
	mkdir -p $@

# 结果判断交给 grep：vvp 本身即使比对失败也返回 0
sim: $(SIM_BIN)
	vvp -n $< +seed=$(SEED) +cycles=$(CYCLES) +corner=$(CORNER) \
	    +vcd=$(BUILD)/$(RUN_TAG).vcd > $(BUILD)/$(RUN_TAG).log
	@grep -E '^(PASS|FAIL)' $(BUILD)/$(RUN_TAG).log
	@grep -q '^PASS' $(BUILD)/$(RUN_TAG).log

lint:
	verilator --lint-only -Wall -GW=$(W) $(RTL)

regress:
	bash regress.sh

clean:
	rm -rf $(BUILD)
