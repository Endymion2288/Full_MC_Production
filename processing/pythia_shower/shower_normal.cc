// ==============================================================================
// shower_normal.cc - Standard Pythia8 shower processing
// ==============================================================================
// Performs parton shower + hadronization without phi meson enrichment.
// Includes kinematic filtering for J/psi -> mu+ mu- decay products.
//
// Compilation (in CMSSW environment):
//   g++ -std=c++17 -O2 shower_normal.cc -o shower_normal \
//       $(pythia8-config --cxxflags --libs) \
//       -I$HEPMC3/include -L$HEPMC3/lib64 -lHepMC3
//
// Usage:
//   ./shower_normal input.lhe output.hepmc [nEvents] [minMuonPt] [maxMuonEta] [maxRetry]
// ==============================================================================

#include "Pythia8/Pythia.h"
#include "Pythia8Plugins/HepMC3.h"

#include <iostream>
#include <string>

using namespace Pythia8;
using namespace std;

// Check if J/psi decay muons satisfy kinematic requirements
bool hasValidJpsiMuons(Event& event, double minPt = 2.5, double maxEta = 2.4) {
    for (int i = 0; i < event.size(); ++i) {
        if (abs(event[i].id()) != 443) continue; // Only J/psi
        
        int status = event[i].status();
        if (status >= 0 && !event[i].isFinal()) continue;
        
        int d1 = event[i].daughter1();
        int d2 = event[i].daughter2();
        
        if (d1 <= 0 || d2 <= 0) continue;
        
        bool foundMuPlus = false, foundMuMinus = false;
        bool muPlusValid = false, muMinusValid = false;
        
        for (int j = d1; j <= d2; ++j) {
            int pid = event[j].id();
            if (pid == 13) { // mu-
                foundMuMinus = true;
                if (event[j].pT() > minPt && abs(event[j].eta()) < maxEta) {
                    muMinusValid = true;
                }
            } else if (pid == -13) { // mu+
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
        // Upsilon(1S)=553, Upsilon(2S)=100553, Upsilon(3S)=200553
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

int main(int argc, char* argv[]) {
    
    if (argc < 3) {
        cerr << "\n=== Pythia8 Standard Shower Processing ===" << endl;
        cerr << "Usage: " << argv[0] << " input.lhe output.hepmc [nEvents] [minMuonPt] [maxMuonEta] [maxRetry]" << endl;
        cerr << "\nArguments:" << endl;
        cerr << "  input.lhe   : Input LHE file" << endl;
        cerr << "  output.hepmc: Output HepMC file" << endl;
        cerr << "  nEvents     : Number of events to process (default: -1, all)" << endl;
        cerr << "  minMuonPt   : Minimum muon pT in GeV (default: 2.5)" << endl;
        cerr << "  maxMuonEta  : Maximum muon |eta| (default: 2.4)" << endl;
        cerr << "  maxRetry    : Maximum hadronization retries (default: 100)" << endl;
        return 1;
    }
    
    string inputFile = argv[1];
    string outputFile = argv[2];
    int nEvents = (argc > 3) ? atoi(argv[3]) : -1;
    double minMuonPt = (argc > 4) ? atof(argv[4]) : 2.5;
    double maxMuonEta = (argc > 5) ? atof(argv[5]) : 2.4;
    int maxRetry = (argc > 6) ? atoi(argv[6]) : 1000;
    
    cout << "\n=== Pythia8 Standard Shower Processing ===" << endl;
    cout << "Input LHE:    " << inputFile << endl;
    cout << "Output HepMC: " << outputFile << endl;
    cout << "Events:       " << (nEvents > 0 ? to_string(nEvents) : "all") << endl;
    cout << "Min muon pT:  " << minMuonPt << " GeV" << endl;
    cout << "Max muon eta: " << maxMuonEta << endl;
    cout << "Max retries:  " << maxRetry << endl;
    cout << "==========================================\n" << endl;
    
    // Initialize Pythia
    Pythia pythia;
    
    // Basic settings
    pythia.readString("Beams:frameType = 4"); // Read from LHEF
    pythia.readString("Beams:LHEF = " + inputFile);
    pythia.readString("Beams:eCM = 13600."); // 13.6 TeV Run3
    
    // Shower settings
    pythia.readString("PartonLevel:ISR = on");
    pythia.readString("PartonLevel:FSR = on");
    pythia.readString("PartonLevel:MPI = on");
    
    // Disable automatic hadronization for retry mechanism
    pythia.readString("HadronLevel:all = off");
    
    // Color reconnection (CMS tune)
    pythia.readString("ColourReconnection:reconnect = on");
    pythia.readString("ColourReconnection:mode = 1");
    pythia.readString("ColourReconnection:allowDoubleJunRem = off");
    pythia.readString("ColourReconnection:m0 = 0.3");
    pythia.readString("ColourReconnection:allowJunctions = on");
    pythia.readString("ColourReconnection:junctionCorrection = 1.20");
    pythia.readString("ColourReconnection:timeDilationMode = 2");
    pythia.readString("ColourReconnection:timeDilationPar = 0.18");
    
    // CP5 tune
    pythia.readString("Tune:pp = 14");
    pythia.readString("Tune:ee = 7");
    pythia.readString("MultipartonInteractions:pT0Ref = 2.4024");
    pythia.readString("MultipartonInteractions:ecmPow = 0.25208");
    pythia.readString("MultipartonInteractions:expPow = 1.6");
    
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
    int successEvents = 0;
    int failedEvents = 0;
    
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
        
        // Try hadronization with retries for muon kinematics
        bool foundValid = false;
        int nRetry = 0;
        
        for (nRetry = 0; nRetry < maxRetry; ++nRetry) {
            pythia.event = savedEvent;
            pythia.partonSystems = savedPartonSystems;
            
            if (!pythia.forceHadronLevel()) {
                continue;
            }
            
            // Check muon kinematics
            bool validMuons = hasValidJpsiMuons(pythia.event, minMuonPt, maxMuonEta) ||
                              hasValidUpsilonMuons(pythia.event, minMuonPt, maxMuonEta);
            
            if (validMuons) {
                foundValid = true;
                break;
            }
        }
        
        totalRetries += nRetry + 1;
        
        if (foundValid) {
            successEvents++;
            toHepMC.writeNextEvent(pythia);
        } else {
            failedEvents++;
        }
        
        ++iEvent;
        if (iEvent % 100 == 0) {
            double efficiency = 100.0 * successEvents / iEvent;
            cout << "Processed " << iEvent << " events, "
                 << "efficiency: " << efficiency << "%" << endl;
        }
    }
    
    pythia.stat();
    
    cout << "\n======================================================" << endl;
    cout << "Processing Summary:" << endl;
    cout << "------------------------------------------------------" << endl;
    cout << "Total LHE events processed: " << iEvent << endl;
    cout << "Events written:             " << successEvents 
         << " (" << 100.0*successEvents/max(1,iEvent) << "%)" << endl;
    cout << "Events skipped:             " << failedEvents << endl;
    cout << "Average retries per event:  " << (double)totalRetries/max(1,iEvent) << endl;
    cout << "Output file: " << outputFile << endl;
    cout << "======================================================" << endl;
    
    return 0;
}
