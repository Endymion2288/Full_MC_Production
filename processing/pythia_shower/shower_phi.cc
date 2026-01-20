// ==============================================================================
// shower_phi.cc - Phi-enriched Pythia8 shower processing
// ==============================================================================
// Performs parton shower + hadronization with phi meson enrichment.
// Uses Pythia8 save/restore mechanism to retry hadronization until
// a phi meson is found in the event.
//
// Key features:
// - Enriched strange quark production to enhance phi yield
// - Multiple hadronization retries to find events with phi mesons
// - Kinematic filtering for both phi and J/psi decay products
//
// Compilation (in CMSSW environment):
//   g++ -std=c++17 -O2 shower_phi.cc -o shower_phi \
//       $(pythia8-config --cxxflags --libs) \
//       -I$HEPMC3/include -L$HEPMC3/lib64 -lHepMC3
//
// Usage:
//   ./shower_phi input.lhe output.hepmc [nEvents] [minPhiPt] [minMuonPt] [maxMuonEta] [maxRetry]
// ==============================================================================

#include "Pythia8/Pythia.h"
#include "Pythia8Plugins/HepMC3.h"

#include <iostream>
#include <string>

using namespace Pythia8;
using namespace std;

// Check for phi meson satisfying pT requirement
// Note: phi meson typically decays immediately, so status is negative (-83, -84)
bool hasPhiMeson(Event& event, double minPt = 0.0) {
    for (int i = 0; i < event.size(); ++i) {
        int pid = abs(event[i].id());
        if (pid == 333) { // phi meson
            int status = event[i].status();
            // phi usually has decayed (status < 0) or is final state
            if ((status < 0) || event[i].isFinal()) {
                if (event[i].pT() > minPt) {
                    return true;
                }
            }
        }
    }
    return false;
}

// Check if J/psi decay muons satisfy kinematic requirements
bool hasValidJpsiMuons(Event& event, double minPt = 2.5, double maxEta = 2.4) {
    for (int i = 0; i < event.size(); ++i) {
        if (abs(event[i].id()) != 443) continue;
        
        int status = event[i].status();
        if (status >= 0 && !event[i].isFinal()) continue;
        
        int d1 = event[i].daughter1();
        int d2 = event[i].daughter2();
        
        if (d1 <= 0 || d2 <= 0) continue;
        
        bool foundMuPlus = false, foundMuMinus = false;
        bool muPlusValid = false, muMinusValid = false;
        
        for (int j = d1; j <= d2; ++j) {
            int pdgid = event[j].id();
            if (pdgid == 13) { // mu-
                foundMuMinus = true;
                if (event[j].pT() > minPt && abs(event[j].eta()) < maxEta) {
                    muMinusValid = true;
                }
            } else if (pdgid == -13) { // mu+
                foundMuPlus = true;
                if (event[j].pT() > minPt && abs(event[j].eta()) < maxEta) {
                    muPlusValid = true;
                }
            }
        }
        
        if (foundMuPlus && foundMuMinus && muPlusValid && muMinusValid) {
            return true;
        }
    }
    return false;
}

// Check if Upsilon decay muons satisfy kinematic requirements
bool hasValidUpsilonMuons(Event& event, double minPt = 2.5, double maxEta = 2.4) {
    for (int i = 0; i < event.size(); ++i) {
        int pid = abs(event[i].id());
        if (pid != 553 && pid != 100553 && pid != 200553) continue;
        
        int status = event[i].status();
        if (status >= 0 && !event[i].isFinal()) continue;
        
        int d1 = event[i].daughter1();
        int d2 = event[i].daughter2();
        
        if (d1 <= 0 || d2 <= 0) continue;
        
        bool foundMuPlus = false, foundMuMinus = false;
        bool muPlusValid = false, muMinusValid = false;
        
        for (int j = d1; j <= d2; ++j) {
            int pdgid = event[j].id();
            if (pdgid == 13) {
                foundMuMinus = true;
                if (event[j].pT() > minPt && abs(event[j].eta()) < maxEta) {
                    muMinusValid = true;
                }
            } else if (pdgid == -13) {
                foundMuPlus = true;
                if (event[j].pT() > minPt && abs(event[j].eta()) < maxEta) {
                    muPlusValid = true;
                }
            }
        }
        
        if (foundMuPlus && foundMuMinus && muPlusValid && muMinusValid) {
            return true;
        }
    }
    return false;
}

