# Makefile for Pythia8 shower programs
# =====================================
# Build shower_normal, shower_phi, and event_mixer_multisource
#
# Prerequisites:
#   - CMSSW environment loaded (provides Pythia8, HepMC3)
#   - HepMC2 available for event mixer
#
# Usage:
#   make all        # Build all programs
#   make shower     # Build shower programs only
#   make mixer      # Build event mixer only
#   make clean      # Remove built files

# Compiler settings
CXX = g++
CXXFLAGS = -std=c++17 -O2 -Wall

# Get paths from environment (CMSSW provides these)
PYTHIA8_INCLUDE = $(shell pythia8-config --includedir 2>/dev/null || echo "")
PYTHIA8_LIBS = $(shell pythia8-config --libs 2>/dev/null || echo "-lpythia8")

# HepMC3 paths (from CMSSW)
HEPMC3_INCLUDE = $(HEPMC3_DIR)/include
HEPMC3_LIB = $(HEPMC3_DIR)/lib64

# HepMC2 paths (for event mixer)
HEPMC2_INCLUDE = $(HEPMC2_DIR)/include
HEPMC2_LIB = $(HEPMC2_DIR)/lib

# Targets
SHOWER_PROGS = shower_normal shower_phi
MIXER_PROG = event_mixer_multisource
ALL_PROGS = $(SHOWER_PROGS) $(MIXER_PROG)

.PHONY: all shower mixer clean check-env

all: check-env $(ALL_PROGS)

shower: check-env $(SHOWER_PROGS)

mixer: check-env $(MIXER_PROG)

check-env:
	@if [ -z "$(CMSSW_BASE)" ]; then \
		echo "Error: CMSSW environment not set. Run 'cmsenv' first."; \
		exit 1; \
	fi
	@echo "Building with CMSSW environment: $(CMSSW_VERSION)"

# Shower programs (use HepMC3)
shower_normal: shower_normal.cc
	@echo "Building shower_normal..."
	$(CXX) $(CXXFLAGS) $< -o $@ \
		$(PYTHIA8_LIBS) \
		-I$(HEPMC3_INCLUDE) -L$(HEPMC3_LIB) \
		-Wl,-rpath,$(HEPMC3_LIB) \
		-lHepMC3
	@echo "Built: $@"

shower_phi: shower_phi.cc
	@echo "Building shower_phi..."
	$(CXX) $(CXXFLAGS) $< -o $@ \
		$(PYTHIA8_LIBS) \
		-I$(HEPMC3_INCLUDE) -L$(HEPMC3_LIB) \
		-Wl,-rpath,$(HEPMC3_LIB) \
		-lHepMC3
	@echo "Built: $@"

# Event mixer (uses both HepMC3 and HepMC2)
event_mixer_multisource: event_mixer_multisource.cc
	@echo "Building event_mixer_multisource..."
	@if [ -z "$(HEPMC2_DIR)" ]; then \
		echo "Warning: HEPMC2_DIR not set, using default paths"; \
	fi
	$(CXX) $(CXXFLAGS) $< -o $@ \
		-I$(HEPMC3_INCLUDE) -I$(HEPMC2_INCLUDE) \
		-L$(HEPMC3_LIB) -L$(HEPMC2_LIB) \
		-Wl,-rpath,$(HEPMC3_LIB) -Wl,-rpath,$(HEPMC2_LIB) \
		-lHepMC3 -lHepMC
	@echo "Built: $@"

clean:
	rm -f $(ALL_PROGS)
	@echo "Cleaned build files"

# Help target
help:
	@echo "Makefile for Pythia8 shower programs"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build all programs"
	@echo "  shower   - Build shower_normal and shower_phi"
	@echo "  mixer    - Build event_mixer_multisource"
	@echo "  clean    - Remove built files"
	@echo ""
	@echo "Environment variables (set by CMSSW):"
	@echo "  CMSSW_BASE  = $(CMSSW_BASE)"
	@echo "  HEPMC3_DIR  = $(HEPMC3_DIR)"
	@echo "  HEPMC2_DIR  = $(HEPMC2_DIR)"
