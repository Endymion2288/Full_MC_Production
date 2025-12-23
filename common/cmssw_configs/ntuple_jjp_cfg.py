# ==============================================================================
# ntuple_jjp_cfg.py - Ntuple configuration for JJP (J/psi + J/psi + phi) analysis
# ==============================================================================
# Based on TPS-Onia2MuMu-Dev-J-J-P branch
# Reads MiniAOD and produces flat ntuple for physics analysis
#
# Usage:
#   cmsRun ntuple_jjp_cfg.py inputFiles=file:input.root outputFile=output.root runOnMC=True
# ==============================================================================

import FWCore.ParameterSet.Config as cms
import FWCore.ParameterSet.VarParsing as VarParsing

# Command line options
ivars = VarParsing.VarParsing('analysis')

ivars.inputFiles = (
    'file:input_MINIAOD.root',
)
ivars.outputFile = 'ntuple_jjp.root'

# Custom options
ivars.register('runOnMC',
               True,
               VarParsing.VarParsing.multiplicity.singleton,
               VarParsing.VarParsing.varType.bool,
               "Run on MC (True) or Data (False)")

ivars.register('maxEvents',
               -1,
               VarParsing.VarParsing.multiplicity.singleton,
               VarParsing.VarParsing.varType.int,
               "Maximum number of events")

ivars.parseArguments()

# Configuration flags
AddCaloMuon = False
runOnMC = ivars.runOnMC
HIFormat = False
UseGenPlusSim = False
UsepatMuonsWithTrigger = False

# Process definition
process = cms.Process("mkcands")

# Message logger
process.load("FWCore.MessageService.MessageLogger_cfi")
process.MessageLogger.suppressInfo = cms.untracked.vstring("mkcands")
process.MessageLogger.suppressWarning = cms.untracked.vstring("mkcands")
process.MessageLogger.cerr.FwkReport.reportEvery = 100

# Geometry and conditions
process.load("TrackingTools/TransientTrack/TransientTrackBuilder_cfi")
process.load('Configuration.StandardSequences.GeometryRecoDB_cff')
process.load("Configuration.StandardSequences.Reconstruction_cff")
process.load("Configuration.StandardSequences.MagneticField_AutoFromDBCurrent_cff")

# Max events
process.maxEvents = cms.untracked.PSet(
    input = cms.untracked.int32(ivars.maxEvents)
)

# Global tag
process.load('Configuration.StandardSequences.FrontierConditions_GlobalTag_cff')
from Configuration.AlCa.GlobalTag import GlobalTag

if runOnMC:
    process.GlobalTag.globaltag = cms.string('124X_mcRun3_2022_realistic_v12')
else:
    process.GlobalTag = GlobalTag(process.GlobalTag, '124X_dataRun3_PromptAnalysis_v1', '')

# Input source
process.source = cms.Source("PoolSource",
    skipEvents = cms.untracked.uint32(0),
    fileNames = cms.untracked.vstring(ivars.inputFiles),
)

# Output module (for debugging, usually not used)
process.out = cms.OutputModule("PoolOutputModule",
    fileName = cms.untracked.string('test.root'),
    SelectEvents = cms.untracked.PSet(SelectEvents = cms.vstring('p')),
    outputCommands = cms.untracked.vstring('drop *')
)

# Filters
process.primaryVertexFilter = cms.EDFilter("GoodVertexFilter",
    vertexCollection = cms.InputTag('offlineSlimmedPrimaryVertices'),
    minimumNDOF = cms.uint32(4),
    maxAbsZ = cms.double(24),
    maxd0 = cms.double(2)
)

process.noscraping = cms.EDFilter("FilterOutScraping",
    applyfilter = cms.untracked.bool(True),
    debugOn = cms.untracked.bool(False),
    numtrack = cms.untracked.uint32(10),
    thresh = cms.untracked.double(0.25)
)