// Count particles for statistics
void countParticles(Event& event, int& nJpsi, int& nUpsilon, int& nPhi, int& nMuon) {
    nJpsi = 0;
    nUpsilon = 0;
    nPhi = 0;
    nMuon = 0;
    
    for (int i = 0; i < event.size(); ++i) {
        int pid = abs(event[i].id());
        int status = event[i].status();
        
        if ((status < 0) || event[i].isFinal()) {
            if (pid == 443) nJpsi++;
            else if (pid == 553 || pid == 100553 || pid == 200553) nUpsilon++;
            else if (pid == 333) nPhi++;
            else if (pid == 13) nMuon++;
        }
    }
}

int main(int argc, char* argv[]) {
    
    if (argc < 3) {
        cerr << "\n====== Phi-Enriched Shower Processing ======" << endl;
        cerr << "Usage: " << argv[0] << " input.lhe output.hepmc [nEvents] [minPhiPt] [minMuonPt] [maxMuonEta] [maxRetry]" << endl;
        cerr << "\nArguments:" << endl;
        cerr << "  input.lhe   : Input LHE file from HELAC-Onia" << endl;
        cerr << "  output.hepmc: Output HepMC file" << endl;
        cerr << "  nEvents     : Number of events to process (default: -1, all)" << endl;
        cerr << "  minPhiPt    : Minimum phi pT in GeV (default: 0)" << endl;
        cerr << "  minMuonPt   : Minimum muon pT in GeV (default: 2.5)" << endl;
        cerr << "  maxMuonEta  : Maximum muon |eta| (default: 2.4)" << endl;
        cerr << "  maxRetry    : Maximum hadronization retries (default: 1000)" << endl;
        cerr << "\nExample:" << endl;
        cerr << "  ./shower_phi jpsi_jpsi.lhe phi_enriched.hepmc 1000 3.0 2.5 2.4 1000" << endl;
        return 1;
    }
    
    string inputFile = argv[1];
    string outputFile = argv[2];
    int nEvents = (argc > 3) ? atoi(argv[3]) : -1;
    double minPhiPt = (argc > 4) ? atof(argv[4]) : 0.0;
    double minMuonPt = (argc > 5) ? atof(argv[5]) : 2.5;
    double maxMuonEta = (argc > 6) ? atof(argv[6]) : 2.4;
    int maxRetry = (argc > 7) ? atoi(argv[7]) : 1000;
    
    cout << "\n====== Phi-Enriched Shower Processing ======" << endl;
    cout << "Input LHE:    " << inputFile << endl;
    cout << "Output HepMC: " << outputFile << endl;
    cout << "Events:       " << (nEvents > 0 ? to_string(nEvents) : "all") << endl;
    cout << "Min phi pT:   " << minPhiPt << " GeV" << endl;
    cout << "Min muon pT:  " << minMuonPt << " GeV" << endl;
    cout << "Max muon eta: " << maxMuonEta << endl;
    cout << "Max retries:  " << maxRetry << endl;
    cout << "=============================================\n" << endl;
    
    // Initialize Pythia
    Pythia pythia;

    auto setFlagIfExists = [&](const string& name, bool value) {
        if (pythia.settings.isFlag(name)) {
            pythia.readString(name + " = " + string(value ? "on" : "off"));
        } else {
            cerr << "[WARN] Pythia setting not found (flag): " << name << endl;
        }
    };
    auto setModeIfExists = [&](const string& name, int value) {
        if (pythia.settings.isMode(name)) {
            pythia.readString(name + " = " + to_string(value));
        } else {
            cerr << "[WARN] Pythia setting not found (mode): " << name << endl;
        }
    };
    auto setParmIfExists = [&](const string& name, double value) {
        if (pythia.settings.isParm(name)) {
            pythia.readString(name + " = " + to_string(value));
        } else {
            cerr << "[WARN] Pythia setting not found (parm): " << name << endl;
        }
    };
    
    // Basic settings
    pythia.readString("Beams:frameType = 4"); // Read from LHEF
    pythia.readString("Beams:LHEF = " + inputFile);
    pythia.readString("Beams:eCM = 13600."); // 13.6 TeV Run3

    // Onia settings (guarded by availability in the installed Pythia version)
    setParmIfExists("Onia:massSplit", 0.2);
    setFlagIfExists("Onia:forceMassSplit", true);
    setFlagIfExists("OniaShower:all", true);
    setModeIfExists("OniaShower:octetSplit", 1);
    
    // Parton shower settings
    pythia.readString("PartonLevel:ISR = on");
    pythia.readString("PartonLevel:FSR = on");
    pythia.readString("PartonLevel:MPI = on");
    
    // Disable automatic hadronization for retry mechanism
    pythia.readString("HadronLevel:all = off");
    
    // Tune settings
    pythia.readString("Tune:pp = 14");
    pythia.readString("Tune:ee = 7");
    pythia.readString("MultipartonInteractions:ecmPow = 0.03344");
    pythia.readString("MultipartonInteractions:bProfile = 2");
    pythia.readString("MultipartonInteractions:pT0Ref = 1.41");
    pythia.readString("MultipartonInteractions:coreRadius = 0.7634");
    pythia.readString("MultipartonInteractions:coreFraction = 0.63");
    pythia.readString("ColourReconnection:range = 5.176");
    pythia.readString("SigmaTotal:zeroAXB = off");
    pythia.readString("SpaceShower:alphaSorder = 2");
    pythia.readString("SpaceShower:alphaSvalue = 0.118");
    pythia.readString("SigmaProcess:alphaSvalue = 0.118");
    pythia.readString("SigmaProcess:alphaSorder = 2");
    pythia.readString("MultipartonInteractions:alphaSvalue = 0.118");
    pythia.readString("MultipartonInteractions:alphaSorder = 2");
    pythia.readString("TimeShower:alphaSorder = 2");
    pythia.readString("TimeShower:alphaSvalue = 0.118");
    pythia.readString("SigmaTotal:mode = 0");
    pythia.readString("SigmaTotal:sigmaEl = 21.89");
    pythia.readString("SigmaTotal:sigmaTot = 100.309");
    pythia.readString("PDF:pSet = LHAPDF6:NNPDF31_nnlo_as_0118");

    // Relax event checks for HELAC-Onia LHE color flow
    // pythia.readString("Check:event = off");

    // Enhanced strange quark production for phi enrichment
    pythia.readString("StringFlav:probStoUD = 0.30");  // default 0.217
    pythia.readString("StringFlav:mesonUDvector = 0.60");  // enhance vector mesons
    pythia.readString("StringFlav:mesonSvector = 0.60");
    
    // Force J/psi -> mu+ mu-
    pythia.readString("443:onMode = off");
    pythia.readString("443:onIfMatch = 13 -13");
    
    // Force phi -> K+ K-
    pythia.readString("333:onMode = off");
    pythia.readString("333:onIfMatch = 321 -321");
    
    // Force Upsilon(1S) -> mu+ mu-
    pythia.readString("553:onMode = off");
    pythia.readString("553:onIfMatch = 13 -13");
    
    // Initialize
    if (!pythia.init()) {
        cerr << "Pythia initialization failed!" << endl;
        return 1;
    }
    
    // HepMC3 output
    Pythia8::Pythia8ToHepMC toHepMC(outputFile);
    
    // Statistics
    int iEvent = 0;
    int iAbort = 0;
    int maxAbort = 10;
    int totalRetries = 0;
    int successWithPhi = 0;
    int failedToFindPhi = 0;
    
    // Particle counts
    int totalJpsi = 0, totalUpsilon = 0, totalPhi = 0, totalMuon = 0;
    
    cout << "Starting event processing..." << endl;
    
    while (true) {
        if (nEvents > 0 && iEvent >= nEvents) break;
        
        // Run parton level (without hadronization)
        if (!pythia.next()) {
            if (pythia.info.atEndOfFile()) {
                cout << "Reached end of LHE file." << endl;
                break;
            }
            if (++iAbort < maxAbort) continue;
            cout << "Event generation aborted prematurely!" << endl;
            break;
        }
        
        // Save parton level state
        Event savedEvent = pythia.event;
        PartonSystems savedPartonSystems = pythia.partonSystems;
        
        // Try multiple hadronizations until phi + muon requirements are met
        bool foundValid = false;
        int nRetry = 0;
        
        for (nRetry = 0; nRetry < maxRetry; ++nRetry) {
            pythia.event = savedEvent;
            pythia.partonSystems = savedPartonSystems;
            
            if (!pythia.forceHadronLevel()) {
                continue;
            }
            
            // Check for phi meson with pT cut
            bool hasPhi = hasPhiMeson(pythia.event, minPhiPt);
            // Check muon kinematics
            bool hasMuons = hasValidJpsiMuons(pythia.event, minMuonPt, maxMuonEta) ||
                            hasValidUpsilonMuons(pythia.event, minMuonPt, maxMuonEta);
            
            if (hasPhi && hasMuons) {
                foundValid = true;
                break;
            }
        }
        
        totalRetries += nRetry + 1;
        
        if (foundValid) {
            successWithPhi++;
            
            // Count particles
            int nJpsi, nUpsilon, nPhi, nMuon;
            countParticles(pythia.event, nJpsi, nUpsilon, nPhi, nMuon);
            totalJpsi += nJpsi;
            totalUpsilon += nUpsilon;
            totalPhi += nPhi;
            totalMuon += nMuon;
            
            // Write to HepMC
            toHepMC.writeNextEvent(pythia);
        } else {
            failedToFindPhi++;
        }
        
        ++iEvent;
        if (iEvent % 100 == 0) {
            double efficiency = 100.0 * successWithPhi / iEvent;
            double avgRetry = (double)totalRetries / iEvent;
            cout << "Processed " << iEvent << " events, "
                 << "phi efficiency: " << efficiency << "%, "
                 << "avg retries: " << avgRetry << endl;
        }
    }
    
    pythia.stat();
    
    cout << "\n======================================================" << endl;
    cout << "Phi-Enriched Processing Summary:" << endl;
    cout << "------------------------------------------------------" << endl;
    cout << "Selection criteria:" << endl;
    cout << "  Phi pT > " << minPhiPt << " GeV" << endl;
    cout << "  Muon pT > " << minMuonPt << " GeV, |eta| < " << maxMuonEta << endl;
    cout << "------------------------------------------------------" << endl;
    cout << "Total LHE events processed:   " << iEvent << endl;
    cout << "Events written (all cuts):    " << successWithPhi 
         << " (" << 100.0*successWithPhi/max(1,iEvent) << "%)" << endl;
    cout << "Events skipped (failed cuts): " << failedToFindPhi << endl;
    cout << "Total hadronization tries:    " << totalRetries << endl;
    cout << "Average retries per event:    " << (double)totalRetries/max(1,iEvent) << endl;
    cout << "------------------------------------------------------" << endl;
    cout << "Particle counts (in written events):" << endl;
    cout << "  Total J/psi:   " << totalJpsi << endl;
    cout << "  Total Upsilon: " << totalUpsilon << endl;
    cout << "  Total phi:     " << totalPhi << endl;
    cout << "  Total muons:   " << totalMuon << endl;
    cout << "------------------------------------------------------" << endl;
    cout << "Output events: " << successWithPhi << endl;
    cout << "Output file:   " << outputFile << endl;
    cout << "======================================================" << endl;
    
    return 0;
}
