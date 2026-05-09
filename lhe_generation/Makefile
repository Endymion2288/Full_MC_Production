# ==============================================================================
# Makefile for lhe_pythia6_pythia8 standalone converter
# ==============================================================================
# This tool converts LHE files from HELAC-Onia (Pythia6 PDG convention) to
# Pythia8 PDG convention for color-octet quarkonium states.
#
# Usage:
#   make            - Build the converter
#   make clean      - Remove compiled files
#   make install    - Copy executable to bin/
#
# Build environments:
#   - CERN lxplus (LCG_88b): source /cvmfs/sft.cern.ch/lcg/views/LCG_88b/x86_64-centos7-gcc62-opt/setup.sh
#   - CMSSW: eval $(scramv1 runtime -sh)
# ==============================================================================

FC = gfortran

# 不同 worker / lxplus 节点上的 gfortran 版本差异较大。
# 只有当编译器确实支持时才追加 -fallow-argument-mismatch。
FALLOW_ARG_MISMATCH := $(shell printf '      end\n' > .flagcheck_tmp.f && \
	if $(FC) -fallow-argument-mismatch -c .flagcheck_tmp.f -o .flagcheck_tmp.o >/dev/null 2>&1; then \
		printf '%s' '-fallow-argument-mismatch'; \
	fi; \
	rm -f .flagcheck_tmp.f .flagcheck_tmp.o)
FFLAGS = -O2 -Wall $(FALLOW_ARG_MISMATCH)
TARGET = lhe_pythia6_pythia8
SRC = lhe_pythia6_pythia8.f

.PHONY: all clean install

all: $(TARGET)

$(TARGET): $(SRC)
	$(FC) $(FFLAGS) -o $@ $<
	@echo "Build complete: $(TARGET)"
	@echo ""
	@echo "Usage: ./$(TARGET) <input.lhe> <py8_onia_user.inp> [output.lhe]"

clean:
	rm -f $(TARGET)

install: $(TARGET)
	mkdir -p ../bin
	cp $(TARGET) ../bin/
	@echo "Installed to ../bin/$(TARGET)"

# Test with example files (requires test data)
test: $(TARGET)
	@echo "Running test..."
	@if [ -f test_input.lhe ] && [ -f test_onia.inp ]; then \
		./$(TARGET) test_input.lhe test_onia.inp test_output.lhe; \
	else \
		echo "Test files not found. Create test_input.lhe and test_onia.inp"; \
	fi