# PAT setup
process.load("PhysicsTools.PatAlgos.patSequences_cff")
process.load("PhysicsTools.PatAlgos.cleaningLayer1.genericTrackCleaner_cfi")
process.cleanPatTracks.checkOverlaps.muons.requireNoOverlaps = cms.bool(False)
process.cleanPatTracks.checkOverlaps.electrons.requireNoOverlaps = cms.bool(False)

from PhysicsTools.PatAlgos.producersLayer1.muonProducer_cfi import *
patMuons.embedTrack = cms.bool(True)
patMuons.embedPickyMuon = cms.bool(False)
patMuons.embedTpfmsMuon = cms.bool(False)

# Filter sequence
process.filter = cms.Sequence(process.primaryVertexFilter + process.noscraping)

# Gen particle producer for MC matching
process.genParticlePlusGEANT = cms.EDProducer("GenPlusSimParticleProducer",
    src = cms.InputTag("g4SimHits"),
    setStatus = cms.int32(8),
    filter = cms.vstring("pt > 0.0"),
    genParticles = cms.InputTag("genParticles")
)

# MC matching configuration
if HIFormat:
    process.muonMatch.matched = cms.InputTag("hiGenParticles")
    process.genParticlePlusGEANT.genParticles = cms.InputTag("hiGenParticles")

if UseGenPlusSim:
    process.muonMatch.matched = cms.InputTag("genParticlePlusGEANT")

# Track tools for JJP analysis
from PhysicsTools.PatAlgos.tools.trackTools import *

# ==============================================================================
# JJP-specific analyzer configuration
# ==============================================================================

# Load JJP Onia2MuMu analyzer
process.load("TPS-Onia2MuMu.src.Onia2MuMuPAT_cfi")

# Configure for J/psi + J/psi + phi final state
process.onia2MuMuPAT.muons = cms.InputTag("slimmedMuons")
process.onia2MuMuPAT.primaryVertexTag = cms.InputTag("offlineSlimmedPrimaryVertices")
process.onia2MuMuPAT.beamSpotTag = cms.InputTag("offlineBeamSpot")

# JJP-specific particle selections
# Require two J/psi candidates reconstructed from muon pairs
process.onia2MuMuPAT.onia1Particle = cms.string("J/psi")
process.onia2MuMuPAT.onia2Particle = cms.string("J/psi")

# Phi meson reconstruction from K+K-
process.onia2MuMuPAT.addPhi = cms.bool(True)
process.onia2MuMuPAT.phiMassMin = cms.double(0.99)  # GeV
process.onia2MuMuPAT.phiMassMax = cms.double(1.06)  # GeV

# Muon selection cuts
process.onia2MuMuPAT.muonPtMin = cms.double(2.5)  # GeV
process.onia2MuMuPAT.muonEtaMax = cms.double(2.4)

# J/psi mass window
process.onia2MuMuPAT.jPsiMassMin = cms.double(2.9)  # GeV
process.onia2MuMuPAT.jPsiMassMax = cms.double(3.3)  # GeV

# Kaon selection for phi reconstruction
process.onia2MuMuPAT.kaonPtMin = cms.double(0.5)  # GeV
process.onia2MuMuPAT.kaonEtaMax = cms.double(2.5)

# MC matching (if running on MC)
process.onia2MuMuPAT.isMC = cms.bool(runOnMC)

# ==============================================================================
# TFile Service for output
# ==============================================================================

process.TFileService = cms.Service("TFileService",
    fileName = cms.string(ivars.outputFile)
)

# ==============================================================================
# Path definition
# ==============================================================================

process.p = cms.Path(
    process.filter *
    process.onia2MuMuPAT
)

# Schedule
process.schedule = cms.Schedule(process.p)

# ==============================================================================
# Customization for MC
# ==============================================================================

if runOnMC:
    # Add MC truth matching
    process.onia2MuMuPAT.addMCTruth = cms.bool(True)
    process.onia2MuMuPAT.genParticles = cms.InputTag("prunedGenParticles")
    process.onia2MuMuPAT.packedGenParticles = cms.InputTag("packedGenParticles")
